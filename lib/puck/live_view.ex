if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView do
    @moduledoc """
    Durable streaming integration for Phoenix LiveView.

    Stream state lives in an ETS table owned by this supervisor, so it survives
    GenServer crashes. LiveViews subscribe via PubSub and can reconnect to
    in-progress or completed streams.

    ## Setup

        # application.ex
        children = [
          {Puck.LiveView, pubsub: MyApp.PubSub}
        ]

    ## Usage

        defmodule MyAppWeb.ChatLive do
          use MyAppWeb, :live_view

          def mount(_params, _session, socket) do
            {:ok, Puck.LiveView.assign_defaults(socket, build_client())}
          end

          def handle_event("send", %{"message" => msg}, socket) do
            {:noreply, Puck.LiveView.send_message(socket, msg)}
          end

          def handle_event("cancel", _params, socket) do
            {:noreply, Puck.LiveView.cancel(socket)}
          end

          def handle_info({:puck, event}, socket) do
            {:noreply, Puck.LiveView.handle_event(event, socket)}
          end

          defp build_client do
            Puck.Client.new(
              {Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
              system_prompt: "You are a helpful assistant."
            )
          end
        end

    ## Reconnecting

    Store the `puck_stream_id` (e.g. in the URL or session), then call
    `subscribe/2` on mount to pick up where you left off:

        def mount(%{"stream_id" => id}, _session, socket) do
          socket =
            socket
            |> Puck.LiveView.assign_defaults(build_client())
            |> Puck.LiveView.subscribe(id)

          {:ok, socket}
        end

    ## Assigns

    | Assign | Type | Default |
    |--------|------|---------|
    | `puck_client` | `Puck.Client.t()` | _(required)_ |
    | `puck_context` | `Puck.Context.t()` | `Context.new()` |
    | `puck_stream_id` | `String.t() \\| nil` | `nil` |
    | `puck_content` | `String.t()` | `""` |
    | `puck_thinking` | `String.t()` | `""` |
    | `puck_markdown` | `String.t()` | `""` |
    | `puck_status` | `atom()` | `:idle` |
    | `puck_error` | `term() \\| nil` | `nil` |

    """

    use Supervisor

    alias Puck.Context

    @table Puck.LiveView.ETS
    @registry Puck.LiveView.Registry
    @dynamic_supervisor Puck.LiveView.DynamicSupervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(opts) do
      pubsub = Keyword.fetch!(opts, :pubsub)
      sweep_interval = Keyword.get(opts, :sweep_interval, 30_000)
      max_age = Keyword.get(opts, :max_age, 300_000)

      :persistent_term.put({__MODULE__, :pubsub}, pubsub)

      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
      end

      children = [
        {Registry, keys: :unique, name: @registry},
        {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one},
        {Puck.LiveView.Sweeper,
         table: @table, registry: @registry, sweep_interval: sweep_interval, max_age: max_age}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end

    @doc """
    Initializes Puck assigns on a LiveView socket.

    ## Options

    - `:context` - Initial `Puck.Context` (defaults to `Context.new()`)

    """
    def assign_defaults(socket, client, opts \\ []) do
      context = Keyword.get(opts, :context, Context.new())

      Phoenix.Component.assign(socket,
        puck_client: client,
        puck_context: context,
        puck_stream_id: nil,
        puck_content: "",
        puck_thinking: "",
        puck_markdown: "",
        puck_status: :idle,
        puck_error: nil
      )
    end

    @doc """
    Starts an LLM stream and subscribes the LiveView to updates.

    If already streaming, unsubscribes from the previous stream's topic.
    The old stream continues running independently in its GenServer.

    ## Options

    - `:markdown` - `(String.t() -> String.t())` render function
    - `:mode` - `:stream` (default) or `:call`
    - `:on_chunk` - `fn chunk, state_snapshot -> any() end`
    - `:on_done` - `fn response, state_snapshot -> any() end`
    - `:on_error` - `fn reason, state_snapshot -> any() end`
    - `:ttl` - Milliseconds to keep ETS entry after completion (default: 60,000)
    - `:stream_id` - Custom stream ID (auto-generated if omitted)

    Remaining options are passed through to `Puck.stream/4` or `Puck.call/4`.

    """
    def send_message(socket, content, opts \\ []) do
      {markdown, opts} = Keyword.pop(opts, :markdown)
      {mode, opts} = Keyword.pop(opts, :mode, :stream)
      {on_chunk, opts} = Keyword.pop(opts, :on_chunk)
      {on_done, opts} = Keyword.pop(opts, :on_done)
      {on_error, opts} = Keyword.pop(opts, :on_error)
      {ttl, opts} = Keyword.pop(opts, :ttl, 60_000)
      {stream_id, opts} = Keyword.pop_lazy(opts, :stream_id, &generate_id/0)

      pubsub = pubsub()

      if socket.assigns.puck_stream_id do
        Phoenix.PubSub.unsubscribe(pubsub, topic(socket.assigns.puck_stream_id))
      end

      Phoenix.PubSub.subscribe(pubsub, topic(stream_id))

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          @dynamic_supervisor,
          {Puck.LiveView.Stream,
           [
             stream_id: stream_id,
             table: @table,
             pubsub: pubsub,
             registry: @registry,
             client: socket.assigns.puck_client,
             content: content,
             context: socket.assigns.puck_context,
             mode: mode,
             markdown: markdown,
             on_chunk: on_chunk,
             on_done: on_done,
             on_error: on_error,
             ttl: ttl,
             stream_opts: opts
           ]}
        )

      Phoenix.Component.assign(socket,
        puck_stream_id: stream_id,
        puck_content: "",
        puck_thinking: "",
        puck_markdown: "",
        puck_status: :streaming,
        puck_error: nil
      )
    end

    @doc """
    Reconnects to an existing stream by reading state from ETS.

    Works even if the stream's GenServer has crashed, since ETS is the source
    of truth. Sets `puck_status` to `:not_found` if the entry has expired.

    """
    def subscribe(socket, stream_id) do
      case :ets.lookup(@table, stream_id) do
        [{^stream_id, entry}] ->
          Phoenix.PubSub.subscribe(pubsub(), topic(stream_id))

          Phoenix.Component.assign(socket,
            puck_stream_id: stream_id,
            puck_content: entry.content,
            puck_thinking: entry.thinking,
            puck_markdown: entry.markdown,
            puck_status: entry.status,
            puck_error: entry.error
          )

        [] ->
          Phoenix.Component.assign(socket,
            puck_stream_id: stream_id,
            puck_status: :not_found
          )
      end
    end

    @doc """
    Processes a Puck event and returns the updated socket.

    Call this from your `handle_info/2`:

        def handle_info({:puck, event}, socket) do
          {:noreply, Puck.LiveView.handle_event(event, socket)}
        end

    Events: `{:chunk, :content, text}`, `{:chunk, :thinking, text}`,
    `{:chunk, :markdown, html}`, `{:done, response, context}`,
    `{:error, reason}`, `{:cancelled, content}`.

    """
    def handle_event({:chunk, :content, text}, socket) do
      Phoenix.Component.assign(socket, puck_content: text)
    end

    def handle_event({:chunk, :thinking, text}, socket) do
      Phoenix.Component.assign(socket, puck_thinking: text)
    end

    def handle_event({:chunk, :markdown, html}, socket) do
      Phoenix.Component.assign(socket, puck_markdown: html)
    end

    def handle_event({:done, _response, context}, socket) do
      Phoenix.Component.assign(socket, puck_status: :done, puck_context: context)
    end

    def handle_event({:error, reason}, socket) do
      Phoenix.Component.assign(socket, puck_status: :error, puck_error: reason)
    end

    def handle_event({:cancelled, _content}, socket) do
      Phoenix.Component.assign(socket, puck_status: :cancelled)
    end

    @doc """
    Returns `true` if the socket is currently streaming.
    """
    def streaming?(socket) do
      socket.assigns.puck_status == :streaming
    end

    @doc """
    Cancels the current stream.

    Kills the stream task and sets status to `:cancelled`. The cancellation
    event arrives asynchronously via PubSub.
    """
    def cancel(socket) do
      if socket.assigns.puck_stream_id do
        Puck.LiveView.Stream.cancel(@registry, socket.assigns.puck_stream_id)
      end

      socket
    end

    defp pubsub, do: :persistent_term.get({__MODULE__, :pubsub})

    defp topic(stream_id), do: "puck:stream:#{stream_id}"

    defp generate_id do
      Base.encode64(:crypto.strong_rand_bytes(16), padding: false)
    end
  end
end
