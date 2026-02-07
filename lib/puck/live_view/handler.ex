if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView.Handler do
    @moduledoc """
    Behaviour for handling stream lifecycle events inside the stream process.

    When using `Puck.LiveView`, the stream GenServer survives LiveView disconnects
    (it's supervised under `Puck.LiveView`). This makes it the right place for
    persistence logic — if the LiveView disconnects mid-stream, the handler still
    fires.

    Handlers run **after** PubSub broadcast, so LiveView always gets events even
    if the handler fails.

    ## Callbacks

    All four callbacks are optional — implement only what you need.

    - `on_chunk/2` — Called for each chunk. The only callback that threads state,
      enabling batching or buffering patterns.
    - `on_done/3` — Called when the stream completes with a response and context.
    - `on_error/2` — Called when the stream fails.
    - `on_cancel/2` — Called when the stream is cancelled.

    ## Usage

        defmodule MyApp.ChatPersistence do
          @behaviour Puck.LiveView.Handler

          @impl true
          def on_done(response, context, %{conversation_id: id}) do
            MyApp.Conversations.save_message(id, response.content)
            :ok
          end
        end

        Puck.LiveView.start_stream(client, prompt, context,
          pubsub: MyApp.PubSub,
          handler: {MyApp.ChatPersistence, %{conversation_id: id}}
        )

    The config map doubles as the initial handler state — no `init` callback
    needed. This matches the `{module, config}` pattern used by `Puck.Compaction`.
    """

    alias Puck.{Context, Response}

    @callback on_chunk(chunk :: map(), state :: term()) :: {:cont, new_state :: term()}
    @callback on_done(response :: Response.t(), context :: Context.t(), state :: term()) :: :ok
    @callback on_error(reason :: term(), state :: term()) :: :ok
    @callback on_cancel(content :: term(), state :: term()) :: :ok

    @optional_callbacks [on_chunk: 2, on_done: 3, on_error: 2, on_cancel: 2]
  end
end
