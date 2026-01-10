defmodule Puck.Eval.GradersTest do
  use ExUnit.Case, async: true

  alias Puck.Eval.{Graders, Step, Trajectory}

  defp make_trajectory(steps \\ 2, tokens \\ 100, duration_ms \\ 500) do
    steps_list =
      for i <- 1..steps do
        Step.new(
          input: "input #{i}",
          output: "output #{i}",
          tokens: %{total: div(tokens, steps)},
          duration_ms: div(duration_ms, steps)
        )
      end

    Trajectory.new(steps_list)
  end

  describe "contains/1" do
    test "passes when output contains substring" do
      grader = Graders.contains("hello")
      trajectory = make_trajectory()

      assert grader.("hello world", trajectory) == :pass
    end

    test "fails when output does not contain substring" do
      grader = Graders.contains("hello")
      trajectory = make_trajectory()

      assert {:fail, reason} = grader.("goodbye world", trajectory)
      assert reason =~ "does not contain"
      assert reason =~ "hello"
    end

    test "works with non-string outputs" do
      grader = Graders.contains("hello")
      trajectory = make_trajectory()

      assert grader.(%{message: "hello world"}, trajectory) == :pass
    end
  end

  describe "matches/1" do
    test "passes when output matches regex" do
      grader = Graders.matches(~r/\d{3}-\d{4}/)
      trajectory = make_trajectory()

      assert grader.("Call 555-1234", trajectory) == :pass
    end

    test "fails when output does not match regex" do
      grader = Graders.matches(~r/\d{3}-\d{4}/)
      trajectory = make_trajectory()

      assert {:fail, reason} = grader.("no phone number here", trajectory)
      assert reason =~ "does not match"
    end
  end

  describe "equals/1" do
    test "passes when output equals expected" do
      grader = Graders.equals("success")
      trajectory = make_trajectory()

      assert grader.("success", trajectory) == :pass
    end

    test "fails when output does not equal expected" do
      grader = Graders.equals("success")
      trajectory = make_trajectory()

      assert {:fail, reason} = grader.("failure", trajectory)
      assert reason =~ "does not equal"
    end

    test "works with complex values" do
      expected = %{status: :ok, data: [1, 2, 3]}
      grader = Graders.equals(expected)
      trajectory = make_trajectory()

      assert grader.(%{status: :ok, data: [1, 2, 3]}, trajectory) == :pass
      assert {:fail, _} = grader.(%{status: :ok, data: [1, 2]}, trajectory)
    end
  end

  describe "satisfies/1" do
    test "passes when predicate returns true" do
      grader = Graders.satisfies(fn output -> String.length(output) > 5 end)
      trajectory = make_trajectory()

      assert grader.("hello world", trajectory) == :pass
    end

    test "fails when predicate returns false" do
      grader = Graders.satisfies(fn output -> String.length(output) > 5 end)
      trajectory = make_trajectory()

      assert {:fail, reason} = grader.("hi", trajectory)
      assert reason =~ "does not satisfy"
    end
  end

  describe "max_steps/1" do
    test "passes when steps are within limit" do
      grader = Graders.max_steps(5)
      trajectory = make_trajectory(3)

      assert grader.("output", trajectory) == :pass
    end

    test "passes when steps equal limit" do
      grader = Graders.max_steps(3)
      trajectory = make_trajectory(3)

      assert grader.("output", trajectory) == :pass
    end

    test "fails when steps exceed limit" do
      grader = Graders.max_steps(2)
      trajectory = make_trajectory(5)

      assert {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "5 steps exceeds max of 2"
    end
  end

  describe "max_tokens/1" do
    test "passes when tokens are within limit" do
      grader = Graders.max_tokens(200)
      trajectory = make_trajectory(2, 100)

      assert grader.("output", trajectory) == :pass
    end

    test "fails when tokens exceed limit" do
      grader = Graders.max_tokens(50)
      trajectory = make_trajectory(2, 100)

      assert {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "100 tokens exceeds max of 50"
    end
  end

  describe "max_duration_ms/1" do
    test "passes when duration is within limit" do
      grader = Graders.max_duration_ms(1000)
      trajectory = make_trajectory(2, 100, 500)

      assert grader.("output", trajectory) == :pass
    end

    test "fails when duration exceeds limit" do
      grader = Graders.max_duration_ms(100)
      trajectory = make_trajectory(2, 100, 500)

      assert {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "500ms exceeds max of 100ms"
    end
  end

  describe "output_produced/1,2" do
    defmodule LookupContact do
      defstruct [:name]
    end

    defmodule FireAlert do
      defstruct [:message]
    end

    defmodule Done do
      defstruct [:result]
    end

    defmodule DeleteContact do
      defstruct [:id]
    end

    defp make_struct_trajectory(outputs) do
      steps =
        Enum.map(outputs, fn output ->
          Step.new(input: "input", output: output, tokens: %{total: 10})
        end)

      Trajectory.new(steps)
    end

    test "passes when struct type was produced" do
      trajectory =
        make_struct_trajectory([
          %LookupContact{name: "John"},
          %Done{result: "found"}
        ])

      grader = Graders.output_produced(LookupContact)

      assert grader.("output", trajectory) == :pass
    end

    test "fails when struct type was not produced" do
      trajectory =
        make_struct_trajectory([
          %Done{result: "done"}
        ])

      grader = Graders.output_produced(LookupContact)

      assert {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "LookupContact"
      assert reason =~ "was not produced"
    end

    test "checks exact count when times option provided" do
      trajectory =
        make_struct_trajectory([
          %LookupContact{name: "John"},
          %LookupContact{name: "Jane"},
          %Done{result: "done"}
        ])

      grader_exact = Graders.output_produced(LookupContact, times: 2)
      grader_wrong = Graders.output_produced(LookupContact, times: 1)

      assert grader_exact.("output", trajectory) == :pass
      assert {:fail, reason} = grader_wrong.("output", trajectory)
      assert reason =~ "produced 2 times, expected 1"
    end
  end

  describe "output_matches/1,2" do
    alias Puck.Eval.GradersTest.{Done, FireAlert, LookupContact}

    defp make_match_trajectory(outputs) do
      steps =
        Enum.map(outputs, fn output ->
          Step.new(input: "input", output: output, tokens: %{total: 10})
        end)

      Trajectory.new(steps)
    end

    test "passes when predicate matches a step output" do
      trajectory =
        make_match_trajectory([
          %LookupContact{name: "John"},
          %Done{result: "found"}
        ])

      grader =
        Graders.output_matches(fn
          %LookupContact{name: "John"} -> true
          _ -> false
        end)

      assert grader.("output", trajectory) == :pass
    end

    test "fails when predicate does not match any step output" do
      trajectory =
        make_match_trajectory([
          %LookupContact{name: "Jane"},
          %Done{result: "done"}
        ])

      grader =
        Graders.output_matches(fn
          %LookupContact{name: "John"} -> true
          _ -> false
        end)

      assert {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "No step output matched"
    end

    test "checks exact count when times option provided" do
      trajectory =
        make_match_trajectory([
          %LookupContact{name: "John"},
          %LookupContact{name: "John"},
          %Done{result: "done"}
        ])

      grader_exact =
        Graders.output_matches(
          fn
            %LookupContact{name: "John"} -> true
            _ -> false
          end,
          times: 2
        )

      grader_wrong =
        Graders.output_matches(
          fn
            %LookupContact{name: "John"} -> true
            _ -> false
          end,
          times: 1
        )

      assert grader_exact.("output", trajectory) == :pass
      assert {:fail, reason} = grader_wrong.("output", trajectory)
      assert reason =~ "matched 2 times, expected 1"
    end

    test "works with match?/2 style predicates" do
      trajectory =
        make_match_trajectory([
          %LookupContact{name: "John"},
          %FireAlert{message: "test alert"}
        ])

      grader = Graders.output_matches(&match?(%FireAlert{message: "test" <> _}, &1))

      assert grader.("output", trajectory) == :pass
    end
  end

  describe "output_not_produced/1" do
    test "passes when struct type was not produced" do
      steps = [
        Step.new(
          input: "a",
          output: %Puck.Eval.GradersTest.LookupContact{name: "John"},
          tokens: %{total: 10}
        ),
        Step.new(
          input: "b",
          output: %Puck.Eval.GradersTest.Done{result: "done"},
          tokens: %{total: 10}
        )
      ]

      trajectory = Trajectory.new(steps)

      grader = Graders.output_not_produced(Puck.Eval.GradersTest.DeleteContact)
      assert grader.("output", trajectory) == :pass
    end

    test "fails when struct type was produced" do
      steps = [
        Step.new(
          input: "a",
          output: %Puck.Eval.GradersTest.DeleteContact{id: 123},
          tokens: %{total: 10}
        )
      ]

      trajectory = Trajectory.new(steps)

      grader = Graders.output_not_produced(Puck.Eval.GradersTest.DeleteContact)
      assert {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "DeleteContact"
      assert reason =~ "should not have been"
    end
  end

  describe "output_sequence/1" do
    defmodule TakeSnapshot do
      defstruct [:description]
    end

    defmodule Analyze do
      defstruct [:data]
    end

    defmodule Wait do
      defstruct [:duration]
    end

    test "passes when struct types appear in order" do
      steps = [
        Step.new(input: "a", output: %TakeSnapshot{description: "test"}, tokens: %{total: 10}),
        Step.new(input: "b", output: %Analyze{data: "test"}, tokens: %{total: 10}),
        Step.new(
          input: "c",
          output: %Puck.Eval.GradersTest.FireAlert{message: "alert"},
          tokens: %{total: 10}
        )
      ]

      trajectory = Trajectory.new(steps)

      grader = Graders.output_sequence([TakeSnapshot, Analyze, Puck.Eval.GradersTest.FireAlert])

      assert grader.("output", trajectory) == :pass
    end

    test "passes when sequence appears with other struct types in between" do
      steps = [
        Step.new(input: "a", output: %TakeSnapshot{description: "test"}, tokens: %{total: 10}),
        Step.new(input: "b", output: %Wait{duration: 100}, tokens: %{total: 10}),
        Step.new(
          input: "c",
          output: %Puck.Eval.GradersTest.FireAlert{message: "alert"},
          tokens: %{total: 10}
        )
      ]

      trajectory = Trajectory.new(steps)

      grader = Graders.output_sequence([TakeSnapshot, Puck.Eval.GradersTest.FireAlert])
      assert grader.("output", trajectory) == :pass
    end

    test "fails when sequence is not present" do
      steps = [
        Step.new(
          input: "a",
          output: %Puck.Eval.GradersTest.FireAlert{message: "alert"},
          tokens: %{total: 10}
        ),
        Step.new(input: "b", output: %TakeSnapshot{description: "test"}, tokens: %{total: 10})
      ]

      trajectory = Trajectory.new(steps)

      grader = Graders.output_sequence([TakeSnapshot, Puck.Eval.GradersTest.FireAlert])
      assert {:fail, reason} = grader.("output", trajectory)
      assert reason =~ "not found"
    end

    test "fails when sequence is incomplete" do
      steps = [
        Step.new(input: "a", output: %TakeSnapshot{description: "test"}, tokens: %{total: 10})
      ]

      trajectory = Trajectory.new(steps)

      grader = Graders.output_sequence([TakeSnapshot, Analyze, Puck.Eval.GradersTest.FireAlert])

      assert {:fail, _} = grader.("output", trajectory)
    end
  end
end
