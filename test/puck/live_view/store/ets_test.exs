defmodule Puck.LiveView.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Puck.LiveView.Store.ETS, as: ETSStore

  defp table_name(suffix) do
    :"puck_store_#{suffix}_#{System.unique_integer([:positive])}"
  end

  test "puts and gets stream snapshot" do
    {:ok, config} = ETSStore.init(session_table: table_name("sessions"))

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
    {:ok, config} = ETSStore.init(session_table: table_name("sessions"))

    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming, content: "hello"})
    :ok = ETSStore.put_stream(config, "stream-1", %{status: :done, content: "hello world"})

    assert {:ok, state} = ETSStore.get_stream(config, "stream-1")
    assert state.status == :done
    assert state.content == "hello world"
  end

  test "deletes stream" do
    {:ok, config} = ETSStore.init(session_table: table_name("sessions"))
    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming})
    :ok = ETSStore.delete_stream(config, "stream-1")
    assert :not_found = ETSStore.get_stream(config, "stream-1")
  end

  test "sweep deletes stale stream without active process" do
    {:ok, config} = ETSStore.init(session_table: table_name("sessions"))
    :ok = ETSStore.put_stream(config, "stream-1", %{status: :done, content: "x"})
    Process.sleep(10)
    :ok = ETSStore.sweep(config, retention_ms: 1)
    assert :not_found = ETSStore.get_stream(config, "stream-1")
  end
end
