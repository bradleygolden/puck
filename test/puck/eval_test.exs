defmodule Puck.EvalTest do
  use ExUnit.Case, async: false

  alias Puck.Eval
  alias Puck.Eval.{Graders, Step, Trajectory}

  defmodule LookupContact do
    @moduledoc false
    defstruct type: "lookup_contact", name: nil
  end

  defmodule CreateTask do
    @moduledoc false
    defstruct type: "create_task", title: nil
  end

  defmodule Done do
    @moduledoc false
    defstruct type: "done", message: nil
  end

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

    test "captures trajectory from agent loop with structured outputs" do
      responses = [
        %LookupContact{name: "John"},
        %CreateTask{title: "Follow up"},
        %Done{message: "Task created"}
      ]

      {output, trajectory} =
        Eval.collect(fn ->
          loop_with_responses(responses, "Find John", Puck.Context.new())
        end)

      assert output == "Task created"
      assert trajectory.total_steps == 3

      result =
        Eval.grade(output, trajectory, [
          Graders.output_produced(LookupContact),
          Graders.output_produced(CreateTask),
          Graders.output_produced(Done),
          Graders.output_sequence([LookupContact, CreateTask, Done]),
          Graders.max_steps(5)
        ])

      assert result.passed?
    end

    test "detects when agent exceeds step limit with structured outputs" do
      responses = List.duplicate(%LookupContact{name: "John"}, 6)

      {_output, trajectory} =
        Eval.collect(fn ->
          loop_with_responses(responses, "Keep looking", Puck.Context.new())
        end)

      assert trajectory.total_steps == 6

      result =
        Eval.grade("exceeded", trajectory, [
          Graders.max_steps(3)
        ])

      refute result.passed?
      assert length(Eval.Result.failures(result)) == 1
    end

    test "grades output values with output_matches" do
      responses = [
        %LookupContact{name: "Jane Doe"},
        %Done{message: "Found Jane"}
      ]

      {output, trajectory} =
        Eval.collect(fn ->
          loop_with_responses(responses, "Find Jane", Puck.Context.new())
        end)

      result =
        Eval.grade(output, trajectory, [
          Graders.output_matches(fn
            %LookupContact{name: "Jane Doe"} -> true
            _ -> false
          end),
          Graders.output_matches(&match?(%Done{message: "Found" <> _}, &1))
        ])

      assert result.passed?
    end

    test "captures trajectory through compaction events" do
      client =
        Puck.Client.new(
          {Puck.Backends.Mock, response: "Response"},
          auto_compaction: {:sliding_window, window_size: 4}
        )

      {_output, trajectory} =
        Eval.collect(fn ->
          Enum.reduce(1..6, Puck.Context.new(), fn i, ctx ->
            {:ok, _resp, ctx} = Puck.call(client, "Message #{i}", ctx)
            ctx
          end)
        end)

      assert trajectory.total_steps == 6

      result =
        Eval.grade("done", trajectory, [
          Graders.max_steps(10),
          Graders.satisfies(fn _ -> true end)
        ])

      assert result.passed?
    end

    test "tracks cumulative tokens across steps" do
      client = Puck.Client.new({Puck.Backends.Mock, response: "Short response"})

      {_output, trajectory} =
        Eval.collect(fn ->
          ctx = Puck.Context.new()
          {:ok, _, ctx} = Puck.call(client, "First message", ctx)
          {:ok, _, ctx} = Puck.call(client, "Second message", ctx)
          {:ok, _, _ctx} = Puck.call(client, "Third message", ctx)
          :done
        end)

      assert trajectory.total_steps == 3
      assert trajectory.total_tokens > 0

      result =
        Eval.grade(:done, trajectory, [
          Graders.max_tokens(10_000)
        ])

      assert result.passed?
    end

    test "combines multiple graders in result" do
      client = Puck.Client.new({Puck.Backends.Mock, response: "hello world"})

      {output, trajectory} =
        Eval.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "Say hello")
          response.content
        end)

      result =
        Eval.grade(output, trajectory, [
          Graders.contains("hello"),
          Graders.contains("world"),
          Graders.matches(~r/hello.*world/),
          Graders.max_steps(1),
          Graders.max_tokens(1000),
          Graders.satisfies(&is_binary/1)
        ])

      assert result.passed?
      assert length(result.grader_results) == 6
      assert Eval.Result.summary(result).passed_count == 6
    end

    test "reports all failures when multiple graders fail" do
      client = Puck.Client.new({Puck.Backends.Mock, response: "hi"})

      {output, trajectory} =
        Eval.collect(fn ->
          ctx = Puck.Context.new()
          {:ok, _, ctx} = Puck.call(client, "1", ctx)
          {:ok, _, ctx} = Puck.call(client, "2", ctx)
          {:ok, _, ctx} = Puck.call(client, "3", ctx)
          {:ok, resp, _ctx} = Puck.call(client, "4", ctx)
          resp.content
        end)

      result =
        Eval.grade(output, trajectory, [
          Graders.contains("hello"),
          Graders.max_steps(2),
          Graders.equals("wrong")
        ])

      refute result.passed?

      failures = Eval.Result.failures(result)
      assert length(failures) == 3
    end
  end

  defp loop_with_responses([], _input, _ctx), do: "exceeded"

  defp loop_with_responses([response | rest], input, ctx) do
    client = Puck.Client.new({Puck.Backends.Mock, response: response})
    {:ok, %{content: action}, ctx} = Puck.call(client, input, ctx)

    case action do
      %Done{message: msg} ->
        msg

      %LookupContact{name: name} ->
        loop_with_responses(rest, "Found contact: #{name}", ctx)

      %CreateTask{title: title} ->
        loop_with_responses(rest, "Created task: #{title}", ctx)
    end
  end
end
