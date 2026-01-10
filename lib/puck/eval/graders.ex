defmodule Puck.Eval.Graders do
  @moduledoc """
  Built-in graders for common evaluation patterns.

  All graders return functions that can be used with `Puck.Eval.Grader.run/3`
  or `Puck.Eval.Result.from_graders/3`.

  ## Output Graders

  Check the agent's final output:

    * `contains/1` - Output contains a substring
    * `matches/1` - Output matches a regex
    * `equals/1` - Output equals expected value
    * `satisfies/1` - Output passes a predicate function

  ## Trajectory Graders

  Check the agent's execution trajectory:

    * `max_steps/1` - Trajectory has at most N steps
    * `max_tokens/1` - Trajectory used at most N tokens
    * `max_duration_ms/1` - Trajectory took at most N milliseconds

  ## Step Output Graders

  Check what was produced during execution:

    * `output_produced/1,2` - A specific struct type was produced
    * `output_matches/1,2` - A step output matches a predicate (for value checks)
    * `output_not_produced/1` - A specific struct type was not produced
    * `output_sequence/1` - Struct types were produced in a specific order

  ## Example

      alias Puck.Eval.{Collector, Graders, Result}

      {output, trajectory} = Collector.collect(fn -> MyAgent.run(input) end)

      result = Result.from_graders(output, trajectory, [
        Graders.contains("john@example.com"),
        Graders.max_steps(5),
        Graders.output_produced(LookupContact)
      ])

      result.passed?  # => true or false

  """

  @doc """
  Checks if the output contains the given substring.

  ## Example

      grader = Graders.contains("hello")
      grader.("hello world", trajectory)
      # => :pass

      grader.("goodbye", trajectory)
      # => {:fail, "Output does not contain \\"hello\\""}

  """
  def contains(substring) when is_binary(substring) do
    fn output, _trajectory ->
      output_str = to_string_safe(output)

      if String.contains?(output_str, substring) do
        :pass
      else
        {:fail, "Output does not contain #{inspect(substring)}"}
      end
    end
  end

  @doc """
  Checks if the output matches the given regex.

  ## Example

      grader = Graders.matches(~r/\\d{3}-\\d{4}/)
      grader.("Call 555-1234", trajectory)
      # => :pass

  """
  def matches(%Regex{} = regex) do
    fn output, _trajectory ->
      output_str = to_string_safe(output)

      if Regex.match?(regex, output_str) do
        :pass
      else
        {:fail, "Output does not match #{inspect(regex)}"}
      end
    end
  end

  @doc """
  Checks if the output equals the expected value.

  ## Example

      grader = Graders.equals("success")
      grader.("success", trajectory)
      # => :pass

  """
  def equals(expected) do
    fn output, _trajectory ->
      if output == expected do
        :pass
      else
        {:fail, "Output #{inspect(output)} does not equal #{inspect(expected)}"}
      end
    end
  end

  @doc """
  Checks if the output satisfies a predicate function.

  The predicate receives the output and should return a boolean.

  ## Example

      grader = Graders.satisfies(fn output -> String.length(output) > 10 end)
      grader.("hello world!", trajectory)
      # => :pass

  """
  def satisfies(predicate) when is_function(predicate, 1) do
    fn output, _trajectory ->
      if predicate.(output) do
        :pass
      else
        {:fail, "Output does not satisfy predicate"}
      end
    end
  end

  @doc """
  Checks that the trajectory has at most N steps.

  ## Example

      grader = Graders.max_steps(3)
      grader.(output, %Trajectory{total_steps: 2})
      # => :pass

      grader.(output, %Trajectory{total_steps: 5})
      # => {:fail, "5 steps exceeds max of 3"}

  """
  def max_steps(n) when is_integer(n) and n >= 0 do
    fn _output, trajectory ->
      if trajectory.total_steps <= n do
        :pass
      else
        {:fail, "#{trajectory.total_steps} steps exceeds max of #{n}"}
      end
    end
  end

  @doc """
  Checks that the trajectory used at most N tokens.

  ## Example

      grader = Graders.max_tokens(1000)
      grader.(output, %Trajectory{total_tokens: 500})
      # => :pass

  """
  def max_tokens(n) when is_integer(n) and n >= 0 do
    fn _output, trajectory ->
      if trajectory.total_tokens <= n do
        :pass
      else
        {:fail, "#{trajectory.total_tokens} tokens exceeds max of #{n}"}
      end
    end
  end

  @doc """
  Checks that the trajectory took at most N milliseconds.

  ## Example

      grader = Graders.max_duration_ms(5000)
      grader.(output, %Trajectory{total_duration_ms: 3000})
      # => :pass

  """
  def max_duration_ms(n) when is_integer(n) and n >= 0 do
    fn _output, trajectory ->
      if trajectory.total_duration_ms <= n do
        :pass
      else
        {:fail, "#{trajectory.total_duration_ms}ms exceeds max of #{n}ms"}
      end
    end
  end

  @doc """
  Checks that a specific struct type was produced during execution.

  Matches directly on struct module types - no extractor needed.

  ## Options

    * `:times` - Exact number of times this struct should appear (default: at least once)

  ## Example

      # Check if any step produced a LookupContact struct
      grader = Graders.output_produced(LookupContact)
      grader.(output, trajectory)
      # => :pass if any step.output was %LookupContact{}

      # Check exact count
      grader = Graders.output_produced(LookupContact, times: 2)

  """
  def output_produced(struct_module, opts \\ [])

  def output_produced(struct_module, opts) when is_atom(struct_module) do
    times = Keyword.get(opts, :times)

    fn _output, trajectory ->
      count = count_struct_type(trajectory, struct_module)

      cond do
        times && count == times ->
          :pass

        times && count != times ->
          {:fail, "#{inspect(struct_module)} produced #{count} times, expected #{times}"}

        count > 0 ->
          :pass

        true ->
          {:fail, "#{inspect(struct_module)} was not produced"}
      end
    end
  end

  @doc """
  Checks that any step output matches a predicate function.

  Use this to assert on specific struct values, not just types.

  ## Options

    * `:times` - Exact number of matches required (default: at least once)

  ## Example

      # Check if any step produced a LookupContact for "John"
      grader = Graders.output_matches(fn
        %LookupContact{name: "John"} -> true
        _ -> false
      end)

      # Check exact count of matching outputs
      grader = Graders.output_matches(
        fn %LookupContact{} -> true; _ -> false end,
        times: 2
      )

  """
  def output_matches(predicate, opts \\ [])

  def output_matches(predicate, opts) when is_function(predicate, 1) do
    times = Keyword.get(opts, :times)

    fn _output, trajectory ->
      count = Enum.count(trajectory.steps, fn step -> predicate.(step.output) end)

      cond do
        times && count == times ->
          :pass

        times && count != times ->
          {:fail, "Output matched #{count} times, expected #{times}"}

        count > 0 ->
          :pass

        true ->
          {:fail, "No step output matched the predicate"}
      end
    end
  end

  @doc """
  Checks that a specific struct type was NOT produced during execution.

  ## Example

      grader = Graders.output_not_produced(DeleteContact)
      grader.(output, trajectory)
      # => :pass if no step.output was %DeleteContact{}

  """
  def output_not_produced(struct_module) when is_atom(struct_module) do
    fn _output, trajectory ->
      count = count_struct_type(trajectory, struct_module)

      if count > 0 do
        {:fail, "#{inspect(struct_module)} was produced but should not have been"}
      else
        :pass
      end
    end
  end

  @doc """
  Checks that struct types were produced in a specific order.

  The sequence must appear somewhere in the trajectory, but other struct
  types can appear between the expected ones.

  ## Example

      # Check investigation pattern: snapshot -> execute -> alert
      grader = Graders.output_sequence([TakeSnapshot, Execute, FireAlert])
      grader.(output, trajectory)
      # => :pass if structs appeared in that order

  """
  def output_sequence(struct_modules) when is_list(struct_modules) do
    fn _output, trajectory ->
      struct_types = extract_struct_types(trajectory)

      if subsequence?(struct_modules, struct_types) do
        :pass
      else
        {:fail,
         "Expected sequence #{inspect(struct_modules)} not found in #{inspect(struct_types)}"}
      end
    end
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)

  defp count_struct_type(trajectory, struct_module) do
    Enum.count(trajectory.steps, fn step ->
      is_struct(step.output, struct_module)
    end)
  end

  defp extract_struct_types(trajectory) do
    trajectory.steps
    |> Enum.map(fn step ->
      if is_struct(step.output), do: step.output.__struct__, else: nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp subsequence?([], _haystack), do: true
  defp subsequence?(_needle, []), do: false

  defp subsequence?([n | rest_needle], [n | rest_haystack]) do
    subsequence?(rest_needle, rest_haystack)
  end

  defp subsequence?(needle, [_h | rest_haystack]) do
    subsequence?(needle, rest_haystack)
  end
end
