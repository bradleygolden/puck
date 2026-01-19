defmodule Puck.TestTest do
  use ExUnit.Case, async: true

  alias Puck.Context
  alias Puck.Test, as: PuckTest

  defmodule Action do
    defstruct [:type, :data]
  end

  describe "mock_client/2" do
    test "returns responses sequentially" do
      client = PuckTest.mock_client(["first", "second", "third"])
      ctx = Context.new()

      {:ok, r1, ctx} = Puck.call(client, "a", ctx)
      {:ok, r2, ctx} = Puck.call(client, "b", ctx)
      {:ok, r3, _ctx} = Puck.call(client, "c", ctx)

      assert r1.content == "first"
      assert r2.content == "second"
      assert r3.content == "third"

      PuckTest.verify!()
    end

    test "returns error when queue exhausted" do
      client = PuckTest.mock_client(["only"])
      ctx = Context.new()

      {:ok, _, ctx} = Puck.call(client, "a", ctx)
      assert {:error, :mock_responses_exhausted} = Puck.call(client, "b", ctx)

      PuckTest.verify!()
    end

    test "supports custom default" do
      client = PuckTest.mock_client(["first"], default: "fallback")
      ctx = Context.new()

      {:ok, _, ctx} = Puck.call(client, "a", ctx)
      {:ok, r2, _ctx} = Puck.call(client, "b", ctx)

      assert r2.content == "fallback"
      PuckTest.verify!()
    end

    test "supports error tuples in queue" do
      client = PuckTest.mock_client(["ok", {:error, :rate_limited}, "recovered"])
      ctx = Context.new()

      {:ok, r1, ctx} = Puck.call(client, "a", ctx)
      assert {:error, :rate_limited} = Puck.call(client, "b", ctx)
      {:ok, r3, _ctx} = Puck.call(client, "c", ctx)

      assert r1.content == "ok"
      assert r3.content == "recovered"

      PuckTest.verify!()
    end

    test "supports function responses" do
      client =
        PuckTest.mock_client([
          "first",
          fn messages ->
            count = Enum.count(messages, &(&1.role == :user))
            "seen #{count} user messages"
          end
        ])

      ctx = Context.new()

      {:ok, _, ctx} = Puck.call(client, "hello", ctx)
      {:ok, r2, _ctx} = Puck.call(client, "world", ctx)

      assert r2.content == "seen 2 user messages"
      PuckTest.verify!()
    end

    test "supports struct responses" do
      client = PuckTest.mock_client([%Action{type: "search"}, %Action{type: "done"}])
      ctx = Context.new()

      {:ok, r1, ctx} = Puck.call(client, "a", ctx)
      {:ok, r2, _ctx} = Puck.call(client, "b", ctx)

      assert r1.content == %Action{type: "search"}
      assert r2.content == %Action{type: "done"}

      PuckTest.verify!()
    end

    test "supports map responses" do
      client = PuckTest.mock_client([%{action: "search"}, %{action: "done"}])
      ctx = Context.new()

      {:ok, r1, ctx} = Puck.call(client, "a", ctx)
      {:ok, r2, _ctx} = Puck.call(client, "b", ctx)

      assert r1.content == %{action: "search"}
      assert r2.content == %{action: "done"}

      PuckTest.verify!()
    end

    test "function can return error" do
      client = PuckTest.mock_client([fn _ -> {:error, :custom} end])

      assert {:error, :custom} = Puck.call(client, "a", Context.new())
      PuckTest.verify!()
    end

    test "sets model via option" do
      client = PuckTest.mock_client([], model: "test-model")
      {_, config} = client.backend

      assert config.model == "test-model"
      PuckTest.verify!()
    end

    test "works with streaming" do
      client = PuckTest.mock_client(["chunk"])
      ctx = Context.new()

      {:ok, stream, _ctx} = Puck.stream(client, "a", ctx)
      chunks = Enum.to_list(stream)

      assert length(chunks) == 1
      assert hd(chunks).content == "chunk"

      PuckTest.verify!()
    end
  end

  describe "verify!/0" do
    test "raises on unconsumed responses" do
      _client = PuckTest.mock_client(["unused1", "unused2"])

      assert_raise ExUnit.AssertionError, ~r/2 of 2 responses unused/, fn ->
        PuckTest.verify!()
      end
    end

    test "passes when fully consumed" do
      client = PuckTest.mock_client(["one"])
      {:ok, _, _} = Puck.call(client, "a", Context.new())

      assert :ok = PuckTest.verify!()
    end

    test "tracks multiple clients" do
      c1 = PuckTest.mock_client(["a", "b"])
      c2 = PuckTest.mock_client(["x"])
      ctx = Context.new()

      {:ok, _, ctx1} = Puck.call(c1, "1", ctx)
      {:ok, _, _} = Puck.call(c1, "2", ctx1)
      {:ok, _, _} = Puck.call(c2, "3", ctx)

      assert :ok = PuckTest.verify!()
    end

    test "catches partial consumption" do
      c1 = PuckTest.mock_client(["a"])
      _c2 = PuckTest.mock_client(["unused"])

      {:ok, _, _} = Puck.call(c1, "1", Context.new())

      assert_raise ExUnit.AssertionError, ~r/1 of 1 responses unused/, fn ->
        PuckTest.verify!()
      end
    end
  end

  describe "verify_on_exit!/1" do
    setup do
      PuckTest.verify_on_exit!()
    end

    test "verifies automatically" do
      client = PuckTest.mock_client(["response"])
      {:ok, r, _} = Puck.call(client, "a", Context.new())

      assert r.content == "response"
    end
  end

  describe "cross-process" do
    test "works with Task" do
      client = PuckTest.mock_client(["from_task"])
      ctx = Context.new()

      task = Task.async(fn -> Puck.call(client, "a", ctx) end)
      {:ok, r, _} = Task.await(task)

      assert r.content == "from_task"
      PuckTest.verify!()
    end

    test "works with Agent" do
      client = PuckTest.mock_client(["from_agent"])
      ctx = Context.new()

      {:ok, agent} =
        Agent.start_link(fn ->
          {:ok, r, _} = Puck.call(client, "a", ctx)
          r.content
        end)

      assert Agent.get(agent, & &1) == "from_agent"
      Agent.stop(agent)

      PuckTest.verify!()
    end

    test "works with spawn" do
      client = PuckTest.mock_client(["from_spawn"])
      ctx = Context.new()
      parent = self()

      spawn(fn ->
        {:ok, r, _} = Puck.call(client, "a", ctx)
        send(parent, {:result, r.content})
      end)

      assert_receive {:result, "from_spawn"}, 1000
      PuckTest.verify!()
    end

    test "concurrent access" do
      client = PuckTest.mock_client(["a", "b", "c"])
      ctx = Context.new()
      parent = self()

      for _ <- 1..3 do
        spawn(fn ->
          {:ok, r, _} = Puck.call(client, "x", ctx)
          send(parent, {:result, r.content})
        end)
      end

      results = for _ <- 1..3, do: receive(do: ({:result, c} -> c))

      assert Enum.sort(results) == ["a", "b", "c"]
      PuckTest.verify!()
    end
  end
end
