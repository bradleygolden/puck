defmodule Puck.LiveView.StreamTest do
  use ExUnit.Case, async: false

  alias Puck.Backends.Mock
  alias Puck.{Client, Context}
  alias Puck.LiveView.Store.ETS, as: ETSStore
  alias Puck.LiveView.Stream, as: StreamServer

  @pubsub Puck.LiveView.StreamTest.PubSub
  @table Puck.LiveView.StreamTest.Store
  @registry Puck.LiveView.Registry
  @dynamic_supervisor Puck.LiveView.DynamicSupervisor
  @task_supervisor Puck.LiveView.TaskSupervisor

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

  defp start_stream(opts \\ []) do
    stream_id = Keyword.get_lazy(opts, :stream_id, fn -> random_id() end)

    client =
      Keyword.get(opts, :client, Client.new({Mock, stream_chunks: ["hello", " ", "world"]}))

    context = Keyword.get(opts, :context, Context.new())
    mode = Keyword.get(opts, :mode, :stream)
    render_fn = Keyword.get(opts, :markdown)
    on_chunk = Keyword.get(opts, :on_chunk)
    on_done = Keyword.get(opts, :on_done)
    on_error = Keyword.get(opts, :on_error)

    Phoenix.PubSub.subscribe(@pubsub, "puck:stream:#{stream_id}")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        @dynamic_supervisor,
        {StreamServer,
         [
           stream_id: stream_id,
           pubsub: @pubsub,
           store: {Puck.LiveView.Store.ETS, %{session_table: @table, registry: @registry}},
           task_supervisor: @task_supervisor,
           registry: @registry,
           client: client,
           content: "test message",
           context: context,
           mode: mode,
           markdown: render_fn,
           on_chunk: on_chunk,
           on_done: on_done,
           on_error: on_error,
           stream_opts: []
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

  defp fetch_stream!(stream_id) do
    {:ok, stream} =
      ETSStore.get_stream(%{session_table: @table, registry: @registry}, stream_id)

    stream
  end

  describe "streaming" do
    test "accumulates content and broadcasts chunks" do
      %{stream_id: id} = start_stream()

      assert_receive {:puck, {:chunk, :content, "hello"}}, 1000
      assert_receive {:puck, {:chunk, :content, "hello "}}, 1000
      assert_receive {:puck, {:chunk, :content, "hello world"}}, 1000
      assert_receive {:puck, {:done, response, context}}, 1000

      assert response.content == "hello world"
      assert response.finish_reason == :stop
      assert %Context{} = context

      entry = fetch_stream!(id)
      assert entry.status == :done
      assert entry.content == "hello world"
    end

    test "writes initial ETS entry as streaming" do
      client = Client.new({Mock, response: "slow", delay: 200})
      %{stream_id: id} = start_stream(client: client, mode: :call)

      Process.sleep(50)
      entry = fetch_stream!(id)
      assert entry.status == :streaming
    end

    test "renders markdown when function provided" do
      render_fn = fn text -> "<p>#{text}</p>" end
      %{stream_id: id} = start_stream(markdown: render_fn)

      assert_receive {:puck, {:chunk, :markdown, _}}, 1000
      assert_receive {:puck, {:done, _, _}}, 1000

      entry = fetch_stream!(id)
      assert entry.markdown == "<p>hello world</p>"
    end

    test "calls on_done callback" do
      test_pid = self()
      on_done = fn response, snapshot -> send(test_pid, {:callback_done, response, snapshot}) end
      start_stream(on_done: on_done)

      assert_receive {:callback_done, response, snapshot}, 1000
      assert response.content == "hello world"
      assert snapshot.content == "hello world"
    end

    test "calls on_chunk callback for each chunk" do
      test_pid = self()
      on_chunk = fn _chunk, snapshot -> send(test_pid, {:callback_chunk, snapshot.content}) end
      start_stream(on_chunk: on_chunk)

      assert_receive {:callback_chunk, "hello"}, 1000
      assert_receive {:callback_chunk, "hello "}, 1000
      assert_receive {:callback_chunk, "hello world"}, 1000
    end

    test "callback exceptions do not crash the GenServer" do
      on_chunk = fn _, _ -> raise "boom" end
      %{stream_id: id} = start_stream(on_chunk: on_chunk)

      assert_receive {:puck, {:done, _, _}}, 1000
      entry = fetch_stream!(id)
      assert entry.status == :done
    end
  end

  describe "call mode" do
    test "sends done with response from Puck.call" do
      client = Client.new({Mock, response: "call result"})
      start_stream(client: client, mode: :call)

      assert_receive {:puck, {:done, response, context}}, 1000
      assert response.content == "call result"
      assert %Context{} = context
    end
  end

  describe "thinking chunks" do
    test "accumulates thinking content and broadcasts" do
      client = Client.new({Mock, response: "slow", delay: 300})
      %{stream_id: id, pid: pid} = start_stream(client: client, mode: :call)

      send(pid, {:stream_chunk, %{type: :thinking, content: "hmm"}})
      send(pid, {:stream_chunk, %{type: :thinking, content: " let me think"}})

      assert_receive {:puck, {:chunk, :thinking, "hmm"}}, 1000
      assert_receive {:puck, {:chunk, :thinking, "hmm let me think"}}, 1000

      entry = fetch_stream!(id)
      assert entry.thinking == "hmm let me think"

      assert_receive {:puck, {:done, _, _}}, 1000
    end
  end

  describe "unknown chunk types" do
    test "does not crash the GenServer" do
      client = Client.new({Mock, response: "slow", delay: 200})
      %{pid: pid} = start_stream(client: client, mode: :call)

      send(pid, {:stream_chunk, %{type: :unknown, content: "mystery"}})

      assert_receive {:puck, {:done, _, _}}, 1000
    end
  end

  describe "error handling" do
    test "broadcasts error when backend fails" do
      client = Client.new({Mock, error: :rate_limited})
      %{stream_id: id} = start_stream(client: client)

      assert_receive {:puck, {:error, _reason}}, 1000

      entry = fetch_stream!(id)
      assert entry.status == :error
      assert entry.error != nil
    end

    test "calls on_error callback with snapshot" do
      test_pid = self()

      on_error = fn reason, snapshot ->
        send(test_pid, {:callback_error, reason, snapshot})
      end

      client = Client.new({Mock, error: :rate_limited})
      start_stream(client: client, on_error: on_error)

      assert_receive {:callback_error, _reason, snapshot}, 1000
      assert Map.has_key?(snapshot, :stream_id)
      assert Map.has_key?(snapshot, :content)
    end
  end

  describe "cancellation" do
    test "broadcasts cancelled when task is killed" do
      client = Client.new({Mock, response: "slow", delay: 500})
      %{stream_id: id} = start_stream(client: client, mode: :call)

      Process.sleep(50)
      StreamServer.cancel(@registry, id)

      assert_receive {:puck, {:cancelled, _}}, 1000

      entry = fetch_stream!(id)
      assert entry.status == :cancelled
    end

    test "cancel on nonexistent stream is a no-op" do
      assert :ok = StreamServer.cancel(@registry, "nonexistent")
    end
  end

  describe "registration" do
    test "registers in Registry by stream_id" do
      %{stream_id: id, pid: pid} = start_stream()

      assert [{^pid, _}] = Registry.lookup(@registry, id)
      assert_receive {:puck, {:done, _, _}}, 1000
    end
  end
end
