defmodule Puck.Eval.Result do
  @moduledoc """
  Aggregates grader results from an evaluation.

  The Result struct captures the output, trajectory, and results of applying
  multiple graders to an agent execution.

  ## Fields

    * `:passed?` - Whether all graders passed
    * `:output` - The agent's final output
    * `:trajectory` - The captured `Puck.Eval.Trajectory`
    * `:grader_results` - List of individual grader results

  ## Example

      alias Puck.Eval.{Collector, Graders, Result}

      {output, trajectory} = Collector.collect(fn -> MyAgent.run(input) end)

      result = Result.from_graders(output, trajectory, [
        Graders.contains("john@example.com"),
        Graders.max_steps(5)
      ])

      if result.passed? do
        IO.puts("All graders passed!")
      else
        IO.puts("Failed graders:")
        for gr <- result.grader_results, !gr.passed? do
          IO.puts("  - \#{gr.reason}")
        end
      end

  """

  alias Puck.Eval.{Grader, Trajectory}

  defstruct [
    :passed?,
    :output,
    :trajectory,
    :grader_results
  ]

  @type grader_result :: %{
          grader: module() | (term(), Trajectory.t() -> Grader.result()),
          result: Grader.result(),
          passed?: boolean(),
          reason: String.t() | nil
        }

  @type t :: %__MODULE__{
          passed?: boolean(),
          output: term(),
          trajectory: Trajectory.t(),
          grader_results: [grader_result()]
        }

  @doc """
  Creates a Result by applying graders to an output and trajectory.

  Returns a Result struct with all grader results aggregated.
  The `passed?` field is true only if all graders pass.

  ## Example

      result = Result.from_graders(output, trajectory, [
        Graders.contains("hello"),
        Graders.max_steps(3)
      ])

      result.passed?         # => true if all passed
      result.grader_results  # => list of individual results

  """
  def from_graders(output, %Trajectory{} = trajectory, graders) when is_list(graders) do
    grader_results =
      Enum.map(graders, fn grader ->
        result = Grader.run(grader, output, trajectory)

        %{
          grader: grader,
          result: result,
          passed?: Grader.passed?(result),
          reason: extract_reason(result)
        }
      end)

    %__MODULE__{
      passed?: Enum.all?(grader_results, & &1.passed?),
      output: output,
      trajectory: trajectory,
      grader_results: grader_results
    }
  end

  @doc """
  Returns only the failed grader results.

  ## Example

      failed = Result.failures(result)
      for f <- failed do
        IO.puts("Failed: \#{f.reason}")
      end

  """
  def failures(%__MODULE__{grader_results: results}) do
    Enum.reject(results, & &1.passed?)
  end

  @doc """
  Returns only the passed grader results.
  """
  def passes(%__MODULE__{grader_results: results}) do
    Enum.filter(results, & &1.passed?)
  end

  @doc """
  Returns a summary map of the result.

  Useful for logging or serialization.

  ## Example

      summary = Result.summary(result)
      # => %{
      #   passed?: true,
      #   total_graders: 3,
      #   passed_count: 3,
      #   failed_count: 0,
      #   total_steps: 2,
      #   total_tokens: 385,
      #   total_duration_ms: 1200
      # }

  """
  def summary(%__MODULE__{} = result) do
    %{
      passed?: result.passed?,
      total_graders: length(result.grader_results),
      passed_count: length(passes(result)),
      failed_count: length(failures(result)),
      total_steps: result.trajectory.total_steps,
      total_tokens: result.trajectory.total_tokens,
      total_duration_ms: result.trajectory.total_duration_ms
    }
  end

  defp extract_reason(:pass), do: nil
  defp extract_reason({:fail, reason}), do: reason
end
