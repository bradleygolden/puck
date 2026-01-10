defmodule Puck.Eval.ResultTest do
  use ExUnit.Case, async: true

  alias Puck.Eval.{Graders, Result, Step, Trajectory}

  defp make_trajectory do
    steps = [
      Step.new(input: "a", output: "b", tokens: %{total: 100}, duration_ms: 200),
      Step.new(input: "c", output: "d", tokens: %{total: 150}, duration_ms: 300)
    ]

    Trajectory.new(steps)
  end

  describe "from_graders/3" do
    test "creates result with all passing graders" do
      trajectory = make_trajectory()
      output = "hello world"

      graders = [
        Graders.contains("hello"),
        Graders.max_steps(5)
      ]

      result = Result.from_graders(output, trajectory, graders)

      assert result.passed? == true
      assert result.output == output
      assert result.trajectory == trajectory
      assert length(result.grader_results) == 2
      assert Enum.all?(result.grader_results, & &1.passed?)
    end

    test "creates result with failing graders" do
      trajectory = make_trajectory()
      output = "hello world"

      graders = [
        Graders.contains("hello"),
        Graders.contains("goodbye")
      ]

      result = Result.from_graders(output, trajectory, graders)

      assert result.passed? == false
      assert length(result.grader_results) == 2

      [first, second] = result.grader_results
      assert first.passed? == true
      assert second.passed? == false
      assert second.reason =~ "does not contain"
    end

    test "includes grader references in results" do
      trajectory = make_trajectory()
      grader1 = Graders.contains("hello")
      grader2 = Graders.max_steps(10)

      result = Result.from_graders("hello", trajectory, [grader1, grader2])

      [r1, r2] = result.grader_results
      assert r1.grader == grader1
      assert r2.grader == grader2
    end

    test "handles empty graders list" do
      trajectory = make_trajectory()

      result = Result.from_graders("output", trajectory, [])

      assert result.passed? == true
      assert result.grader_results == []
    end
  end

  describe "failures/1" do
    test "returns only failed graders" do
      trajectory = make_trajectory()

      graders = [
        Graders.contains("hello"),
        Graders.contains("goodbye"),
        Graders.max_steps(1)
      ]

      result = Result.from_graders("hello world", trajectory, graders)

      failures = Result.failures(result)
      assert length(failures) == 2
      assert Enum.all?(failures, fn f -> not f.passed? end)
    end

    test "returns empty list when all pass" do
      trajectory = make_trajectory()
      graders = [Graders.contains("hello")]

      result = Result.from_graders("hello", trajectory, graders)

      assert Result.failures(result) == []
    end
  end

  describe "passes/1" do
    test "returns only passed graders" do
      trajectory = make_trajectory()

      graders = [
        Graders.contains("hello"),
        Graders.contains("goodbye")
      ]

      result = Result.from_graders("hello world", trajectory, graders)

      passes = Result.passes(result)
      assert length(passes) == 1
      assert Enum.all?(passes, & &1.passed?)
    end
  end

  describe "summary/1" do
    test "returns summary map" do
      trajectory = make_trajectory()

      graders = [
        Graders.contains("hello"),
        Graders.contains("goodbye"),
        Graders.max_steps(10)
      ]

      result = Result.from_graders("hello world", trajectory, graders)
      summary = Result.summary(result)

      assert summary.passed? == false
      assert summary.total_graders == 3
      assert summary.passed_count == 2
      assert summary.failed_count == 1
      assert summary.total_steps == 2
      assert summary.total_tokens == 250
      assert summary.total_duration_ms == 500
    end
  end
end
