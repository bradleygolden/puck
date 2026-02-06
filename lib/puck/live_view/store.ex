defmodule Puck.LiveView.Store do
  @moduledoc """
  Storage behaviour for LiveView stream snapshots.

  Implementations persist the latest stream state per `stream_id`. Puck ships
  with `Puck.LiveView.Store.ETS` as the default.

  ## Snapshot shape

  The `snapshot` map passed to `put_stream/3` and returned by `get_stream/2`
  contains:

    - `:content` - accumulated content text
    - `:thinking` - accumulated thinking text
    - `:markdown` - rendered markdown HTML
    - `:status` - `:streaming`, `:done`, `:error`, or `:cancelled`
    - `:error` - error reason or `nil`
    - `:response` - `Puck.Response.t()` or `nil`
    - `:context` - `Puck.Context.t()`
    - `:updated_at` - monotonic timestamp in milliseconds

  """

  @doc """
  Called once during supervisor startup to initialize store state.

  Receives the options from the `{module, opts}` tuple in the supervisor config,
  with `:registry` merged in. Return `{:ok, config}` where `config` is passed
  to all subsequent callbacks.
  """
  @callback init(opts :: keyword()) :: {:ok, config :: term()} | {:error, reason :: term()}

  @doc """
  Persists a stream snapshot. Called on every chunk, completion, error, and
  cancellation.
  """
  @callback put_stream(config :: term(), stream_id :: String.t(), snapshot :: map()) ::
              :ok | {:error, reason :: term()}

  @doc """
  Retrieves the latest snapshot for a stream. Returns `:not_found` when the
  stream has expired or was never created.
  """
  @callback get_stream(config :: term(), stream_id :: String.t()) ::
              {:ok, map()} | :not_found | {:error, reason :: term()}

  @doc """
  Removes a stream snapshot.
  """
  @callback delete_stream(config :: term(), stream_id :: String.t()) ::
              :ok | {:error, reason :: term()}

  @doc """
  Deletes expired snapshots. Called periodically by the sweeper.

  `opts` contains `:retention_ms` — snapshots older than this (in milliseconds)
  with no active GenServer should be removed.
  """
  @callback sweep(config :: term(), opts :: keyword()) ::
              :ok | {:error, reason :: term()}
end
