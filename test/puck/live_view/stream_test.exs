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

    test "context returned from function is passed through unmodified" do
      empty_context = Context.new()

      %{stream_id: id} =
        start_fun_stream(fn parent ->
          send(parent, {:stream_chunk, %{type: :content, content: "hello"}})
          {:stream_done, empty_context, %{type: :content, content: "hello"}}
        end)

      assert_receive {:puck_stream, ^id, {:done, _response, context}}, 1000
      assert context == empty_context
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

    test "finish_reason from last chunk propagates to Response" do
      %{stream_id: id} =
        start_fun_stream(fn parent ->
          chunk = %{type: :content, content: "truncated", finish_reason: :max_tokens}
          send(parent, {:stream_chunk, chunk})
          {:stream_done, Context.new(), chunk}
        end)

      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert response.finish_reason == :max_tokens
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

  describe "structured output" do
    defmodule Person do
      @moduledoc false
      defstruct [:name, :age]
    end

    defp person_schema do
      Zoi.struct(
        Person,
        %{
          name: Zoi.string(),
          age: Zoi.integer()
        },
        coerce: true
      )
    end

    test "start_stream/4 with output_schema parses chunks into structs" do
      client =
        Client.new(
          {Mock,
           stream_chunks: [
             ~s|{"name":"Alice","age":30}|,
             ~s|{"name":"Alice","age":30}|
           ]}
        )

      %{stream_id: id} =
        start_stream(client: client, stream_opts: [output_schema: person_schema()])

      assert_receive {:puck_stream, ^id, {:content, %{content: %Person{name: "Alice", age: 30}}}},
                     1000

      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert %Person{name: "Alice", age: 30} = response.content
    end

    test "custom function sending struct chunks accumulates to last struct" do
      %{stream_id: id} =
        start_fun_stream(fn parent ->
          send(
            parent,
            {:stream_chunk, %{type: :content, content: %Person{name: "Alice", age: 30}}}
          )

          send(
            parent,
            {:stream_chunk, %{type: :content, content: %Person{name: "Bob", age: 25}}}
          )

          {:stream_done, Context.new(), %{type: :content, content: %Person{name: "Bob", age: 25}}}
        end)

      assert_receive {:puck_stream, ^id, {:content, %{content: %Person{name: "Alice"}}}}, 1000
      assert_receive {:puck_stream, ^id, {:content, %{content: %Person{name: "Bob"}}}}, 1000
      assert_receive {:puck_stream, ^id, {:done, response, _context}}, 1000
      assert %Person{name: "Bob", age: 25} = response.content
    end

    test "cancel with struct content returns accumulated struct" do
      %{stream_id: id} =
        start_fun_stream(fn parent ->
          send(
            parent,
            {:stream_chunk, %{type: :content, content: %Person{name: "Alice", age: 30}}}
          )

          Process.sleep(5000)
        end)

      assert_receive {:puck_stream, ^id, {:content, %{content: %Person{name: "Alice"}}}}, 1000
      poll_until(fn -> Registry.lookup(Puck.LiveView.Registry, id) != [] end)
      StreamServer.cancel(Puck.LiveView.Registry, id)

      assert_receive {:puck_stream, ^id, {:cancelled, %Person{name: "Alice", age: 30}}}, 1000
    end
  end

  describe "registration" do
    test "registers in Registry by stream_id" do
      %{stream_id: id, pid: pid} = start_stream()

      assert [{^pid, _}] = Registry.lookup(Puck.LiveView.Registry, id)
      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
    end
  end

  describe "handler" do
    defmodule FullHandler do
      @behaviour Puck.LiveView.Handler

      @impl true
      def on_chunk(chunk, %{agent: agent} = state) do
        Agent.update(agent, fn calls -> [{:on_chunk, chunk} | calls] end)
        {:cont, %{state | chunks: [chunk | Map.get(state, :chunks, [])]}}
      end

      @impl true
      def on_done(response, context, %{agent: agent}) do
        Agent.update(agent, fn calls -> [{:on_done, response, context} | calls] end)
        :ok
      end

      @impl true
      def on_error(reason, %{agent: agent}) do
        Agent.update(agent, fn calls -> [{:on_error, reason} | calls] end)
        :ok
      end

      @impl true
      def on_cancel(content, %{agent: agent}) do
        Agent.update(agent, fn calls -> [{:on_cancel, content} | calls] end)
        :ok
      end
    end

    defmodule DoneOnlyHandler do
      @behaviour Puck.LiveView.Handler

      @impl true
      def on_done(response, _context, %{agent: agent}) do
        Agent.update(agent, fn calls -> [{:on_done, response} | calls] end)
        :ok
      end
    end

    defmodule CrashingHandler do
      @behaviour Puck.LiveView.Handler

      @impl true
      def on_chunk(_chunk, _state), do: raise("boom")

      @impl true
      def on_done(_response, _context, _state), do: raise("boom")
    end

    defp start_handler_stream(handler, opts \\ []) do
      stream_id = Keyword.get_lazy(opts, :stream_id, &random_id/0)

      client =
        Keyword.get(opts, :client, Client.new({Mock, stream_chunks: ["hello", " ", "world"]}))

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
             context: Context.new(),
             timeout: timeout,
             handler: handler
           ]}
        )

      %{stream_id: stream_id, pid: pid}
    end

    defp start_handler_fun_stream(fun, handler, opts \\ []) do
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
             timeout: timeout,
             handler: handler
           ]}
        )

      %{stream_id: stream_id, pid: pid}
    end

    defp poll_handler(agent, match_fn) do
      poll_until(fn -> Enum.any?(Agent.get(agent, & &1), match_fn) end)
      Agent.get(agent, & &1)
    end

    test "on_chunk receives each chunk and threads state" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {FullHandler, %{agent: agent, chunks: []}}

      %{stream_id: id} = start_handler_stream(handler)

      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000

      calls = poll_handler(agent, &match?({:on_done, _, _}, &1))

      chunk_calls = for {:on_chunk, _} <- calls, do: :ok
      assert length(chunk_calls) == 3
    end

    test "on_done receives response and context" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {FullHandler, %{agent: agent, chunks: []}}

      %{stream_id: id} = start_handler_stream(handler)

      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000

      calls = poll_handler(agent, &match?({:on_done, _, _}, &1))

      assert Enum.any?(calls, fn
               {:on_done, %Response{}, %Context{}} -> true
               _ -> false
             end)
    end

    test "on_error called on stream failure" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {FullHandler, %{agent: agent, chunks: []}}
      client = Client.new({Mock, error: :rate_limited})

      %{stream_id: id} = start_handler_stream(handler, client: client)

      assert_receive {:puck_stream, ^id, {:error, :rate_limited}}, 1000

      calls = poll_handler(agent, &match?({:on_error, _}, &1))

      assert Enum.any?(calls, fn
               {:on_error, :rate_limited} -> true
               _ -> false
             end)
    end

    test "on_error called on task crash" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {FullHandler, %{agent: agent, chunks: []}}

      %{stream_id: id} =
        start_handler_fun_stream(
          fn _parent -> raise "task boom" end,
          handler
        )

      assert_receive {:puck_stream, ^id, {:error, _}}, 1000

      calls = poll_handler(agent, &match?({:on_error, _}, &1))

      assert Enum.any?(calls, fn
               {:on_error, {%RuntimeError{message: "task boom"}, _}} -> true
               _ -> false
             end)
    end

    test "on_cancel called on cancellation" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {FullHandler, %{agent: agent, chunks: []}}

      %{stream_id: id} =
        start_handler_fun_stream(
          fn parent ->
            send(parent, {:stream_chunk, %{type: :content, content: "partial"}})
            Process.sleep(5000)
          end,
          handler
        )

      assert_receive {:puck_stream, ^id, {:content, _}}, 1000
      poll_until(fn -> Registry.lookup(Puck.LiveView.Registry, id) != [] end)
      StreamServer.cancel(Puck.LiveView.Registry, id)

      assert_receive {:puck_stream, ^id, {:cancelled, "partial"}}, 1000

      calls = poll_handler(agent, &match?({:on_cancel, _}, &1))

      assert Enum.any?(calls, fn
               {:on_cancel, "partial"} -> true
               _ -> false
             end)
    end

    test "on_cancel called on timeout" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {FullHandler, %{agent: agent, chunks: []}}

      %{stream_id: id} =
        start_handler_fun_stream(
          fn _parent -> Process.sleep(5000) end,
          handler,
          timeout: 50
        )

      assert_receive {:puck_stream, ^id, {:cancelled, _}}, 1000

      calls = poll_handler(agent, &match?({:on_cancel, _}, &1))

      assert Enum.any?(calls, &match?({:on_cancel, _}, &1))
    end

    test "optional callbacks — handler with only on_done works" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {DoneOnlyHandler, %{agent: agent}}

      %{stream_id: id} = start_handler_stream(handler)

      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000

      calls = poll_handler(agent, &match?({:on_done, _}, &1))

      assert Enum.any?(calls, fn
               {:on_done, %Response{}} -> true
               _ -> false
             end)
    end

    test "handler crash doesn't kill stream" do
      handler = {CrashingHandler, %{}}

      %{stream_id: id} = start_handler_stream(handler)

      assert_receive {:puck_stream, ^id, {:content, %{content: "hello"}}}, 1000
      assert_receive {:puck_stream, ^id, {:content, %{content: " "}}}, 1000
      assert_receive {:puck_stream, ^id, {:content, %{content: "world"}}}, 1000
      assert_receive {:puck_stream, ^id, {:done, response, _}}, 1000
      assert response.content == "hello world"
    end

    test "invalid handler format raises ArgumentError" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _}} =
               StreamServer.start_link(
                 stream_id: random_id(),
                 pubsub: @pubsub,
                 task_supervisor: Puck.LiveView.TaskSupervisor,
                 registry: Puck.LiveView.Registry,
                 client: Client.new({Mock, stream_chunks: ["hello"]}),
                 prompt: "test",
                 context: Context.new(),
                 handler: SomeModule
               )

      assert message =~ "expected :handler to be"
    end

    test "works with start_fun_stream path" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      handler = {FullHandler, %{agent: agent, chunks: []}}

      %{stream_id: id} =
        start_handler_fun_stream(
          fn parent ->
            for text <- ["a", "b"] do
              send(parent, {:stream_chunk, %{type: :content, content: text}})
            end

            {:stream_done, Context.new(), %{type: :content, content: "b"}}
          end,
          handler
        )

      assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000

      calls = poll_handler(agent, &match?({:on_done, _, _}, &1))

      chunk_calls = for {:on_chunk, _} <- calls, do: :ok
      assert length(chunk_calls) == 2

      assert Enum.any?(calls, fn
               {:on_done, %Response{}, %Context{}} -> true
               _ -> false
             end)
    end
  end
end
