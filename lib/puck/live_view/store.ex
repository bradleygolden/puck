defmodule Puck.LiveView.Store do
  @moduledoc """
  Storage behavior for LiveView stream snapshots.

  Implementations persist the latest stream state per `stream_id`. Puck core
  intentionally keeps this contract small.
  """

  @callback init(opts :: keyword()) :: {:ok, config :: term()} | {:error, reason :: term()}

  @callback put_stream(config :: term(), stream_id :: String.t(), snapshot :: map()) ::
              :ok | {:error, reason :: term()}

  @callback get_stream(config :: term(), stream_id :: String.t()) ::
              {:ok, map()} | :not_found | {:error, reason :: term()}

  @callback delete_stream(config :: term(), stream_id :: String.t()) ::
              :ok | {:error, reason :: term()}

  @callback sweep(config :: term(), opts :: keyword()) ::
              :ok | {:error, reason :: term()}
end
