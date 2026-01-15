defmodule Integration.EvalLLMGraderTest do
  use ExUnit.Case

  alias Puck.Eval.Graders.LLM
  alias Puck.Eval.Result

  @moduletag :integration
  @moduletag :llm

  setup do
    if System.get_env("ANTHROPIC_API_KEY") do
      judge_client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5"})
      {:ok, judge_client: judge_client}
    else
      :skip
    end
  end

  test "judges polite response", %{judge_client: judge} do
    output = "Thank you so much for your question! I'd be happy to help."

    result =
      Result.from_graders(
        output,
        Puck.Eval.empty_trajectory(),
        [
          LLM.rubric(judge, """
          - Response is polite
          - Response is helpful
          """)
        ]
      )

    assert result.passed?
  end

  test "judges rude response", %{judge_client: judge} do
    output = "That's a stupid question. Figure it out yourself."

    result =
      Result.from_graders(
        output,
        Puck.Eval.empty_trajectory(),
        [
          LLM.rubric(judge, """
          - Response is polite
          - Response is helpful
          """)
        ]
      )

    refute result.passed?
    failures = Result.failures(result)
    assert failures != []
  end
end
