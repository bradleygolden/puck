if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView.Stream do
    @moduledoc false

    use GenServer, restart: :temporary

    alias Puck.{Context, Response}
    alias Puck.Runtime.Telemetry

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
      timeout = Keyword.get(opts, :timeout)

      handler =
        case Keyword.get(opts, :handler) do
          {module, config} ->
            {module, config}

          nil ->
            nil

          other ->
            raise ArgumentError,
                  "expected :handler to be {module, config}, got: #{inspect(other)}"
        end

      me = self()

      {task, start_time} =
        case Keyword.fetch(opts, :fun) do
          {:ok, fun} ->
            start_time = Telemetry.start([:live_view, :stream], %{stream_id: stream_id})
            task = Task.Supervisor.async_nolink(task_supervisor, fn -> fun.(me) end)
            {task, start_time}

          :error ->
            client = Keyword.fetch!(opts, :client)
            prompt = Keyword.fetch!(opts, :prompt)
            context = Keyword.fetch!(opts, :context)
            stream_opts = Keyword.get(opts, :stream_opts, [])

            start_time =
              Telemetry.start([:live_view, :stream], %{stream_id: stream_id, client: client})

            task =
              Task.Supervisor.async_nolink(task_supervisor, fn ->
                consume(me, client, prompt, context, stream_opts)
              end)

            {task, start_time}
        end

      if timeout, do: Process.send_after(self(), :timeout, timeout)

      state = %{
        stream_id: stream_id,
        pubsub: pubsub,
        content: "",
        task_ref: task.ref,
        task_pid: task.pid,
        cancelled: false,
        start_time: start_time,
        handler: handler
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
      broadcast(state, {chunk_type(chunk), chunk})
      state = invoke_handler(:on_chunk, [chunk], state)
      {:noreply, state}
    end

    def handle_info(
          {ref, {:stream_done, result_context, last_chunk}},
          %{task_ref: ref} = state
        ) do
      Process.demonitor(ref, [:flush])

      finish_reason = chunk_field(last_chunk, :finish_reason, :stop)
      metadata = chunk_field(last_chunk, :metadata, %{})

      response =
        Response.new(
          content: state.content,
          finish_reason: finish_reason,
          metadata: metadata
        )

      Telemetry.stop([:live_view, :stream], state.start_time, %{
        stream_id: state.stream_id,
        response: response
      })

      broadcast(state, {:done, response, result_context})
      invoke_handler(:on_done, [response, result_context], state)
      {:stop, :normal, state}
    end

    def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
      Process.demonitor(ref, [:flush])

      Telemetry.event([:live_view, :stream, :error], %{}, %{
        stream_id: state.stream_id,
        reason: reason
      })

      broadcast(state, {:error, reason})
      invoke_handler(:on_error, [reason], state)
      {:stop, :normal, state}
    end

    def handle_info(
          {:DOWN, ref, :process, _pid, _reason},
          %{task_ref: ref, cancelled: true} = state
        ) do
      Telemetry.event([:live_view, :stream, :cancel], %{}, %{
        stream_id: state.stream_id,
        content: state.content
      })

      broadcast(state, {:cancelled, state.content})
      invoke_handler(:on_cancel, [state.content], state)
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
      Telemetry.event([:live_view, :stream, :error], %{}, %{
        stream_id: state.stream_id,
        reason: reason
      })

      broadcast(state, {:error, reason})
      invoke_handler(:on_error, [reason], state)
      {:stop, :normal, state}
    end

    def handle_info(:timeout, state) do
      if state.task_pid, do: Process.exit(state.task_pid, :kill)
      {:noreply, %{state | cancelled: true}}
    end

    defp consume(parent, client, prompt, context, opts) do
      case Puck.stream(client, prompt, context, opts) do
        {:ok, stream, updated_context} ->
          {last_chunk, content} =
            Enum.reduce(stream, {nil, ""}, fn chunk, {_prev, acc} ->
              send(parent, {:stream_chunk, chunk})
              {chunk, accumulate_content(acc, chunk)}
            end)

          metadata = chunk_field(last_chunk, :metadata, %{})
          final_context = Context.add_message(updated_context, :assistant, content, metadata)
          {:stream_done, final_context, last_chunk}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp accumulate_content(acc, %{type: :content, content: text}) when is_binary(text),
      do: acc <> text

    defp accumulate_content(_acc, %{type: :content, content: value}), do: value
    defp accumulate_content(acc, _chunk), do: acc

    defp accumulate_chunk(state, %{type: :content, content: text}) when is_binary(text) do
      %{state | content: state.content <> text}
    end

    defp accumulate_chunk(state, %{type: :content, content: value}) do
      %{state | content: value}
    end

    defp accumulate_chunk(state, _chunk), do: state

    defp chunk_type(%{type: type}), do: type
    defp chunk_type(_chunk), do: :unknown

    defp chunk_field(nil, _key, default), do: default
    defp chunk_field(chunk, key, default), do: Map.get(chunk, key, default)

    defp invoke_handler(_callback, _args, %{handler: nil} = state), do: state

    defp invoke_handler(:on_chunk, args, %{handler: {module, handler_state}} = state) do
      if function_exported?(module, :on_chunk, 2) do
        try do
          case apply(module, :on_chunk, args ++ [handler_state]) do
            {:cont, new_handler_state} ->
              %{state | handler: {module, new_handler_state}}

            _other ->
              state
          end
        rescue
          e ->
            Telemetry.event([:live_view, :stream, :handler_error], %{}, %{
              stream_id: state.stream_id,
              handler: module,
              callback: :on_chunk,
              reason: e
            })

            state
        end
      else
        state
      end
    end

    defp invoke_handler(callback, args, %{handler: {module, handler_state}} = state) do
      arity = length(args) + 1

      if function_exported?(module, callback, arity) do
        try do
          apply(module, callback, args ++ [handler_state])
        rescue
          e ->
            Telemetry.event([:live_view, :stream, :handler_error], %{}, %{
              stream_id: state.stream_id,
              handler: module,
              callback: callback,
              reason: e
            })
        end
      end

      state
    end

    defp broadcast(state, event) do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        "puck:stream:#{state.stream_id}",
        {:puck_stream, state.stream_id, event}
      )
    end
  end
end
