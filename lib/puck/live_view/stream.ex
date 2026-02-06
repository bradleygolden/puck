if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView.Stream do
    @moduledoc false

    use GenServer

    alias Puck.{Context, Response}

    def start_link(opts) do
      stream_id = Keyword.fetch!(opts, :stream_id)
      registry = Keyword.fetch!(opts, :registry)
      GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, stream_id}})
    end

    def cancel(registry, stream_id) do
      case Registry.lookup(registry, stream_id) do
        [{pid, _}] -> GenServer.cast(pid, :cancel)
        [] -> :ok
      end
    end

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)

      stream_id = Keyword.fetch!(opts, :stream_id)
      pubsub = Keyword.fetch!(opts, :pubsub)
      store = Keyword.fetch!(opts, :store)
      client = Keyword.fetch!(opts, :client)
      content = Keyword.fetch!(opts, :content)
      context = Keyword.fetch!(opts, :context)
      mode = Keyword.get(opts, :mode, :stream)
      render_fn = Keyword.get(opts, :markdown)
      on_chunk = Keyword.get(opts, :on_chunk)
      on_done = Keyword.get(opts, :on_done)
      on_error = Keyword.get(opts, :on_error)
      stream_opts = Keyword.get(opts, :stream_opts, [])

      initial_entry = %{
        content: "",
        thinking: "",
        markdown: "",
        status: :streaming,
        error: nil,
        response: nil,
        context: context,
        updated_at: System.monotonic_time(:millisecond)
      }

      state = %{
        stream_id: stream_id,
        store: store,
        pubsub: pubsub,
        content: "",
        thinking: "",
        markdown: "",
        context: context,
        render_fn: render_fn,
        on_chunk: on_chunk,
        on_done: on_done,
        on_error: on_error,
        task_ref: nil,
        task_pid: nil,
        cancelled: false
      }

      case persist_put_stream(state, initial_entry) do
        :ok ->
          me = self()
          task = Task.async(fn -> consume(me, client, content, context, mode, stream_opts) end)
          {:ok, %{state | task_ref: task.ref, task_pid: task.pid}}

        {:error, reason} ->
          {:stop, {:store_error, reason}}
      end
    end

    @impl true
    def handle_cast(:cancel, state) do
      if state.task_pid, do: Process.exit(state.task_pid, :kill)
      {:noreply, %{state | cancelled: true}}
    end

    @impl true
    def handle_info({:stream_chunk, chunk}, state) do
      state = accumulate_chunk(state, chunk)

      case persist_snapshot(state, streaming_entry(state)) do
        :ok ->
          broadcast_chunk(state, chunk)
          safe_callback(state.on_chunk, [chunk, snapshot(state)])
          {:noreply, state}

        {:error, reason} ->
          handle_stream_error(state, {:store_error, reason})
      end
    end

    def handle_info({ref, {:stream_done, result_context}}, %{task_ref: ref} = state) do
      Process.demonitor(ref, [:flush])

      response =
        Response.new(
          content: state.content,
          thinking: if(state.thinking == "", do: nil, else: state.thinking),
          finish_reason: :stop
        )

      final_context =
        Context.add_message(result_context, :assistant, response.content, response.metadata)

      state = %{state | context: final_context}

      case persist_snapshot(state, done_entry(state, response, final_context)) do
        :ok ->
          broadcast_done(state, response, final_context)
          safe_callback(state.on_done, [response, snapshot(state)])
          {:stop, :normal, state}

        {:error, reason} ->
          handle_stream_error(state, {:store_error, reason})
      end
    end

    def handle_info({ref, {:call_done, response, result_context}}, %{task_ref: ref} = state) do
      Process.demonitor(ref, [:flush])

      content = if(is_binary(response.content), do: response.content, else: "")
      thinking = response.thinking || ""
      markdown = if(state.render_fn && content != "", do: state.render_fn.(content), else: "")

      state = %{
        state
        | content: content,
          thinking: thinking,
          markdown: markdown,
          context: result_context
      }

      case persist_snapshot(state, done_entry(state, response, result_context)) do
        :ok ->
          broadcast_done(state, response, result_context)
          safe_callback(state.on_done, [response, snapshot(state)])
          {:stop, :normal, state}

        {:error, reason} ->
          handle_stream_error(state, {:store_error, reason})
      end
    end

    def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
      Process.demonitor(ref, [:flush])
      handle_stream_error(state, reason)
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
      if state.cancelled do
        case persist_snapshot(state, cancelled_entry(state)) do
          :ok ->
            broadcast_cancelled(state)
            {:stop, :normal, state}

          {:error, store_reason} ->
            handle_stream_error(state, {:store_error, store_reason})
        end
      else
        handle_stream_error(state, reason)
      end
    end

    def handle_info({:EXIT, _pid, _reason}, state) do
      {:noreply, state}
    end

    # -- Stream consumption (runs in Task) --

    defp consume(parent, client, content, context, :stream, opts) do
      case Puck.stream(client, content, context, opts) do
        {:ok, stream, updated_context} ->
          Enum.each(stream, fn chunk ->
            send(parent, {:stream_chunk, chunk})
          end)

          {:stream_done, updated_context}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp consume(_parent, client, content, context, :call, opts) do
      case Puck.call(client, content, context, opts) do
        {:ok, response, updated_context} ->
          {:call_done, response, updated_context}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # -- Chunk accumulation --

    defp accumulate_chunk(state, %{type: :content, content: text}) do
      new_content = state.content <> to_string(text)
      new_markdown = if(state.render_fn, do: state.render_fn.(new_content), else: "")
      %{state | content: new_content, markdown: new_markdown}
    end

    defp accumulate_chunk(state, %{type: :thinking, content: text}) do
      %{state | thinking: state.thinking <> to_string(text)}
    end

    defp accumulate_chunk(state, _chunk), do: state

    # -- PubSub broadcasts --

    defp broadcast_chunk(state, %{type: :content}) do
      topic = topic(state.stream_id)
      Phoenix.PubSub.broadcast(state.pubsub, topic, {:puck, {:chunk, :content, state.content}})

      if state.render_fn do
        Phoenix.PubSub.broadcast(
          state.pubsub,
          topic,
          {:puck, {:chunk, :markdown, state.markdown}}
        )
      end
    end

    defp broadcast_chunk(state, %{type: :thinking}) do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        topic(state.stream_id),
        {:puck, {:chunk, :thinking, state.thinking}}
      )
    end

    defp broadcast_chunk(_state, _chunk), do: :ok

    defp broadcast_done(state, response, context) do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        topic(state.stream_id),
        {:puck, {:done, response, context}}
      )
    end

    defp broadcast_cancelled(state) do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        topic(state.stream_id),
        {:puck, {:cancelled, state.content}}
      )
    end

    # -- Store writes --

    # -- Error handling --

    defp handle_stream_error(state, reason) do
      _ = persist_error(state, reason)

      Phoenix.PubSub.broadcast(
        state.pubsub,
        topic(state.stream_id),
        {:puck, {:error, reason}}
      )

      safe_callback(state.on_error, [reason, snapshot(state)])
      {:stop, :normal, state}
    end

    # -- Helpers --

    defp snapshot(state) do
      %{
        stream_id: state.stream_id,
        content: state.content,
        thinking: state.thinking,
        markdown: state.markdown,
        context: state.context
      }
    end

    defp safe_callback(nil, _args), do: :ok

    defp safe_callback(fun, args) do
      apply(fun, args)
    rescue
      _ -> :ok
    end

    defp topic(stream_id), do: "puck:stream:#{stream_id}"

    defp persist_put_stream(state, attrs) do
      {store_module, store_config} = state.store
      store_module.put_stream(store_config, state.stream_id, attrs)
    end

    defp persist_snapshot(state, snapshot) do
      {store_module, store_config} = state.store
      store_module.put_stream(store_config, state.stream_id, snapshot)
    end

    defp persist_error(state, reason) do
      {store_module, store_config} = state.store
      store_module.put_stream(store_config, state.stream_id, error_entry(state, reason))
    end

    defp streaming_entry(state) do
      %{
        content: state.content,
        thinking: state.thinking,
        markdown: state.markdown,
        status: :streaming,
        error: nil,
        response: nil,
        context: state.context,
        updated_at: System.monotonic_time(:millisecond)
      }
    end

    defp done_entry(state, response, context) do
      %{
        content: state.content,
        thinking: state.thinking,
        markdown: state.markdown,
        status: :done,
        error: nil,
        response: response,
        context: context,
        updated_at: System.monotonic_time(:millisecond)
      }
    end

    defp error_entry(state, reason) do
      %{
        content: state.content,
        thinking: state.thinking,
        markdown: state.markdown,
        status: :error,
        error: reason,
        response: nil,
        context: state.context,
        updated_at: System.monotonic_time(:millisecond)
      }
    end

    defp cancelled_entry(state) do
      %{
        content: state.content,
        thinking: state.thinking,
        markdown: state.markdown,
        status: :cancelled,
        error: nil,
        response: nil,
        context: state.context,
        updated_at: System.monotonic_time(:millisecond)
      }
    end
  end
end
