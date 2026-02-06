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
      stream_id = Keyword.fetch!(opts, :stream_id)
      pubsub = Keyword.fetch!(opts, :pubsub)
      task_supervisor = Keyword.fetch!(opts, :task_supervisor)
      client = Keyword.fetch!(opts, :client)
      prompt = Keyword.fetch!(opts, :prompt)
      context = Keyword.fetch!(opts, :context)
      stream_opts = Keyword.get(opts, :stream_opts, [])

      me = self()

      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          consume(me, client, prompt, context, stream_opts)
        end)

      state = %{
        stream_id: stream_id,
        pubsub: pubsub,
        content: "",
        context: context,
        task_ref: task.ref,
        task_pid: task.pid,
        cancelled: false
      }

      {:ok, state}
    end

    @impl true
    def handle_cast(:cancel, state) do
      if state.task_pid, do: Process.exit(state.task_pid, :kill)
      {:noreply, %{state | cancelled: true}}
    end

    @impl true
    def handle_info({:stream_chunk, chunk}, state) do
      state = accumulate_chunk(state, chunk)
      broadcast(state, chunk_event(chunk))
      {:noreply, state}
    end

    def handle_info({ref, {:stream_done, result_context}}, %{task_ref: ref} = state) do
      Process.demonitor(ref, [:flush])

      response =
        Response.new(
          content: state.content,
          finish_reason: :stop
        )

      final_context =
        Context.add_message(result_context, :assistant, response.content, response.metadata)

      broadcast(state, {:done, response, final_context})
      {:stop, :normal, state}
    end

    def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
      Process.demonitor(ref, [:flush])
      broadcast(state, {:error, reason})
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
      if state.cancelled do
        broadcast(state, {:cancelled, state.content})
        {:stop, :normal, state}
      else
        broadcast(state, {:error, reason})
        {:stop, :normal, state}
      end
    end

    defp consume(parent, client, prompt, context, opts) do
      case Puck.stream(client, prompt, context, opts) do
        {:ok, stream, updated_context} ->
          Enum.each(stream, fn chunk ->
            send(parent, {:stream_chunk, chunk})
          end)

          {:stream_done, updated_context}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp accumulate_chunk(state, %{type: :content, content: text}) do
      %{state | content: state.content <> to_string(text)}
    end

    defp accumulate_chunk(state, _chunk), do: state

    defp chunk_event(%{type: :content, content: text}), do: {:chunk, to_string(text)}
    defp chunk_event(%{type: :thinking, content: text}), do: {:thinking, to_string(text)}
    defp chunk_event(chunk), do: {:chunk, inspect(chunk)}

    defp broadcast(state, event) do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        "puck:stream:#{state.stream_id}",
        {:puck_stream, state.stream_id, event}
      )
    end
  end
end
