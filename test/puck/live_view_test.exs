defmodule Puck.LiveViewTest do
  use ExUnit.Case, async: false

  alias Puck.Backends.Mock
  alias Puck.{Client, Context, Response}
  alias Puck.LiveView.Store.ETS, as: ETSStore

  @pubsub Puck.LiveViewTest.PubSub
  @table Puck.LiveViewTest.Store
  @registry Puck.LiveView.Registry

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})

    start_supervised!(
      {Puck.LiveView,
       pubsub: @pubsub,
       sweep_interval: :timer.minutes(10),
       store: {Puck.LiveView.Store.ETS, session_table: @table}}
    )

    :ets.delete_all_objects(@table)
    flush_mailbox()
    :ok
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{}
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  describe "assign_defaults/3" do
    test "sets all default assigns" do
      client = Client.new({Mock, response: "test"})
      socket = Puck.LiveView.assign_defaults(build_socket(), client)

      assert socket.assigns.puck_client == client
      assert socket.assigns.puck_context == Context.new()
      assert socket.assigns.puck_stream_id == nil
      assert socket.assigns.puck_content == ""
      assert socket.assigns.puck_thinking == ""
      assert socket.assigns.puck_markdown == ""
      assert socket.assigns.puck_status == :idle
      assert socket.assigns.puck_error == nil
    end

    test "accepts custom context" do
      client = Client.new({Mock, response: "test"})
      context = Context.new(metadata: %{session: "abc"})
      socket = Puck.LiveView.assign_defaults(build_socket(), client, context: context)

      assert socket.assigns.puck_context == context
    end
  end

  describe "send_message/3" do
    test "starts streaming and updates assigns" do
      client = Client.new({Mock, stream_chunks: ["hello", " ", "world"]})

      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.send_message("test")

      assert socket.assigns.puck_status == :streaming
      assert socket.assigns.puck_stream_id != nil
      assert socket.assigns.puck_content == ""

      assert_receive {:puck, {:chunk, :content, _}}, 1000
      assert_receive {:puck, {:done, %Response{}, %Context{}}}, 1000
    end

    test "accepts custom stream_id" do
      client = Client.new({Mock, stream_chunks: ["a"]})

      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.send_message("test", stream_id: "custom-123")

      assert socket.assigns.puck_stream_id == "custom-123"
      assert_receive {:puck, {:done, _, _}}, 1000
    end

    test "unsubscribes from previous stream on new send" do
      client = Client.new({Mock, stream_chunks: ["a"]})

      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.send_message("first")

      first_id = socket.assigns.puck_stream_id
      assert_receive {:puck, {:done, _, _}}, 1000

      socket = Puck.LiveView.send_message(socket, "second")
      second_id = socket.assigns.puck_stream_id
      assert first_id != second_id

      assert_receive {:puck, {:done, _, _}}, 1000
    end

    test "supports call mode" do
      client = Client.new({Mock, response: "call result"})

      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.send_message("test", mode: :call)

      assert_receive {:puck, {:done, response, _ctx}}, 1000
      assert response.content == "call result"
    end

    test "supports markdown render function" do
      client = Client.new({Mock, stream_chunks: ["hello"]})
      render = fn text -> "<b>#{text}</b>" end

      build_socket()
      |> Puck.LiveView.assign_defaults(client)
      |> Puck.LiveView.send_message("test", markdown: render)

      assert_receive {:puck, {:chunk, :markdown, "<b>hello</b>"}}, 1000
    end

    test "returns error assigns instead of crashing when stream start fails" do
      client = Client.new({Mock, response: "slow", delay: 300})

      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.send_message("first", stream_id: "duplicate-id", mode: :call)

      assert socket.assigns.puck_status == :streaming

      second_socket =
        Puck.LiveView.send_message(socket, "second", stream_id: "duplicate-id", mode: :call)

      assert second_socket.assigns.puck_status == :error
      assert {:failed_to_start_stream, _reason} = second_socket.assigns.puck_error
      assert second_socket.assigns.puck_stream_id == "duplicate-id"
    end
  end

  describe "subscribe/2" do
    test "reconnects to completed stream" do
      client = Client.new({Mock, response: "x"})
      stream_id = "completed-stream"

      :ok =
        ETSStore.put_stream(%{session_table: @table, registry: @registry}, stream_id, %{
          content: "hello world",
          thinking: "",
          markdown: "",
          status: :done,
          error: nil
        })

      new_socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.subscribe(stream_id)

      assert new_socket.assigns.puck_status == :done
      assert new_socket.assigns.puck_content == "hello world"
      assert new_socket.assigns.puck_stream_id == stream_id
    end

    test "returns not_found for missing stream" do
      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(Client.new({Mock, response: "x"}))
        |> Puck.LiveView.subscribe("nonexistent")

      assert socket.assigns.puck_status == :not_found
    end

    test "unsubscribes previous topic before subscribing to new stream" do
      client = Client.new({Mock, response: "x"})
      stream_1 = "stream-1"
      stream_2 = "stream-2"

      store = %{session_table: @table, registry: @registry}

      :ok = ETSStore.put_stream(store, stream_1, %{status: :done, error: nil})
      :ok = ETSStore.put_stream(store, stream_2, %{status: :done, error: nil})

      _socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.subscribe(stream_1)
        |> Puck.LiveView.subscribe(stream_2)

      Phoenix.PubSub.broadcast(
        @pubsub,
        "puck:stream:#{stream_1}",
        {:puck, {:chunk, :content, "stale"}}
      )

      refute_receive {:puck, {:chunk, :content, "stale"}}, 100
    end

    test "returns error when store read fails" do
      :ets.delete(@table)

      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(Client.new({Mock, response: "x"}))
        |> Puck.LiveView.subscribe("any-id")

      assert socket.assigns.puck_status == :error
      assert {:failed_to_load_stream, _reason} = socket.assigns.puck_error

      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    test "expired stream becomes not_found after retention window" do
      client = Client.new({Mock, stream_chunks: ["ok"]})

      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.send_message("test")

      stream_id = socket.assigns.puck_stream_id
      assert_receive {:puck, {:done, _, _}}, 1000

      Process.sleep(20)

      :ok = ETSStore.sweep(%{session_table: @table, registry: @registry}, retention_ms: 1)

      new_socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.subscribe(stream_id)

      assert new_socket.assigns.puck_status == :not_found
    end
  end

  describe "handle_event/2" do
    test "handles content chunk" do
      socket = Puck.LiveView.handle_event({:chunk, :content, "hi"}, build_socket())
      assert socket.assigns.puck_content == "hi"
    end

    test "handles thinking chunk" do
      socket = Puck.LiveView.handle_event({:chunk, :thinking, "hmm"}, build_socket())
      assert socket.assigns.puck_thinking == "hmm"
    end

    test "handles markdown chunk" do
      socket = Puck.LiveView.handle_event({:chunk, :markdown, "<p>hi</p>"}, build_socket())
      assert socket.assigns.puck_markdown == "<p>hi</p>"
    end

    test "handles done event" do
      context = Context.new(metadata: %{done: true})
      response = Response.new(content: "done")
      socket = Puck.LiveView.handle_event({:done, response, context}, build_socket())

      assert socket.assigns.puck_status == :done
      assert socket.assigns.puck_context == context
    end

    test "handles error event" do
      socket = Puck.LiveView.handle_event({:error, :timeout}, build_socket())

      assert socket.assigns.puck_status == :error
      assert socket.assigns.puck_error == :timeout
    end

    test "handles cancelled event" do
      socket = Puck.LiveView.handle_event({:cancelled, "partial"}, build_socket())
      assert socket.assigns.puck_status == :cancelled
    end
  end

  describe "streaming?/1" do
    test "true when streaming" do
      socket = Phoenix.Component.assign(build_socket(), puck_status: :streaming)
      assert Puck.LiveView.streaming?(socket)
    end

    test "false when idle" do
      socket = Phoenix.Component.assign(build_socket(), puck_status: :idle)
      refute Puck.LiveView.streaming?(socket)
    end

    test "false when done" do
      socket = Phoenix.Component.assign(build_socket(), puck_status: :done)
      refute Puck.LiveView.streaming?(socket)
    end
  end

  describe "cancel/1" do
    test "cancels an active stream" do
      client = Client.new({Mock, response: "slow", delay: 500})

      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(client)
        |> Puck.LiveView.send_message("test", mode: :call)

      Process.sleep(50)
      cancelled_socket = Puck.LiveView.cancel(socket)

      assert cancelled_socket.assigns.puck_status == :cancelled

      assert_receive {:puck, {:cancelled, _}}, 1000
    end

    test "no-op when no stream active" do
      socket =
        build_socket()
        |> Puck.LiveView.assign_defaults(Client.new({Mock, response: "x"}))

      cancelled_socket = Puck.LiveView.cancel(socket)
      assert cancelled_socket.assigns.puck_status == :cancelled
    end
  end
end
