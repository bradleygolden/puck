defmodule Puck.Eval.Grader do
  @moduledoc """
  Behaviour for evaluation graders.

  Graders score agent output and trajectory. They can be implemented as
  modules using this behaviour, or as simple 2-arity functions.

  ## Grader Result

  Graders return one of:

    * `:pass` - The evaluation passed
    * `{:fail, reason}` - The evaluation failed with a reason string

  ## Using Functions

  The simplest way to create a grader is with a function:

      grader = fn output, trajectory ->
        if String.contains?(output, "john@example.com") do
          :pass
        else
          {:fail, "Expected email not found"}
        end
      end

      grader.(output, trajectory)

  ## Using Modules

  For reusable graders, implement this behaviour:

      defmodule MyApp.Graders.ContainsEmail do
        @behaviour Puck.Eval.Grader

        @impl true
        def grade(output, _trajectory) do
          if output =~ ~r/[\\w.]+@[\\w.]+/ do
            :pass
          else
            {:fail, "No email address found in output"}
          end
        end
      end

  ## Applying Graders

  Use `Puck.Eval.Grader.run/3` to run either type of grader:

      Grader.run(grader_fn, output, trajectory)
      Grader.run(MyApp.Graders.ContainsEmail, output, trajectory)

  """

  alias Puck.Eval.Trajectory

  @type result :: :pass | {:fail, reason :: String.t()}

  @doc """
  Grades the output and trajectory of an agent execution.

  Returns `:pass` if the evaluation succeeds, or `{:fail, reason}` if it fails.
  """
  @callback grade(output :: term(), trajectory :: Trajectory.t()) :: result()

  @doc """
  Runs a grader on an output and trajectory.

  Accepts either a grader function (2-arity) or a module implementing
  the `Puck.Eval.Grader` behaviour.

  ## Examples

      # With a function
      grader = fn output, _traj -> if output == "hello", do: :pass, else: {:fail, "wrong"} end
      Grader.run(grader, "hello", trajectory)
      # => :pass

      # With a module
      Grader.run(MyGrader, output, trajectory)
      # => :pass or {:fail, reason}

  """
  def run(grader, output, trajectory) when is_function(grader, 2) do
    grader.(output, trajectory)
  end

  def run(grader, output, trajectory) when is_atom(grader) do
    grader.grade(output, trajectory)
  end

  @doc """
  Runs multiple graders and returns all results.

  Returns a list of `{grader, result}` tuples.

  ## Example

      graders = [
        Graders.contains("hello"),
        Graders.max_steps(3)
      ]

      results = Grader.run_all(graders, output, trajectory)
      # => [{grader1, :pass}, {grader2, {:fail, "4 steps exceeds max of 3"}}]

  """
  def run_all(graders, output, trajectory) when is_list(graders) do
    Enum.map(graders, fn grader ->
      {grader, run(grader, output, trajectory)}
    end)
  end

  @doc """
  Returns true if the grader result indicates a pass.

  ## Examples

      Grader.passed?(:pass)
      # => true

      Grader.passed?({:fail, "reason"})
      # => false

  """
  def passed?(:pass), do: true
  def passed?({:fail, _}), do: false
end
