defmodule Puck.EvalTest do
  use ExUnit.Case, async: false

  alias Puck.Eval
  alias Puck.Eval.{Graders, Step, Trajectory}

  describe "collect/1" do
    test "delegates to Collector" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "test response"})

      {result, trajectory} =
        Eval.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "test")
          response.content
        end)

      assert result == "test response"
      assert %Trajectory{} = trajectory
    end
  end

  describe "grade/3" do
    test "applies graders and returns result" do
      trajectory =
        Trajectory.new([
          Step.new(input: "a", output: "b", tokens: %{total: 100}, duration_ms: 200)
        ])

      result =
        Eval.grade("hello world", trajectory, [
          Graders.contains("hello"),
          Graders.max_steps(5)
        ])

      assert result.passed? == true
      assert length(result.grader_results) == 2
    end
  end

  describe "run_grader/3" do
    test "runs a single grader" do
      trajectory = Trajectory.empty()
      grader = Graders.contains("hello")

      assert Eval.run_grader(grader, "hello world", trajectory) == :pass
      assert {:fail, _} = Eval.run_grader(grader, "goodbye", trajectory)
    end
  end

  describe "empty_trajectory/0" do
    test "returns empty trajectory" do
      trajectory = Eval.empty_trajectory()

      assert trajectory.total_steps == 0
      assert trajectory.steps == []
    end
  end

  describe "trajectory/1" do
    test "creates trajectory from steps" do
      steps = [
        Step.new(input: "a", output: "b", tokens: %{total: 10}, duration_ms: 100)
      ]

      trajectory = Eval.trajectory(steps)

      assert trajectory.total_steps == 1
      assert trajectory.total_tokens == 10
    end
  end

  describe "integration: full evaluation flow" do
    test "evaluates agent with mock backend" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "john@example.com"})

      {output, trajectory} =
        Eval.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "Find John's email")
          response.content
        end)

      result =
        Eval.grade(output, trajectory, [
          Graders.contains("john@example.com"),
          Graders.max_steps(3),
          Graders.max_tokens(10_000)
        ])

      assert result.passed? == true
      assert result.output == "john@example.com"
      assert result.trajectory.total_steps == 1
    end

    test "evaluates agent loop with multiple calls" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "done"})

      {output, trajectory} =
        Eval.collect(fn ->
          ctx = Puck.Context.new()
          {:ok, _, ctx} = Puck.call(client, "Step 1", ctx)
          {:ok, _, ctx} = Puck.call(client, "Step 2", ctx)
          {:ok, response, _ctx} = Puck.call(client, "Step 3", ctx)
          response.content
        end)

      result =
        Eval.grade(output, trajectory, [
          Graders.equals("done"),
          Graders.max_steps(5)
        ])

      assert result.passed? == true
      assert trajectory.total_steps == 3
    end

    test "detects failing conditions" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "error"})

      {output, trajectory} =
        Eval.collect(fn ->
          ctx = Puck.Context.new()

          Enum.reduce(1..10, ctx, fn _i, acc_ctx ->
            {:ok, _, new_ctx} = Puck.call(client, "call", acc_ctx)
            new_ctx
          end)

          "final"
        end)

      result =
        Eval.grade(output, trajectory, [
          Graders.max_steps(5)
        ])

      assert result.passed? == false

      [failure] = Eval.Result.failures(result)
      assert failure.reason =~ "10 steps exceeds max of 5"
    end
  end
end
