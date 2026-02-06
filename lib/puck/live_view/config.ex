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
    {:ok, :persistent_term.get(@key)}
  rescue
    ArgumentError -> {:error, :not_started}
  end

  def delete do
    :persistent_term.erase(@key)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
