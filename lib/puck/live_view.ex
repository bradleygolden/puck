if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView do
    @moduledoc """
    Supervised streaming for Phoenix LiveView.

    Starts a background stream task, subscribes the caller to PubSub, and
    broadcasts chunks as they arrive. Two functions: `start_stream/4` to begin
    and `cancel/1` to stop. You write your own `handle_info` clauses.

    ## Setup

        # application.ex
        children = [
          Puck.LiveView
        ]

    ## Usage

        defmodule MyAppWeb.ChatLive do
          use MyAppWeb, :live_view

          def mount(_params, _session, socket) do
            {:ok, assign(socket, content: "", status: :idle)}
          end

          def handle_event("send", %{"message" => msg}, socket) do
            {:ok, stream_id} =
              Puck.LiveView.start_stream(build_client(), msg, Puck.Context.new(),
                pubsub: MyApp.PubSub
              )

            {:noreply, assign(socket, stream_id: stream_id, content: "", status: :streaming)}
          end

          def handle_event("cancel", _params, socket) do
            Puck.LiveView.cancel(socket.assigns.stream_id)
            {:noreply, socket}
          end

          def handle_info({:puck_stream, _id, {:chunk, text}}, socket) do
            {:noreply, assign(socket, content: socket.assigns.content <> text)}
          end

          def handle_info({:puck_stream, _id, {:done, response, context}}, socket) do
            {:noreply, assign(socket, status: :done)}
          end

          def handle_info({:puck_stream, _id, {:error, reason}}, socket) do
            {:noreply, assign(socket, status: :error)}
          end

          def handle_info({:puck_stream, _id, {:cancelled, content}}, socket) do
            {:noreply, assign(socket, status: :cancelled)}
          end

          defp build_client do
            Puck.Client.new(
              {Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
              system_prompt: "You are a helpful assistant."
            )
          end
        end

    ## PubSub Messages

    All messages arrive as `{:puck_stream, stream_id, event}` on the topic
    `"puck:stream:\#{stream_id}"`:

    | Event | Description |
    |-------|-------------|
    | `{:chunk, text}` | Individual content chunk (append to your accumulator) |
    | `{:thinking, text}` | Individual thinking chunk |
    | `{:done, response, context}` | Stream completed with `Puck.Response` and updated `Puck.Context` |
    | `{:error, reason}` | Stream failed |
    | `{:cancelled, content}` | Cancelled with accumulated content so far |

    """

    use Supervisor

    @doc """
    Starts the LiveView supervision tree.

    ## Options

      - `:name` - Supervisor name (default: `Puck.LiveView`)

    """
    def start_link(opts \\ []) do
      name = Keyword.get(opts, :name, __MODULE__)
      Supervisor.start_link(__MODULE__, name, name: name)
    end

    @impl true
    def init(name) do
      registry = Module.concat(name, Registry)
      task_supervisor = Module.concat(name, TaskSupervisor)
      dynamic_supervisor = Module.concat(name, DynamicSupervisor)

      children = [
        {Registry, keys: :unique, name: registry},
        {Task.Supervisor, name: task_supervisor},
        {DynamicSupervisor, name: dynamic_supervisor, strategy: :one_for_one}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end

    @doc """
    Starts a supervised stream, subscribes the caller to PubSub, and returns
    the stream ID.

    ## Options

      - `:pubsub` - (required) PubSub module, e.g. `MyApp.PubSub`
      - `:stream_id` - Custom stream ID (auto-generated if omitted)
      - `:name` - Supervisor name to use (default: `Puck.LiveView`)

    Remaining options are passed through to `Puck.stream/4`.

    """
    def start_stream(client, prompt, context, opts) do
      {pubsub, opts} = Keyword.pop!(opts, :pubsub)
      {stream_id, opts} = Keyword.pop_lazy(opts, :stream_id, &generate_id/0)
      {name, opts} = Keyword.pop(opts, :name, __MODULE__)

      registry = Module.concat(name, Registry)
      task_supervisor = Module.concat(name, TaskSupervisor)
      dynamic_supervisor = Module.concat(name, DynamicSupervisor)

      Phoenix.PubSub.subscribe(pubsub, topic(stream_id))

      case DynamicSupervisor.start_child(
             dynamic_supervisor,
             {Puck.LiveView.Stream,
              [
                stream_id: stream_id,
                pubsub: pubsub,
                task_supervisor: task_supervisor,
                registry: registry,
                client: client,
                prompt: prompt,
                context: context,
                stream_opts: opts
              ]}
           ) do
        {:ok, _pid} ->
          {:ok, stream_id}

        {:error, reason} ->
          Phoenix.PubSub.unsubscribe(pubsub, topic(stream_id))
          {:error, reason}
      end
    end

    @doc """
    Cancels an active stream by ID.

    Kills the stream task and triggers a `{:cancelled, content}` broadcast.
    Returns `:ok` even if the stream has already finished.

    """
    def cancel(stream_id, name \\ __MODULE__) do
      registry = Module.concat(name, Registry)
      Puck.LiveView.Stream.cancel(registry, stream_id)
    end

    @doc """
    Returns the PubSub topic for a stream.
    """
    def topic(stream_id), do: "puck:stream:#{stream_id}"

    @doc """
    Generates a unique stream ID.
    """
    def generate_id do
      Base.encode64(:crypto.strong_rand_bytes(16), padding: false)
    end
  end
end
