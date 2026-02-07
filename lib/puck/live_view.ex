if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView do
    @moduledoc """
    Supervised streaming for Phoenix LiveView.

    Starts a background stream task, subscribes the caller to PubSub, and
    broadcasts chunks as they arrive. Use `start_stream/4` with a client,
    prompt, and context for standard `Puck.stream/4` flows, or `start_stream/2`
    with a custom function for full control over execution logic. Check status
    with `streaming?/1`, cancel with `cancel/1`. You write your own
    `handle_info` clauses.

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

          def handle_info({:puck_stream, _id, {:content, chunk}}, socket) do
            {:noreply, assign(socket, content: socket.assigns.content <> chunk.content)}
          end

          def handle_info({:puck_stream, id, {:done, _response, _context}}, socket) do
            Puck.LiveView.unsubscribe(id, pubsub: MyApp.PubSub)
            {:noreply, assign(socket, status: :done)}
          end

          def handle_info({:puck_stream, _id, {:error, _reason}}, socket) do
            {:noreply, assign(socket, status: :error)}
          end

          def handle_info({:puck_stream, _id, {:cancelled, _content}}, socket) do
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
    | `{:content, chunk}` | Content chunk map (use `chunk.content` for text) |
    | `{:thinking, chunk}` | Thinking chunk map |
    | `{:done, response, context}` | Stream completed with `Puck.Response` and updated `Puck.Context` |
    | `{:error, reason}` | Stream failed |
    | `{:cancelled, content}` | Cancelled with accumulated content so far (string for text, struct for structured output) |

    Chunk events use the chunk's own `:type` as the PubSub tag. Content chunks
    arrive as `{:content, chunk}`, thinking as `{:thinking, chunk}`, and any
    other backend-specific types (e.g. `:tool_use`) use their own tag. Chunk
    maps are passed through unmodified and may include metadata like usage stats
    or model info depending on the backend.

    ## Custom Function

    When your streaming logic goes beyond a single `Puck.stream/4` call —
    multi-turn agentic loops, structured outputs via `Puck.call/4`, or custom
    orchestration — use `start_stream/2` with a function that receives the
    stream's parent PID:

        {:ok, stream_id} =
          Puck.LiveView.start_stream(
            fn parent ->
              send(parent, {:stream_chunk, %{type: :content, content: "thinking..."}})

              {:ok, result} = Puck.call(client, prompt, context, output_schema: schema)
              last_chunk = %{type: :content, content: result.content}
              send(parent, {:stream_chunk, last_chunk})

              {:stream_done, context, last_chunk}
            end,
            pubsub: MyApp.PubSub
          )

    The function must follow this protocol:

      - Send `{:stream_chunk, chunk}` messages to the parent PID during execution
      - Return `{:stream_done, context, last_chunk}` on success
      - Return `{:error, reason}` on failure

    All lifecycle features (PubSub broadcasting, cancellation, timeout,
    telemetry) work identically for both variants.

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
      - `:timeout` - Auto-cancel after this many milliseconds
      - `:name` - Supervisor name to use (default: `Puck.LiveView`)

    Remaining options are passed through to `Puck.stream/4`.

    """
    def start_stream(client, prompt, context, opts) do
      {pubsub, opts} = Keyword.pop!(opts, :pubsub)
      {stream_id, opts} = Keyword.pop_lazy(opts, :stream_id, &generate_id/0)
      {name, opts} = Keyword.pop(opts, :name, __MODULE__)
      {timeout, opts} = Keyword.pop(opts, :timeout)

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
                timeout: timeout,
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
    Starts a supervised stream with a custom function, subscribes the caller
    to PubSub, and returns the stream ID.

    The function receives the stream's parent PID and communicates using the
    same protocol as `start_stream/4` internally: send `{:stream_chunk, chunk}`
    messages during execution and return `{:stream_done, context, last_chunk}`
    or `{:error, reason}`.

    ## Options

      - `:pubsub` - (required) PubSub module, e.g. `MyApp.PubSub`
      - `:stream_id` - Custom stream ID (auto-generated if omitted)
      - `:timeout` - Auto-cancel after this many milliseconds
      - `:name` - Supervisor name to use (default: `Puck.LiveView`)

    """
    def start_stream(fun, opts) when is_function(fun, 1) do
      {pubsub, opts} = Keyword.pop!(opts, :pubsub)
      {stream_id, opts} = Keyword.pop_lazy(opts, :stream_id, &generate_id/0)
      {name, opts} = Keyword.pop(opts, :name, __MODULE__)
      {timeout, _opts} = Keyword.pop(opts, :timeout)

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
                fun: fun,
                timeout: timeout
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
    Returns whether a stream is currently active.

    Checks the registry for a running stream process with the given ID.

        if Puck.LiveView.streaming?(stream_id) do
          # stream is still running
        end

    """
    def streaming?(stream_id, name \\ __MODULE__) do
      registry = Module.concat(name, Registry)
      Registry.lookup(registry, stream_id) != []
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
    Unsubscribes the caller from a stream's PubSub topic.

    Call this in your `{:done, ...}` or `{:error, ...}` handler to stop
    receiving messages after a stream completes.

    """
    def unsubscribe(stream_id, opts) do
      pubsub = Keyword.fetch!(opts, :pubsub)
      Phoenix.PubSub.unsubscribe(pubsub, topic(stream_id))
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
