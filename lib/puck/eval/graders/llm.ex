defmodule Puck.Eval.Graders.LLM do
  @moduledoc """
  LLM-as-judge graders for subjective evaluation.

  Use when code-based graders can't capture nuanced criteria like tone,
  empathy, or code quality. LLM graders are non-deterministic - the same
  output may receive different scores on retries.

  ## Example

      alias Puck.Eval.{Collector, Graders, Result}
      alias Puck.Eval.Graders.LLM

      judge_client = Puck.Client.new(
        {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5"}
      )

      {output, trajectory} = Collector.collect(fn ->
        CustomerAgent.respond("How do I return an item?")
      end)

      result = Result.from_graders(output, trajectory, [
        LLM.rubric(judge_client, \"\"\"
        - Response is polite
        - Response explains return process
        - Response asks for order number
        \"\"\")
      ])

  Use fast, cheap models (Haiku) for judges to minimize cost and latency.

  ## Rubric Format

  Simple bullet points describing criteria. Judge decides pass/fail based
  on whether all criteria are met.

  ## Non-Determinism

  LLM judges are probabilistic. For reliability testing, run multiple trials
  with `Puck.Eval.Trial.run_trials/3` and measure pass@k metrics.
  """

  defmodule Judgment do
    @moduledoc false
    defstruct [:passed, :reason]
  end

  @doc """
  Creates an LLM-as-judge grader using a rubric.

  Returns a grader function compatible with `Puck.Eval.Result.from_graders/3`.

  ## Parameters

    * `client` - Puck.Client for the judge LLM (recommend fast model like Haiku)
    * `rubric` - String with bullet points describing evaluation criteria

  ## Returns

  Grader function that returns `:pass` or `{:fail, reason}`.

  ## Example

      judge = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5"})

      grader = LLM.rubric(judge, \"\"\"
      - Response is polite
      - Response is concise
      - Response answers the question
      \"\"\")

      grader.("Thanks! Your order is confirmed.", trajectory)
      # => :pass

  """
  def rubric(client, rubric) when is_binary(rubric) do
    fn output, _trajectory ->
      output_str = to_string_safe(output)
      prompt = build_prompt(rubric, output_str)

      case Puck.call(client, prompt, Puck.Context.new(), output_schema: schema()) do
        {:ok, response, _ctx} ->
          to_grader_result(response.content)

        {:error, reason} ->
          {:fail, "LLM judge error: #{inspect(reason)}"}
      end
    end
  end

  defp schema do
    Zoi.struct(
      Judgment,
      %{
        passed: Zoi.boolean(description: "true if all rubric criteria are met, false otherwise"),
        reason:
          Zoi.string(description: "explanation of why criteria passed or failed")
          |> Zoi.nullable()
      },
      coerce: true
    )
  end

  defp build_prompt(rubric, output) do
    """
    Evaluate this output against the rubric below.

    Rubric:
    #{rubric}

    Output:
    #{output}
    """
  end

  defp to_grader_result(%Judgment{passed: true}), do: :pass
  defp to_grader_result(%Judgment{passed: false, reason: reason}), do: {:fail, reason}

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)
end
