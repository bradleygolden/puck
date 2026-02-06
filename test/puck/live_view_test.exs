defmodule Puck.LiveViewTest do
  use ExUnit.Case, async: false

  alias Puck.Backends.Mock
  alias Puck.{Client, Context, Response}

  @pubsub Puck.LiveViewTest.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    start_supervised!(Puck.LiveView)
    flush_mailbox()
    :ok
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  describe "start_stream/4" do
    test "returns {:ok, stream_id} and delivers content + done messages" do
      client = Client.new({Mock, stream_chunks: ["hello", " ", "world"]})

      {:ok, stream_id} =
        Puck.LiveView.start_stream(client, "test", Context.new(), pubsub: @pubsub)

      assert is_binary(stream_id)

      assert_receive {:puck_stream, ^stream_id, {:content, %{content: "hello"}}}, 1000
      assert_receive {:puck_stream, ^stream_id, {:content, %{content: " "}}}, 1000
      assert_receive {:puck_stream, ^stream_id, {:content, %{content: "world"}}}, 1000
      assert_receive {:puck_stream, ^stream_id, {:done, %Response{}, %Context{}}}, 1000
    end

    test "chunks include backend metadata" do
      client = Client.new({Mock, stream_chunks: ["hi"]})

      {:ok, id} = Puck.LiveView.start_stream(client, "test", Context.new(), pubsub: @pubsub)

      assert_receive {:puck_stream, ^id, {:content, chunk}}, 1000
      assert chunk.type == :content
      assert chunk.content == "hi"
      assert chunk.metadata == %{partial: true, backend: :mock}
      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end

    test "accepts custom :stream_id" do
      client = Client.new({Mock, stream_chunks: ["a"]})

      {:ok, "custom-123"} =
        Puck.LiveView.start_stream(client, "test", Context.new(),
          pubsub: @pubsub,
          stream_id: "custom-123"
        )

      assert_receive {:puck_stream, "custom-123", {:done, _, _}}, 1000
    end

    test "done message includes Response with accumulated content" do
      client = Client.new({Mock, stream_chunks: ["hello", " ", "world"]})

      {:ok, id} = Puck.LiveView.start_stream(client, "test", Context.new(), pubsub: @pubsub)

      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert response.content == "hello world"
      assert response.finish_reason == :stop
    end

    test "done message includes metadata from last chunk" do
      client = Client.new({Mock, stream_chunks: ["hi"]})

      {:ok, id} = Puck.LiveView.start_stream(client, "test", Context.new(), pubsub: @pubsub)

      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert response.metadata == %{partial: true, backend: :mock}
    end

    test "done message includes updated context with assistant message" do
      client = Client.new({Mock, stream_chunks: ["hi"]})
      ctx = Context.new()

      {:ok, id} = Puck.LiveView.start_stream(client, "test", ctx, pubsub: @pubsub)

      assert_receive {:puck_stream, ^id, {:done, _response, context}}, 1000
      assert context.messages != []
    end

    test "backend error broadcasts {:error, reason}" do
      client = Client.new({Mock, error: :rate_limited})

      {:ok, id} = Puck.LiveView.start_stream(client, "test", Context.new(), pubsub: @pubsub)

      assert_receive {:puck_stream, ^id, {:error, :rate_limited}}, 1000
    end

    test "multiple concurrent streams" do
      client1 = Client.new({Mock, stream_chunks: ["one"]})
      client2 = Client.new({Mock, stream_chunks: ["two"]})

      {:ok, id1} = Puck.LiveView.start_stream(client1, "test", Context.new(), pubsub: @pubsub)
      {:ok, id2} = Puck.LiveView.start_stream(client2, "test", Context.new(), pubsub: @pubsub)

      assert id1 != id2

      assert_receive {:puck_stream, ^id1, {:done, r1, _}}, 1000
      assert_receive {:puck_stream, ^id2, {:done, r2, _}}, 1000

      assert r1.content == "one"
      assert r2.content == "two"
    end

    test "raises on missing :pubsub" do
      client = Client.new({Mock, stream_chunks: ["a"]})

      assert_raise KeyError, ~r/:pubsub/, fn ->
        Puck.LiveView.start_stream(client, "test", Context.new(), [])
      end
    end

    test "timeout auto-cancels the stream" do
      client = Client.new({Mock, response: "slow", delay: 2000})

      {:ok, id} =
        Puck.LiveView.start_stream(client, "test", Context.new(),
          pubsub: @pubsub,
          timeout: 50
        )

      assert_receive {:puck_stream, ^id, {:cancelled, _}}, 1000
    end
  end

  describe "cancel/1" do
    test "broadcasts {:cancelled, content} for active stream" do
      client = Client.new({Mock, response: "slow", delay: 500})

      {:ok, id} =
        Puck.LiveView.start_stream(client, "test", Context.new(), pubsub: @pubsub)

      poll_until(fn ->
        Registry.lookup(Puck.LiveView.Registry, id) != []
      end)

      Puck.LiveView.cancel(id)

      assert_receive {:puck_stream, ^id, {:cancelled, _}}, 1000
    end

    test "no-op when stream does not exist" do
      assert :ok = Puck.LiveView.cancel("nonexistent")
    end
  end

  describe "unsubscribe/2" do
    test "stops receiving messages after unsubscribe" do
      client = Client.new({Mock, stream_chunks: ["a"]})

      {:ok, id} = Puck.LiveView.start_stream(client, "test", Context.new(), pubsub: @pubsub)
      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000

      Puck.LiveView.unsubscribe(id, pubsub: @pubsub)

      Phoenix.PubSub.broadcast(@pubsub, Puck.LiveView.topic(id), {:puck_stream, id, :test})
      refute_receive {:puck_stream, ^id, :test}, 100
    end
  end

  defp poll_until(fun, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: raise("poll timed out")
      Process.sleep(1)
      do_poll(fun, deadline)
    end
  end
end
