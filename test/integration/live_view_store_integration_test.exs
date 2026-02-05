defmodule Puck.Integration.LiveViewStoreTest do
  use ExUnit.Case, async: false

  alias Puck.Backends.Mock
  alias Puck.{Client, Context}

  @moduletag :integration
  @pubsub Puck.Integration.LiveViewStoreTest.PubSub

  defmodule InstrumentedStore do
    @behaviour Puck.LiveView.Store

    alias Puck.LiveView.Store.ETS, as: ETSStore

    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)

      session_table = :"puck_integration_sessions_#{System.unique_integer([:positive])}"
      chunk_table = :"puck_integration_chunks_#{System.unique_integer([:positive])}"

      with {:ok, ets_config} <-
             ETSStore.init(
               session_table: session_table,
               chunk_table: chunk_table,
               registry: Keyword.get(opts, :registry)
             ) do
        {:ok, %{test_pid: test_pid, ets: ets_config}}
      end
    end

    def put_stream(config, stream_id, attrs) do
      send(config.test_pid, {:store, :put_stream, stream_id, attrs})
      ETSStore.put_stream(config.ets, stream_id, attrs)
    end

    def append_chunk(config, stream_id, seq, chunk, snapshot) do
      send(config.test_pid, {:store, :append_chunk, stream_id, seq, chunk})
      ETSStore.append_chunk(config.ets, stream_id, seq, chunk, snapshot)
    end

    def mark_done(config, stream_id, response, context, snapshot) do
      send(config.test_pid, {:store, :mark_done, stream_id, response, context})
      ETSStore.mark_done(config.ets, stream_id, response, context, snapshot)
    end

    def mark_error(config, stream_id, reason, snapshot) do
      send(config.test_pid, {:store, :mark_error, stream_id, reason})
      ETSStore.mark_error(config.ets, stream_id, reason, snapshot)
    end

    def mark_cancelled(config, stream_id, snapshot) do
      send(config.test_pid, {:store, :mark_cancelled, stream_id})
      ETSStore.mark_cancelled(config.ets, stream_id, snapshot)
    end

    def get_stream(config, stream_id), do: ETSStore.get_stream(config.ets, stream_id)
    def list_chunks(config, stream_id), do: ETSStore.list_chunks(config.ets, stream_id)
    def delete_stream(config, stream_id), do: ETSStore.delete_stream(config.ets, stream_id)
    def sweep(config, opts), do: ETSStore.sweep(config.ets, opts)
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})

    start_supervised!(
      {Puck.LiveView,
       pubsub: @pubsub,
       sweep_interval: :timer.minutes(10),
       store: {InstrumentedStore, test_pid: self()}}
    )

    :ok
  end

  defp build_socket, do: %Phoenix.LiveView.Socket{}

  test "uses configured store for stream lifecycle and reconnect state" do
    client = Client.new({Mock, stream_chunks: ["hello", " ", "world"]})

    socket =
      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.send_message("test")

    stream_id = socket.assigns.puck_stream_id
    assert_receive {:store, :put_stream, ^stream_id, _attrs}, 1000
    assert_receive {:store, :append_chunk, ^stream_id, 1, _chunk}, 1000
    assert_receive {:store, :append_chunk, ^stream_id, 2, _chunk}, 1000
    assert_receive {:store, :append_chunk, ^stream_id, 3, _chunk}, 1000
    assert_receive {:store, :mark_done, ^stream_id, _response, %Context{}}, 1000
    assert_receive {:puck, {:done, _response, _context}}, 1000

    reconnected =
      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.subscribe(stream_id)

    assert reconnected.assigns.puck_status == :done
    assert reconnected.assigns.puck_content == "hello world"
  end

  test "uses configured store for cancellation" do
    client = Client.new({Mock, response: "slow", delay: 500})

    socket =
      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.send_message("test", mode: :call)

    stream_id = socket.assigns.puck_stream_id
    Process.sleep(50)
    _cancelled_socket = Puck.LiveView.cancel(socket)

    assert_receive {:store, :mark_cancelled, ^stream_id}, 1000
    assert_receive {:puck, {:cancelled, _}}, 1000
  end
end
