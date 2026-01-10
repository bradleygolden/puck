defmodule Puck.Eval.GraderTest do
  use ExUnit.Case, async: true

  alias Puck.Eval.{Grader, Step, Trajectory}

  defmodule PassingGrader do
    @behaviour Puck.Eval.Grader

    @impl true
    def grade(_output, _trajectory), do: :pass
  end

  defmodule FailingGrader do
    @behaviour Puck.Eval.Grader

    @impl true
    def grade(_output, _trajectory), do: {:fail, "Always fails"}
  end

  defmodule ContainsGrader do
    @behaviour Puck.Eval.Grader

    @impl true
    def grade(output, _trajectory) do
      if is_binary(output) and String.contains?(output, "hello") do
        :pass
      else
        {:fail, "Output does not contain hello"}
      end
    end
  end

  defp make_trajectory do
    steps = [
      Step.new(input: "input", output: "output", tokens: %{total: 10})
    ]

    Trajectory.new(steps)
  end

  describe "run/3 with function graders" do
    test "runs a passing function grader" do
      grader = fn _output, _trajectory -> :pass end
      trajectory = make_trajectory()

      assert Grader.run(grader, "output", trajectory) == :pass
    end

    test "runs a failing function grader" do
      grader = fn _output, _trajectory -> {:fail, "reason"} end
      trajectory = make_trajectory()

      assert Grader.run(grader, "output", trajectory) == {:fail, "reason"}
    end

    test "function grader receives output and trajectory" do
      grader = fn output, trajectory ->
        if output == "test" and trajectory.total_steps == 1 do
          :pass
        else
          {:fail, "wrong args"}
        end
      end

      trajectory = make_trajectory()

      assert Grader.run(grader, "test", trajectory) == :pass
    end
  end

  describe "run/3 with module graders" do
    test "runs a passing module grader" do
      trajectory = make_trajectory()
      assert Grader.run(PassingGrader, "output", trajectory) == :pass
    end

    test "runs a failing module grader" do
      trajectory = make_trajectory()
      assert Grader.run(FailingGrader, "output", trajectory) == {:fail, "Always fails"}
    end

    test "runs a module grader that checks output" do
      trajectory = make_trajectory()

      assert Grader.run(ContainsGrader, "hello world", trajectory) == :pass

      assert Grader.run(ContainsGrader, "goodbye", trajectory) ==
               {:fail, "Output does not contain hello"}
    end
  end

  describe "run_all/3" do
    test "runs multiple graders and returns all results" do
      grader1 = fn _output, _trajectory -> :pass end
      grader2 = fn _output, _trajectory -> {:fail, "failed"} end
      grader3 = PassingGrader

      trajectory = make_trajectory()

      results = Grader.run_all([grader1, grader2, grader3], "output", trajectory)

      assert length(results) == 3
      assert {^grader1, :pass} = Enum.at(results, 0)
      assert {^grader2, {:fail, "failed"}} = Enum.at(results, 1)
      assert {PassingGrader, :pass} = Enum.at(results, 2)
    end

    test "returns empty list for empty graders list" do
      trajectory = make_trajectory()
      assert Grader.run_all([], "output", trajectory) == []
    end

    test "mixes function and module graders" do
      fn_grader = fn output, _traj -> if output == "test", do: :pass, else: {:fail, "wrong"} end
      trajectory = make_trajectory()

      results = Grader.run_all([fn_grader, ContainsGrader], "test", trajectory)

      assert [{^fn_grader, :pass}, {ContainsGrader, {:fail, _}}] = results
    end
  end

  describe "passed?/1" do
    test "returns true for :pass" do
      assert Grader.passed?(:pass) == true
    end

    test "returns false for {:fail, reason}" do
      assert Grader.passed?({:fail, "any reason"}) == false
    end
  end
end
