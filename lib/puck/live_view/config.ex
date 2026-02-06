defmodule Puck.LiveView.Config do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  catch
    :exit, _ -> {:error, :not_started}
  end

  @impl true
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    store = Keyword.fetch!(opts, :store)
    {:ok, %{pubsub: pubsub, store: store}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, {:ok, state}, state}
  end
end
