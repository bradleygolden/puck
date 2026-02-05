defmodule Puck.LiveView.Store do
  @moduledoc """
  Storage behavior for LiveView stream state.

  Implementations can persist stream sessions and chunks in ETS, a database,
  or another backend. The first argument to every callback is the store config
  returned by `init/1`.
  """

  @callback init(opts :: keyword()) :: {:ok, config :: term()} | {:error, reason :: term()}

  @callback put_stream(config :: term(), stream_id :: String.t(), attrs :: map()) ::
              :ok | {:error, reason :: term()}

  @callback append_chunk(
              config :: term(),
              stream_id :: String.t(),
              seq :: non_neg_integer(),
              chunk :: term(),
              snapshot :: map()
            ) :: :ok | {:error, reason :: term()}

  @callback mark_done(
              config :: term(),
              stream_id :: String.t(),
              response :: term(),
              context :: term(),
              snapshot :: map()
            ) :: :ok | {:error, reason :: term()}

  @callback mark_error(
              config :: term(),
              stream_id :: String.t(),
              reason :: term(),
              snapshot :: map()
            ) :: :ok | {:error, reason :: term()}

  @callback mark_cancelled(config :: term(), stream_id :: String.t(), snapshot :: map()) ::
              :ok | {:error, reason :: term()}

  @callback get_stream(config :: term(), stream_id :: String.t()) ::
              {:ok, map()} | :not_found | {:error, reason :: term()}

  @callback list_chunks(config :: term(), stream_id :: String.t()) ::
              {:ok, [map()]} | {:error, reason :: term()}

  @callback delete_stream(config :: term(), stream_id :: String.t()) ::
              :ok | {:error, reason :: term()}

  @callback sweep(config :: term(), opts :: keyword()) ::
              :ok | {:error, reason :: term()}
end
