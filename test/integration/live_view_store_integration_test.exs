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

      with {:ok, ets_config} <-
             ETSStore.init(
               session_table: session_table,
               registry: Keyword.get(opts, :registry)
             ) do
        {:ok, %{test_pid: test_pid, ets: ets_config}}
      end
    end

    def put_stream(config, stream_id, attrs) do
      :ok = ETSStore.put_stream(config.ets, stream_id, attrs)
      send(config.test_pid, {:store, :put_stream, stream_id, attrs})
      :ok
    end

    def get_stream(config, stream_id), do: ETSStore.get_stream(config.ets, stream_id)
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

  defp await_reconnect_status(client, stream_id, expected, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_reconnect_status(client, stream_id, expected, deadline)
  end

  defp do_await_reconnect_status(client, stream_id, expected, deadline) do
    socket =
      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.subscribe(stream_id)

    if socket.assigns.puck_status == expected do
      socket
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("stream #{stream_id} did not reach status #{inspect(expected)}")
      else
        Process.sleep(10)
        do_await_reconnect_status(client, stream_id, expected, deadline)
      end
    end
  end

  test "uses configured store for stream lifecycle and reconnect state" do
    client = Client.new({Mock, stream_chunks: ["hello", " ", "world"]})

    socket =
      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.send_message("test")

    stream_id = socket.assigns.puck_stream_id
    assert_receive {:store, :put_stream, ^stream_id, _attrs}, 1000
    assert_receive {:store, :put_stream, ^stream_id, %{status: :streaming}}, 1000
    assert_receive {:store, :put_stream, ^stream_id, %{status: :streaming}}, 1000
    assert_receive {:store, :put_stream, ^stream_id, %{status: :done, context: %Context{}}}, 1000
    assert_receive {:puck, {:done, _response, _context}}, 1000

    reconnected = await_reconnect_status(client, stream_id, :done)

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

    assert_receive {:store, :put_stream, ^stream_id, %{status: :cancelled}}, 1000
    assert_receive {:puck, {:cancelled, _}}, 1000
  end

  test "persists error status through custom store" do
    client = Client.new({Mock, error: :rate_limited})

    socket =
      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.send_message("test")

    stream_id = socket.assigns.puck_stream_id
    assert_receive {:store, :put_stream, ^stream_id, %{status: :error}}, 1000
    assert_receive {:puck, {:error, _}}, 1000
  end

  test "call mode completion persists through custom store" do
    client = Client.new({Mock, response: "call result"})

    socket =
      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.send_message("test", mode: :call)

    stream_id = socket.assigns.puck_stream_id
    assert_receive {:store, :put_stream, ^stream_id, %{status: :done}}, 1000
    assert_receive {:puck, {:done, response, _context}}, 1000
    assert response.content == "call result"

    reconnected = await_reconnect_status(client, stream_id, :done)
    assert reconnected.assigns.puck_content == "call result"
  end
end
