defmodule Puck.LiveView.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Puck.LiveView.Store.ETS, as: ETSStore

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp init_store do
    registry = unique_name("registry")
    start_supervised!({Registry, keys: :unique, name: registry})
    {:ok, config} = ETSStore.init(session_table: unique_name("sessions"), registry: registry)
    {config, registry}
  end

  test "puts and gets stream snapshot" do
    {config, _registry} = init_store()

    :ok =
      ETSStore.put_stream(config, "stream-1", %{
        status: :streaming,
        content: "",
        error: nil
      })

    assert {:ok, state} = ETSStore.get_stream(config, "stream-1")
    assert state.status == :streaming
  end

  test "updates stream by writing latest snapshot" do
    {config, _registry} = init_store()

    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming, content: "hello"})
    :ok = ETSStore.put_stream(config, "stream-1", %{status: :done, content: "hello world"})

    assert {:ok, state} = ETSStore.get_stream(config, "stream-1")
    assert state.status == :done
    assert state.content == "hello world"
  end

  test "deletes stream" do
    {config, _registry} = init_store()
    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming})
    :ok = ETSStore.delete_stream(config, "stream-1")
    assert :not_found = ETSStore.get_stream(config, "stream-1")
  end

  test "sweep deletes stale stream without active process" do
    {config, _registry} = init_store()
    :ok = ETSStore.put_stream(config, "stream-1", %{status: :done, content: "x"})
    Process.sleep(10)
    :ok = ETSStore.sweep(config, retention_ms: 1)
    assert :not_found = ETSStore.get_stream(config, "stream-1")
  end

  test "sweep preserves stale stream with active registered process" do
    {config, registry} = init_store()
    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming, content: "x"})
    Registry.register(registry, "stream-1", nil)
    Process.sleep(10)
    :ok = ETSStore.sweep(config, retention_ms: 1)
    assert {:ok, _} = ETSStore.get_stream(config, "stream-1")
  end

  test "get_stream returns error for non-existent table" do
    config = %{session_table: :nonexistent_table, registry: :nonexistent_registry}
    assert {:error, %ArgumentError{}} = ETSStore.get_stream(config, "stream-1")
  end

  test "delete_stream raises for non-existent table" do
    config = %{session_table: :nonexistent_table, registry: :nonexistent_registry}

    assert_raise ArgumentError, fn ->
      ETSStore.delete_stream(config, "stream-1")
    end
  end

  test "put_stream raises for non-existent table" do
    config = %{session_table: :nonexistent_table, registry: :nonexistent_registry}

    assert_raise ArgumentError, fn ->
      ETSStore.put_stream(config, "stream-1", %{status: :done})
    end
  end

  test "init is idempotent" do
    table = unique_name("idempotent")
    registry = unique_name("registry")
    start_supervised!({Registry, keys: :unique, name: registry})

    {:ok, config1} = ETSStore.init(session_table: table, registry: registry)
    {:ok, config2} = ETSStore.init(session_table: table, registry: registry)

    assert config1 == config2

    :ok = ETSStore.put_stream(config1, "stream-1", %{status: :done})
    assert {:ok, _} = ETSStore.get_stream(config2, "stream-1")
  end
end
