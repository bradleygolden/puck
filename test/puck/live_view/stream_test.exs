defmodule Puck.LiveView.StreamTest do
  use ExUnit.Case, async: false

  alias Puck.Backends.Mock
  alias Puck.{Client, Context, Response}
  alias Puck.LiveView.Stream, as: StreamServer

  @pubsub Puck.LiveView.StreamTest.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    start_supervised!(Puck.LiveView)
    flush_mailbox()
    :ok
  end

  defp start_stream(opts \\ []) do
    stream_id = Keyword.get_lazy(opts, :stream_id, &random_id/0)

    client =
      Keyword.get(opts, :client, Client.new({Mock, stream_chunks: ["hello", " ", "world"]}))

    context = Keyword.get(opts, :context, Context.new())
    stream_opts = Keyword.get(opts, :stream_opts, [])
    timeout = Keyword.get(opts, :timeout)

    Phoenix.PubSub.subscribe(@pubsub, "puck:stream:#{stream_id}")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Puck.LiveView.DynamicSupervisor,
        {StreamServer,
         [
           stream_id: stream_id,
           pubsub: @pubsub,
           task_supervisor: Puck.LiveView.TaskSupervisor,
           registry: Puck.LiveView.Registry,
           client: client,
           prompt: "test message",
           context: context,
           timeout: timeout,
           stream_opts: stream_opts
         ]}
      )

    %{stream_id: stream_id, pid: pid}
  end

  defp random_id, do: Base.encode64(:crypto.strong_rand_bytes(8), padding: false)

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
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

  defp start_fun_stream(fun, opts \\ []) do
    stream_id = Keyword.get_lazy(opts, :stream_id, &random_id/0)
    timeout = Keyword.get(opts, :timeout)

    Phoenix.PubSub.subscribe(@pubsub, "puck:stream:#{stream_id}")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Puck.LiveView.DynamicSupervisor,
        {StreamServer,
         [
           stream_id: stream_id,
           pubsub: @pubsub,
           task_supervisor: Puck.LiveView.TaskSupervisor,
           registry: Puck.LiveView.Registry,
           fun: fun,
           timeout: timeout
         ]}
      )

    %{stream_id: stream_id, pid: pid}
  end

  describe "custom function" do
    test "streams chunks and completes with done" do
      %{stream_id: id} =
        start_fun_stream(fn parent ->
          for text <- ["hello", " ", "world"] do
            send(parent, {:stream_chunk, %{type: :content, content: text}})
          end

          {:stream_done, Context.new(), %{type: :content, content: "world"}}
        end)

      assert_receive {:puck_stream, ^id, {:content, %{content: "hello"}}}, 1000
      assert_receive {:puck_stream, ^id, {:content, %{content: " "}}}, 1000
      assert_receive {:puck_stream, ^id, {:content, %{content: "world"}}}, 1000
      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert response.content == "hello world"
    end

    test "error from custom function broadcasts error" do
      %{stream_id: id} = start_fun_stream(fn _parent -> {:error, :custom_error} end)

      assert_receive {:puck_stream, ^id, {:error, :custom_error}}, 1000
    end

    test "cancel mid-stream with accumulated content" do
      %{stream_id: id} =
        start_fun_stream(fn parent ->
          send(parent, {:stream_chunk, %{type: :content, content: "partial"}})
          Process.sleep(5000)
        end)

      assert_receive {:puck_stream, ^id, {:content, %{content: "partial"}}}, 1000
      poll_until(fn -> Registry.lookup(Puck.LiveView.Registry, id) != [] end)
      StreamServer.cancel(Puck.LiveView.Registry, id)

      assert_receive {:puck_stream, ^id, {:cancelled, "partial"}}, 1000
    end

    test "timeout auto-cancels" do
      %{stream_id: id} =
        start_fun_stream(fn _parent -> Process.sleep(5000) end, timeout: 50)

      assert_receive {:puck_stream, ^id, {:cancelled, _}}, 1000
    end
  end

  describe "streaming" do
    test "broadcasts chunks tagged by their type" do
      %{stream_id: id} = start_stream()

      assert_receive {:puck_stream, ^id, {:content, %{type: :content, content: "hello"}}}, 1000
      assert_receive {:puck_stream, ^id, {:content, %{type: :content, content: " "}}}, 1000
      assert_receive {:puck_stream, ^id, {:content, %{type: :content, content: "world"}}}, 1000
      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end

    test "chunk maps preserve backend metadata" do
      %{stream_id: id} = start_stream()

      assert_receive {:puck_stream, ^id, {:content, chunk}}, 1000
      assert Map.has_key?(chunk, :metadata)
      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end

    test "done includes Response with accumulated content" do
      %{stream_id: id} = start_stream()

      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert %Response{} = response
      assert response.content == "hello world"
      assert response.finish_reason == :stop
    end

    test "done Response includes metadata from last chunk" do
      %{stream_id: id} = start_stream()

      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert response.metadata == %{partial: true, backend: :mock}
    end

    test "done includes updated Context with assistant message" do
      %{stream_id: id} = start_stream()

      assert_receive {:puck_stream, ^id, {:done, _response, context}}, 1000
      assert %Context{} = context
      assert context.messages != []
    end
  end

  describe "thinking chunks" do
    test "broadcasts thinking chunks with their type tag" do
      client = Client.new({Mock, response: "slow", delay: 300})
      %{stream_id: id, pid: pid} = start_stream(client: client)

      send(pid, {:stream_chunk, %{type: :thinking, content: "hmm"}})
      send(pid, {:stream_chunk, %{type: :thinking, content: " let me think"}})

      assert_receive {:puck_stream, ^id, {:thinking, %{type: :thinking, content: "hmm"}}}, 1000

      assert_receive {:puck_stream, ^id,
                      {:thinking, %{type: :thinking, content: " let me think"}}},
                     1000

      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end
  end

  describe "unknown chunk types" do
    test "broadcasts with the chunk's own type tag" do
      client = Client.new({Mock, response: "slow", delay: 300})
      %{stream_id: id, pid: pid} = start_stream(client: client)

      send(pid, {:stream_chunk, %{type: :tool_use, content: "calling search"}})

      assert_receive {:puck_stream, ^id,
                      {:tool_use, %{type: :tool_use, content: "calling search"}}},
                     1000

      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end

    test "chunks without a type field broadcast as :unknown" do
      client = Client.new({Mock, response: "slow", delay: 300})
      %{stream_id: id, pid: pid} = start_stream(client: client)

      send(pid, {:stream_chunk, %{data: "mystery"}})

      assert_receive {:puck_stream, ^id, {:unknown, %{data: "mystery"}}}, 1000
      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end
  end

  describe "error handling" do
    test "broadcasts error when backend fails" do
      client = Client.new({Mock, error: :rate_limited})
      %{stream_id: id} = start_stream(client: client)

      assert_receive {:puck_stream, ^id, {:error, :rate_limited}}, 1000
    end

    test "task crash broadcasts error" do
      client = Client.new({Mock, response: "slow", delay: 500})
      %{stream_id: id, pid: pid} = start_stream(client: client)

      poll_until(fn -> Registry.lookup(Puck.LiveView.Registry, id) != [] end)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    end
  end

  describe "cancellation" do
    test "cancel kills task and broadcasts cancelled with accumulated content" do
      client = Client.new({Mock, response: "slow", delay: 500})
      %{stream_id: id} = start_stream(client: client)

      poll_until(fn -> Registry.lookup(Puck.LiveView.Registry, id) != [] end)
      StreamServer.cancel(Puck.LiveView.Registry, id)

      assert_receive {:puck_stream, ^id, {:cancelled, _content}}, 1000
    end

    test "cancel on nonexistent stream is a no-op" do
      assert :ok = StreamServer.cancel(Puck.LiveView.Registry, "nonexistent")
    end
  end

  describe "timeout" do
    test "auto-cancels after timeout" do
      client = Client.new({Mock, response: "slow", delay: 2000})
      %{stream_id: id} = start_stream(client: client, timeout: 50)

      assert_receive {:puck_stream, ^id, {:cancelled, _}}, 1000
    end

    test "no timeout when option is nil" do
      %{stream_id: id} = start_stream(timeout: nil)

      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end
  end

  describe "registration" do
    test "registers in Registry by stream_id" do
      %{stream_id: id, pid: pid} = start_stream()

      assert [{^pid, _}] = Registry.lookup(Puck.LiveView.Registry, id)
      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end
  end
end
