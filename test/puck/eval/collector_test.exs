defmodule Puck.Eval.CollectorTest do
  use ExUnit.Case, async: false

  alias Puck.Eval.{Collector, Trajectory}

  describe "collect/1" do
    test "captures trajectory from Puck.call" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "Hello!"})

      {result, trajectory} =
        Collector.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "Hi there")
          response.content
        end)

      assert result == "Hello!"
      assert %Trajectory{} = trajectory
      assert trajectory.total_steps == 1
      assert [step] = trajectory.steps
      assert step.output == "Hello!"
    end

    test "captures multiple calls in a loop" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "response"})

      {_result, trajectory} =
        Collector.collect(fn ->
          {:ok, _, ctx} = Puck.call(client, "first", Puck.Context.new())
          {:ok, _, ctx} = Puck.call(client, "second", ctx)
          {:ok, response, _ctx} = Puck.call(client, "third", ctx)
          response.content
        end)

      assert trajectory.total_steps == 3
      assert length(trajectory.steps) == 3
    end

    test "captures tokens and duration" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "test", delay: 50})

      {_result, trajectory} =
        Collector.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "test")
          response.content
        end)

      assert trajectory.total_steps == 1
      [step] = trajectory.steps
      # Mock backend estimates tokens
      assert step.tokens.total >= 0
      # Duration should be at least the delay
      assert step.duration_ms >= 50
    end

    test "returns empty trajectory when no calls made" do
      {result, trajectory} =
        Collector.collect(fn ->
          "no LLM calls here"
        end)

      assert result == "no LLM calls here"
      assert trajectory.total_steps == 0
      assert trajectory.steps == []
    end

    test "isolates trajectories between concurrent collections" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "test"})

      task1 =
        Task.async(fn ->
          Collector.collect(fn ->
            {:ok, _, _} = Puck.call(client, "task1-call1", Puck.Context.new())
            {:ok, response, _} = Puck.call(client, "task1-call2", Puck.Context.new())
            response.content
          end)
        end)

      task2 =
        Task.async(fn ->
          Collector.collect(fn ->
            {:ok, response, _} = Puck.call(client, "task2-call1", Puck.Context.new())
            response.content
          end)
        end)

      {_result1, trajectory1} = Task.await(task1)
      {_result2, trajectory2} = Task.await(task2)

      # Each task should only see its own calls
      assert trajectory1.total_steps == 2
      assert trajectory2.total_steps == 1
    end
  end
end
