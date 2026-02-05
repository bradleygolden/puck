defmodule Puck.LiveView.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Puck.LiveView.Store.ETS, as: ETSStore

  defp table_name(suffix) do
    :"puck_store_#{suffix}_#{System.unique_integer([:positive])}"
  end

  test "puts and gets stream state" do
    {:ok, config} =
      ETSStore.init(
        session_table: table_name("sessions"),
        chunk_table: table_name("chunks")
      )

    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming, content: ""})

    assert {:ok, state} = ETSStore.get_stream(config, "stream-1")
    assert state.status == :streaming
  end

  test "appends idempotent chunks by seq and returns ordered chunks" do
    {:ok, config} =
      ETSStore.init(
        session_table: table_name("sessions"),
        chunk_table: table_name("chunks")
      )

    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming})

    :ok =
      ETSStore.append_chunk(config, "stream-1", 2, %{type: :content, content: "b"}, %{
        content: "ab"
      })

    :ok =
      ETSStore.append_chunk(config, "stream-1", 1, %{type: :content, content: "a"}, %{
        content: "a"
      })

    :ok =
      ETSStore.append_chunk(config, "stream-1", 1, %{type: :content, content: "a"}, %{
        content: "a"
      })

    assert {:ok, chunks} = ETSStore.list_chunks(config, "stream-1")
    assert Enum.map(chunks, & &1.seq) == [1, 2]
  end

  test "marks terminal states" do
    {:ok, config} =
      ETSStore.init(
        session_table: table_name("sessions"),
        chunk_table: table_name("chunks")
      )

    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming})
    :ok = ETSStore.mark_error(config, "stream-1", :timeout, %{content: "partial"})
    assert {:ok, state} = ETSStore.get_stream(config, "stream-1")
    assert state.status == :error

    :ok = ETSStore.mark_cancelled(config, "stream-1", %{content: "partial"})
    assert {:ok, state} = ETSStore.get_stream(config, "stream-1")
    assert state.status == :cancelled

    :ok =
      ETSStore.mark_done(config, "stream-1", %{content: "done"}, %{messages: []}, %{
        content: "done"
      })

    assert {:ok, state} = ETSStore.get_stream(config, "stream-1")
    assert state.status == :done
  end

  test "deletes stream and chunks" do
    {:ok, config} =
      ETSStore.init(
        session_table: table_name("sessions"),
        chunk_table: table_name("chunks")
      )

    :ok = ETSStore.put_stream(config, "stream-1", %{status: :streaming})

    :ok =
      ETSStore.append_chunk(config, "stream-1", 1, %{type: :content, content: "x"}, %{
        content: "x"
      })

    :ok = ETSStore.delete_stream(config, "stream-1")

    assert :not_found = ETSStore.get_stream(config, "stream-1")
    assert {:ok, []} = ETSStore.list_chunks(config, "stream-1")
  end
end
