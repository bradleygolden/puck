defmodule Puck.Eval.Trial do
  @moduledoc """
  Multi-trial execution for measuring agent reliability and consistency.

  Executes an agent function multiple times and computes:
  - `pass@k`: At least one success in k trials (reliability)
  - `pass^k`: All k trials succeed (consistency)
  - `pass_rate`: Fraction of successful trials

  ## Example

      alias Puck.Eval.{Trial, Graders}

      Trial.run_trials(
        fn -> MyAgent.run("Find contact") end,
        [Graders.contains("john@example.com")],
        k: 5
      )
      # => %{
      #   k: 5,
      #   results: [...],
      #   pass_at_k: true,
      #   pass_carrot_k: false,
      #   pass_rate: 0.6
      # }

  Agent with 75% per-trial success:
  - pass@3 ≈ 98% (1 - 0.25³)
  - pass^3 ≈ 42% (0.75³)

  ## Process Isolation

  Each trial runs in a separate process via `Task.async_stream/3`, providing
  clean state per execution. BEAM's process isolation replaces Docker containers
  for clean environments.
  """

  alias Puck.Eval.{Collector, Result}

  @doc """
  Runs agent function k times and grades each execution.

  ## Options

    * `:k` - Number of trials (default: 3)
    * `:concurrency` - Max concurrent trials (default: `System.schedulers_online()`)

  ## Returns

  Map with:
    * `:k` - Number of trials run
    * `:results` - List of `Puck.Eval.Result` structs
    * `:pass_at_k` - Boolean, true if ≥1 trial passed
    * `:pass_carrot_k` - Boolean, true if all trials passed
    * `:pass_rate` - Float between 0.0 and 1.0

  ## Example

      Trial.run_trials(
        fn -> MyAgent.run("task") end,
        [Graders.contains("success")],
        k: 5,
        concurrency: 3
      )

  """
  def run_trials(agent_fn, graders, opts \\ [])
      when is_function(agent_fn, 0) and is_list(graders) do
    k = Keyword.get(opts, :k, 3)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    results =
      1..k
      |> Task.async_stream(
        fn _ ->
          {output, trajectory} = Collector.collect(agent_fn)
          Result.from_graders(output, trajectory, graders)
        end,
        max_concurrency: concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    %{
      k: k,
      results: results,
      pass_at_k: Enum.any?(results, & &1.passed?),
      pass_carrot_k: Enum.all?(results, & &1.passed?),
      pass_rate: Enum.count(results, & &1.passed?) / k
    }
  end
end
