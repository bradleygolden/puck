defmodule Puck.Eval.Inspector do
  @moduledoc """
  Debugging tools for trajectories and evaluation results.

  When evals fail, developers need human-readable output to determine if the
  eval is broken or the agent is broken. Anthropic emphasizes reading transcripts
  to ensure evals "feel fair".

  ## Example

      {output, trajectory} = Collector.collect(fn ->
        MyAgent.run("Find John")
      end)

      Inspector.print_trajectory(trajectory)
      # => Prints formatted trajectory to console

      result = Result.from_graders(output, trajectory, graders)

      unless result.passed? do
        IO.puts(Inspector.format_failures(result))
      end

  """

  alias Puck.Eval.{Result, Trajectory}

  @doc """
  Prints a human-readable trajectory to the console.

  ## Options

    * `:device` - IO device to print to (default: `:stdio`)
    * `:max_length` - Max characters for output display (default: 200)

  ## Example

      Inspector.print_trajectory(trajectory)
      # Trajectory (3 steps, 425 tokens, 1250ms)
      #
      # Step 1:
      #   Input: "Find John's email"
      #   Output: %LookupContact{name: "John"}
      #   Tokens: 150 in, 30 out (180 total)
      #   Duration: 450ms
      # ...

  """
  def print_trajectory(trajectory, opts \\ [])

  def print_trajectory(%Trajectory{} = trajectory, opts) do
    device = Keyword.get(opts, :device, :stdio)
    max_length = Keyword.get(opts, :max_length, 200)

    IO.puts(device, format_trajectory_header(trajectory))
    IO.puts(device, "")

    trajectory.steps
    |> Enum.with_index(1)
    |> Enum.each(fn {step, index} ->
      IO.puts(device, format_step(step, index, max_length))
      IO.puts(device, "")
    end)

    :ok
  end

  @doc """
  Formats grader failures into a readable string.

  Returns a string listing all failed graders and their reasons.
  Suitable for ExUnit assertions or logging.

  ## Example

      result = Result.from_graders(output, trajectory, graders)

      unless result.passed? do
        IO.puts(Inspector.format_failures(result))
      end

      # Or in tests:
      assert result.passed?, Inspector.format_failures(result)

  ## Output Format

      2 failures:
        - Output does not contain "john@example.com"
        - 7 steps exceeds max of 5

  """
  def format_failures(%Result{} = result) do
    failures = Result.failures(result)

    case length(failures) do
      0 ->
        "All graders passed"

      count ->
        header = "#{count} failure#{plural(count)}:"
        reasons = Enum.map_join(failures, "\n", &"  - #{&1.reason}")
        "#{header}\n#{reasons}"
    end
  end

  defp format_trajectory_header(trajectory) do
    "Trajectory (#{trajectory.total_steps} steps, #{trajectory.total_tokens} tokens, #{trajectory.total_duration_ms}ms)"
  end

  defp format_step(step, index, max_length) do
    input_str = truncate(inspect(step.input), max_length)
    output_str = truncate(format_output(step), max_length)

    tokens = step.tokens
    token_str = "#{tokens.input} in, #{tokens.output} out (#{tokens.total} total)"

    streamed_label = if step.metadata[:streamed], do: " (streamed)", else: ""

    """
    Step #{index}:#{streamed_label}
      Input: #{input_str}
      Output: #{output_str}
      Tokens: #{token_str}
      Duration: #{step.duration_ms}ms
    """
    |> String.trim_trailing()
  end

  defp format_output(step), do: inspect(step.output)

  defp truncate(str, max_length) when byte_size(str) <= max_length, do: str

  defp truncate(str, max_length) do
    String.slice(str, 0, max_length) <> "..."
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
