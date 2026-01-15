defmodule Puck.Eval do
  @moduledoc """
  Evaluation primitives for testing agents built on Puck.

  Puck.Eval provides minimal building blocks for evaluating LLM agents.
  These primitives can be composed however you need - with ExUnit, custom
  runners, or production monitoring.

  ## Core Primitives

    * `Puck.Eval.Trajectory` - Captures what happened during execution
    * `Puck.Eval.Step` - A single LLM call within a trajectory
    * `Puck.Eval.Collector` - Captures trajectory via telemetry
    * `Puck.Eval.Grader` - Behaviour for scoring
    * `Puck.Eval.Graders` - Built-in graders
    * `Puck.Eval.Result` - Aggregates grader results

  ## Helpers

    * `Puck.Eval.Trial` - Multi-trial execution with pass@k metrics
    * `Puck.Eval.Graders.LLM` - LLM-as-judge for subjective criteria
    * `Puck.Eval.Inspector` - Debug tools for trajectories and failures

  ## Quick Example

      alias Puck.Eval.{Collector, Graders, Result}

      # Capture trajectory from your agent
      {output, trajectory} = Collector.collect(fn ->
        MyAgent.run("Find John's email")
      end)

      # Apply graders
      result = Result.from_graders(output, trajectory, [
        Graders.contains("john@example.com"),
        Graders.max_steps(5),
        Graders.output_produced(LookupContact)
      ])

      # Check result
      result.passed?  # => true or false

  ## Multi-Trial Evaluation

      alias Puck.Eval.Trial

      # Run 5 trials, compute reliability metrics
      results = Trial.run_trials(
        fn -> MyAgent.run("Find contact") end,
        [Graders.contains("john@example.com")],
        k: 5
      )

      results.pass_at_k      # => true (≥1 success)
      results.pass_carrot_k  # => false (not all succeeded)
      results.pass_rate      # => 0.6 (60% success rate)

  ## LLM-as-Judge

      alias Puck.Eval.Graders.LLM

      judge_client = Puck.Client.new(
        {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5"}
      )

      result = Result.from_graders(output, trajectory, [
        LLM.rubric(judge_client, \"\"\"
        - Response is polite
        - Response is helpful
        - Response is concise
        \"\"\")
      ])

  ## Debugging

      alias Puck.Eval.Inspector

      # Print human-readable trajectory
      Inspector.print_trajectory(trajectory)

      # Format grader failures
      unless result.passed? do
        IO.puts(Inspector.format_failures(result))
      end

  ## In ExUnit

      test "agent finds contact" do
        {output, trajectory} = Puck.Eval.collect(fn ->
          MyAgent.run("Find John's email")
        end)

        assert trajectory.total_steps <= 3
        assert output =~ "john@example.com"
      end

  ## In Production Monitoring

      def monitor_agent_call(input) do
        {output, trajectory} = Puck.Eval.collect(fn ->
          MyAgent.run(input)
        end)

        :telemetry.execute([:my_app, :agent, :metrics], %{
          tokens: trajectory.total_tokens,
          steps: trajectory.total_steps,
          duration_ms: trajectory.total_duration_ms
        })

        output
      end

  """

  alias Puck.Eval.{Collector, Result, Trajectory}

  @doc """
  Collects trajectory from the provided function.

  Convenience delegate to `Puck.Eval.Collector.collect/1`.

  ## Example

      {output, trajectory} = Puck.Eval.collect(fn ->
        MyAgent.run("Find John's email")
      end)

  """
  defdelegate collect(fun), to: Collector

  @doc """
  Collects trajectory with options.

  Convenience delegate to `Puck.Eval.Collector.collect/2`.

  ## Options

    * `:timeout` - Time to wait for telemetry events (default: 100ms)

  """
  defdelegate collect(fun, opts), to: Collector

  @doc """
  Creates a Result by applying graders to output and trajectory.

  Convenience delegate to `Puck.Eval.Result.from_graders/3`.

  ## Example

      result = Puck.Eval.grade(output, trajectory, [
        Graders.contains("hello"),
        Graders.max_steps(3)
      ])

  """
  def grade(output, trajectory, graders) do
    Result.from_graders(output, trajectory, graders)
  end

  @doc """
  Runs a single grader on output and trajectory.

  Convenience delegate to `Puck.Eval.Grader.run/3`.

  ## Example

      Puck.Eval.run_grader(Graders.contains("hello"), output, trajectory)
      # => :pass or {:fail, reason}

  """
  defdelegate run_grader(grader, output, trajectory), to: Puck.Eval.Grader, as: :run

  @doc """
  Creates an empty trajectory.

  ## Example

      trajectory = Puck.Eval.empty_trajectory()

  """
  def empty_trajectory, do: Trajectory.empty()

  @doc """
  Creates a trajectory from a list of steps.

  ## Example

      steps = [
        Puck.Eval.Step.new(input: "hi", output: "hello", tokens: %{total: 10})
      ]
      trajectory = Puck.Eval.trajectory(steps)

  """
  def trajectory(steps), do: Trajectory.new(steps)
end
