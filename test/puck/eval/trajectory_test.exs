defmodule Puck.Eval.TrajectoryTest do
  use ExUnit.Case, async: true

  alias Puck.Eval.{Step, Trajectory}

  describe "Step.new/1" do
    test "creates a step with required fields" do
      step = Step.new(input: "hello", output: "world")

      assert step.input == "hello"
      assert step.output == "world"
      assert step.tokens == %{input: 0, output: 0, total: 0}
      assert step.duration_ms == 0
      assert step.metadata == %{}
    end

    test "creates a step with all fields" do
      step =
        Step.new(
          input: "hello",
          output: %{action: "done"},
          tokens: %{input: 100, output: 50, total: 150},
          duration_ms: 500,
          metadata: %{model: "claude"}
        )

      assert step.input == "hello"
      assert step.output == %{action: "done"}
      assert step.tokens == %{input: 100, output: 50, total: 150}
      assert step.duration_ms == 500
      assert step.metadata == %{model: "claude"}
    end

    test "normalizes token fields" do
      step =
        Step.new(
          input: "hi",
          output: "bye",
          tokens: %{input_tokens: 10, output_tokens: 5}
        )

      assert step.tokens == %{input: 10, output: 5, total: 15}
    end

    test "raises when required fields are missing" do
      assert_raise KeyError, fn ->
        Step.new(input: "hello")
      end

      assert_raise KeyError, fn ->
        Step.new(output: "world")
      end
    end
  end

  describe "Trajectory.new/1" do
    test "creates a trajectory from steps" do
      steps = [
        Step.new(input: "a", output: "b", tokens: %{total: 10}, duration_ms: 100),
        Step.new(input: "c", output: "d", tokens: %{total: 20}, duration_ms: 200)
      ]

      trajectory = Trajectory.new(steps)

      assert trajectory.total_steps == 2
      assert trajectory.total_tokens == 30
      assert trajectory.total_duration_ms == 300
      assert length(trajectory.steps) == 2
    end

    test "creates an empty trajectory" do
      trajectory = Trajectory.new([])

      assert trajectory.total_steps == 0
      assert trajectory.total_tokens == 0
      assert trajectory.total_duration_ms == 0
      assert trajectory.steps == []
    end
  end

  describe "Trajectory.empty/0" do
    test "returns an empty trajectory" do
      trajectory = Trajectory.empty()

      assert trajectory.total_steps == 0
      assert trajectory.total_tokens == 0
      assert trajectory.total_duration_ms == 0
      assert trajectory.steps == []
    end
  end

  describe "Trajectory.add_step/2" do
    test "adds a step to the trajectory" do
      trajectory = Trajectory.empty()
      step = Step.new(input: "a", output: "b", tokens: %{total: 10}, duration_ms: 100)

      updated = Trajectory.add_step(trajectory, step)

      assert updated.total_steps == 1
      assert updated.total_tokens == 10
      assert updated.total_duration_ms == 100
    end

    test "appends steps in order" do
      step1 = Step.new(input: "a", output: "b", tokens: %{total: 10}, duration_ms: 100)
      step2 = Step.new(input: "c", output: "d", tokens: %{total: 20}, duration_ms: 200)

      trajectory =
        Trajectory.empty()
        |> Trajectory.add_step(step1)
        |> Trajectory.add_step(step2)

      assert trajectory.total_steps == 2
      assert [first, second] = trajectory.steps
      assert first.input == "a"
      assert second.input == "c"
    end
  end

  describe "Trajectory.first_step/1" do
    test "returns the first step" do
      steps = [
        Step.new(input: "first", output: "a", tokens: %{total: 0}),
        Step.new(input: "second", output: "b", tokens: %{total: 0})
      ]

      trajectory = Trajectory.new(steps)
      assert Trajectory.first_step(trajectory).input == "first"
    end

    test "returns nil for empty trajectory" do
      trajectory = Trajectory.empty()
      assert Trajectory.first_step(trajectory) == nil
    end
  end

  describe "Trajectory.last_step/1" do
    test "returns the last step" do
      steps = [
        Step.new(input: "first", output: "a", tokens: %{total: 0}),
        Step.new(input: "last", output: "b", tokens: %{total: 0})
      ]

      trajectory = Trajectory.new(steps)
      assert Trajectory.last_step(trajectory).input == "last"
    end

    test "returns nil for empty trajectory" do
      trajectory = Trajectory.empty()
      assert Trajectory.last_step(trajectory) == nil
    end
  end

  describe "Trajectory.outputs/1" do
    test "returns all outputs" do
      steps = [
        Step.new(input: "a", output: "out1", tokens: %{total: 0}),
        Step.new(input: "b", output: "out2", tokens: %{total: 0}),
        Step.new(input: "c", output: "out3", tokens: %{total: 0})
      ]

      trajectory = Trajectory.new(steps)
      assert Trajectory.outputs(trajectory) == ["out1", "out2", "out3"]
    end

    test "returns empty list for empty trajectory" do
      trajectory = Trajectory.empty()
      assert Trajectory.outputs(trajectory) == []
    end
  end
end
