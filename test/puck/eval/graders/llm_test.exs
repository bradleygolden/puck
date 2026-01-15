defmodule Puck.Eval.Graders.LLMTest do
  use ExUnit.Case, async: true

  alias Puck.Eval.Graders.LLM
  alias Puck.Eval.Result
  alias Puck.Eval.Trajectory

  setup do
    trajectory = Trajectory.empty()
    {:ok, trajectory: trajectory}
  end

  describe "rubric/2" do
    test "returns :pass when judge responds with passed: true", %{trajectory: trajectory} do
      client = Puck.Client.new({Puck.Backends.Mock, response: %{passed: true, reason: nil}})
      grader = LLM.rubric(client, "- Be polite")

      assert grader.("Thank you", trajectory) == :pass
    end

    test "returns {:fail, reason} when judge responds with passed: false", %{
      trajectory: trajectory
    } do
      client =
        Puck.Client.new(
          {Puck.Backends.Mock, response: %{passed: false, reason: "Not polite enough"}}
        )

      grader = LLM.rubric(client, "- Be polite")

      assert {:fail, "Not polite enough"} = grader.("Go away", trajectory)
    end

    test "handles LLM call errors", %{trajectory: trajectory} do
      client = Puck.Client.new({Puck.Backends.Mock, error: "Network timeout"})
      grader = LLM.rubric(client, "- Test")

      {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "LLM judge error"
    end

    test "converts non-string output to string", %{trajectory: trajectory} do
      client = Puck.Client.new({Puck.Backends.Mock, response: %{passed: true, reason: nil}})
      grader = LLM.rubric(client, "- Valid struct")

      assert grader.(%{data: "test"}, trajectory) == :pass
    end

    test "works with Result.from_graders", %{trajectory: trajectory} do
      client = Puck.Client.new({Puck.Backends.Mock, response: %{passed: true, reason: nil}})

      result =
        Result.from_graders(
          "Polite response",
          trajectory,
          [LLM.rubric(client, "- Be polite")]
        )

      assert result.passed?
    end
  end
end
