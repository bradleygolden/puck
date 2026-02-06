defmodule Puck.LiveView.ConfigTest do
  use ExUnit.Case, async: true

  alias Puck.LiveView.Config

  setup do
    on_exit(fn -> Config.delete() end)
    :ok
  end

  test "get returns {:ok, config} after put" do
    Config.put(pubsub: MyApp.PubSub, store: {SomeStore, %{}})
    assert {:ok, %{pubsub: MyApp.PubSub, store: {SomeStore, %{}}}} = Config.get()
  end

  test "get returns {:error, :not_started} when not put" do
    Config.delete()
    assert {:error, :not_started} = Config.get()
  end

  test "delete clears config" do
    Config.put(pubsub: MyApp.PubSub, store: {SomeStore, %{}})
    Config.delete()
    assert {:error, :not_started} = Config.get()
  end
end
