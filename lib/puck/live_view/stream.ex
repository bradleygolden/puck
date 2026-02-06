if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView.Stream do
    @moduledoc false

    use GenServer

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
      client = Keyword.fetch!(opts, :client)
      prompt = Keyword.fetch!(opts, :prompt)
      context = Keyword.fetch!(opts, :context)
      stream_opts = Keyword.get(opts, :stream_opts, [])
      timeout = Keyword.get(opts, :timeout)

      start_time =
        Telemetry.start([:live_view, :stream], %{stream_id: stream_id, client: client})

      me = self()

      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          consume(me, client, prompt, context, stream_opts)
        end)

      if timeout, do: Process.send_after(self(), :timeout, timeout)

      state = %{
        stream_id: stream_id,
        pubsub: pubsub,
        content: "",
        context: context,
        task_ref: task.ref,
        task_pid: task.pid,
        cancelled: false,
        start_time: start_time
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

      Telemetry.stop([:live_view, :stream], state.start_time, %{
        stream_id: state.stream_id,
        response: response
      })

      broadcast(state, {:done, response, final_context})
      {:stop, :normal, state}
    end

    def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
      Process.demonitor(ref, [:flush])

      Telemetry.event([:live_view, :stream, :error], %{}, %{
        stream_id: state.stream_id,
        reason: reason
      })

      broadcast(state, {:error, reason})
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
      if state.cancelled do
        Telemetry.event([:live_view, :stream, :cancel], %{}, %{
          stream_id: state.stream_id,
          content: state.content
        })

        broadcast(state, {:cancelled, state.content})
        {:stop, :normal, state}
      else
        Telemetry.event([:live_view, :stream, :error], %{}, %{
          stream_id: state.stream_id,
          reason: reason
        })

        broadcast(state, {:error, reason})
        {:stop, :normal, state}
      end
    end

    def handle_info(:timeout, state) do
      if state.task_pid, do: Process.exit(state.task_pid, :kill)
      {:noreply, %{state | cancelled: true}}
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

    defp chunk_event(%{type: :content} = chunk), do: {:chunk, chunk}
    defp chunk_event(%{type: :thinking} = chunk), do: {:thinking, chunk}
    defp chunk_event(chunk), do: {:chunk, chunk}

    defp broadcast(state, event) do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        "puck:stream:#{state.stream_id}",
        {:puck_stream, state.stream_id, event}
      )
    end
  end
end
