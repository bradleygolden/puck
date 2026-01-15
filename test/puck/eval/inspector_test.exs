defmodule Puck.Eval.InspectorTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Puck.Eval.{Graders, Inspector, Result, Step, Trajectory}

  defmodule TestStruct do
    defstruct [:name]
  end

  describe "print_trajectory/2" do
    test "prints trajectory header with summary" do
      trajectory =
        build_trajectory([
          %{
            input: "hi",
            output: "hello",
            tokens: %{input: 10, output: 5, total: 15},
            duration_ms: 100
          }
        ])

      output =
        capture_io(fn ->
          Inspector.print_trajectory(trajectory)
        end)

      assert output =~ "Trajectory (1 steps, 15 tokens, 100ms)"
    end

    test "prints each step with details" do
      trajectory =
        build_trajectory([
          %{
            input: "find John",
            output: "john@example.com",
            tokens: %{input: 20, output: 10, total: 30},
            duration_ms: 200
          }
        ])

      output =
        capture_io(fn ->
          Inspector.print_trajectory(trajectory)
        end)

      assert output =~ "Step 1:"
      assert output =~ "Input: \"find John\""
      assert output =~ "Output: \"john@example.com\""
      assert output =~ "Tokens: 20 in, 10 out (30 total)"
      assert output =~ "Duration: 200ms"
    end

    test "truncates long outputs" do
      long_output = String.duplicate("a", 300)

      trajectory =
        build_trajectory([
          %{
            input: "test",
            output: long_output,
            tokens: %{input: 10, output: 5, total: 15},
            duration_ms: 100
          }
        ])

      output =
        capture_io(fn ->
          Inspector.print_trajectory(trajectory, max_length: 50)
        end)

      assert output =~ "..."
      refute String.contains?(output, String.duplicate("a", 250))
    end

    test "formats struct outputs" do
      trajectory =
        build_trajectory([
          %{
            input: "test",
            output: %TestStruct{name: "John"},
            tokens: %{input: 10, output: 5, total: 15},
            duration_ms: 100
          }
        ])

      output =
        capture_io(fn ->
          Inspector.print_trajectory(trajectory)
        end)

      assert output =~ "%Puck.Eval.InspectorTest.TestStruct{name: \"John\"}"
    end

    test "labels streamed steps" do
      step =
        Step.new(
          input: "test",
          output: "response",
          tokens: %{input: 0, output: 0, total: 0},
          duration_ms: 100,
          metadata: %{streamed: true}
        )

      trajectory = Trajectory.new([step])

      output =
        capture_io(fn ->
          Inspector.print_trajectory(trajectory)
        end)

      assert output =~ "Step 1: (streamed)"
    end

    test "handles multiple steps" do
      trajectory =
        build_trajectory([
          %{
            input: "first",
            output: "one",
            tokens: %{input: 10, output: 5, total: 15},
            duration_ms: 100
          },
          %{
            input: "second",
            output: "two",
            tokens: %{input: 20, output: 10, total: 30},
            duration_ms: 200
          },
          %{
            input: "third",
            output: "three",
            tokens: %{input: 30, output: 15, total: 45},
            duration_ms: 300
          }
        ])

      output =
        capture_io(fn ->
          Inspector.print_trajectory(trajectory)
        end)

      assert output =~ "Trajectory (3 steps, 90 tokens, 600ms)"
      assert output =~ "Step 1:"
      assert output =~ "Step 2:"
      assert output =~ "Step 3:"
    end

    test "writes to custom device" do
      trajectory =
        build_trajectory([
          %{
            input: "test",
            output: "output",
            tokens: %{input: 10, output: 5, total: 15},
            duration_ms: 100
          }
        ])

      {:ok, pid} = StringIO.open("")

      Inspector.print_trajectory(trajectory, device: pid)

      {_in, output} = StringIO.contents(pid)
      assert output =~ "Trajectory"
    end
  end

  describe "format_failures/1" do
    test "returns message when all graders pass" do
      result = %Result{
        passed?: true,
        output: "test",
        trajectory: Trajectory.empty(),
        grader_results: [
          %{grader: nil, result: :pass, passed?: true, reason: nil}
        ]
      }

      assert Inspector.format_failures(result) == "All graders passed"
    end

    test "formats single failure" do
      result = %Result{
        passed?: false,
        output: "test",
        trajectory: Trajectory.empty(),
        grader_results: [
          %{grader: nil, result: {:fail, "Too short"}, passed?: false, reason: "Too short"}
        ]
      }

      output = Inspector.format_failures(result)
      assert output =~ "1 failure:"
      assert output =~ "- Too short"
    end

    test "formats multiple failures" do
      result = %Result{
        passed?: false,
        output: "test",
        trajectory: Trajectory.empty(),
        grader_results: [
          %{grader: nil, result: {:fail, "Too short"}, passed?: false, reason: "Too short"},
          %{grader: nil, result: :pass, passed?: true, reason: nil},
          %{
            grader: nil,
            result: {:fail, "Missing email"},
            passed?: false,
            reason: "Missing email"
          }
        ]
      }

      output = Inspector.format_failures(result)
      assert output =~ "2 failures:"
      assert output =~ "- Too short"
      assert output =~ "- Missing email"
      refute output =~ "pass"
    end

    test "works with Result.from_graders" do
      trajectory =
        build_trajectory([
          %{
            input: "test",
            output: "result",
            tokens: %{input: 10, output: 5, total: 15},
            duration_ms: 100
          }
        ])

      result =
        Result.from_graders(
          "test",
          trajectory,
          [
            Graders.contains("missing"),
            Graders.max_steps(0)
          ]
        )

      output = Inspector.format_failures(result)
      assert output =~ "2 failures:"
      assert output =~ "does not contain"
      assert output =~ "exceeds max"
    end
  end

  defp build_trajectory(steps_data) do
    steps =
      Enum.map(steps_data, fn data ->
        Step.new(
          input: data.input,
          output: data.output,
          tokens: data.tokens,
          duration_ms: data.duration_ms,
          metadata: Map.get(data, :metadata, %{})
        )
      end)

    Trajectory.new(steps)
  end
end
