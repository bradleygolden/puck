defmodule Puck.LiveView.Config do
  @moduledoc false

  @key {__MODULE__, :config}

  def put(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    store = Keyword.fetch!(opts, :store)
    :persistent_term.put(@key, %{pubsub: pubsub, store: store})
    :ok
  end

  def get do
    case :persistent_term.get(@key, :not_found) do
      :not_found -> {:error, :not_started}
      config -> {:ok, config}
    end
  end

  def delete do
    :persistent_term.erase(@key)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
