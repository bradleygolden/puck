defmodule Puck.Integration.EvalTest do
  @moduledoc """
  Integration tests for Puck.Eval with real LLM backends.

  Tests trajectory capture, grading, and compaction summarizer dogfooding
  with actual API calls.
  """

  use Puck.IntegrationCase

  alias Puck.Eval
  alias Puck.Eval.Graders

  defmodule LookupContact do
    @moduledoc false
    defstruct type: "lookup_contact", name: nil
  end

  defmodule Done do
    @moduledoc false
    defstruct type: "done", message: nil
  end

  defp schema do
    Zoi.union([
      Zoi.struct(
        LookupContact,
        %{
          type: Zoi.literal("lookup_contact"),
          name: Zoi.string(description: "Name of contact to look up")
        },
        coerce: true
      ),
      Zoi.struct(
        Done,
        %{
          type: Zoi.literal("done"),
          message: Zoi.string(description: "Final response to user")
        },
        coerce: true
      )
    ])
  end

  describe "ReqLLM eval" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          system_prompt: "You are a helpful assistant. Keep responses brief."
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "captures trajectory from single call", %{client: client} do
      {output, trajectory} =
        Eval.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "Say hello in exactly 3 words")
          response.content
        end)

      assert is_binary(output)
      assert trajectory.total_steps == 1
      assert trajectory.total_tokens > 0
      assert trajectory.total_duration_ms > 0

      result =
        Eval.grade(output, trajectory, [
          Graders.satisfies(&is_binary/1),
          Graders.max_steps(1),
          Graders.max_tokens(500)
        ])

      assert result.passed?
    end

    @tag timeout: 120_000
    test "captures trajectory from agent loop with structured outputs", %{client: client} do
      crm_find = fn name ->
        "Found: #{name}, email: #{String.downcase(name) |> String.replace(" ", ".")}@example.com"
      end

      {output, trajectory} =
        Eval.collect(fn ->
          loop(client, "Find John Smith's email", Puck.Context.new(), crm_find)
        end)

      assert is_binary(output)
      assert trajectory.total_steps >= 1
      assert trajectory.total_tokens > 0

      result =
        Eval.grade(output, trajectory, [
          Graders.output_produced(Done),
          Graders.max_steps(5)
        ])

      assert result.passed?, "Grader failures: #{inspect(Eval.Result.failures(result))}"
    end

    @tag timeout: 60_000
    test "captures trajectory from streaming response", %{client: client} do
      {output, trajectory} =
        Eval.collect(fn ->
          {:ok, stream, _ctx} = Puck.stream(client, "Count from 1 to 5")
          Enum.map_join(stream, "", & &1.content)
        end)

      assert is_binary(output)
      assert String.length(output) > 0
      assert trajectory.total_steps == 1
      # streaming doesn't capture tokens currently
      assert trajectory.total_tokens == 0

      [step] = trajectory.steps
      assert step.metadata[:streamed] == true
      assert step.output == output
    end
  end

  describe "ReqLLM eval + compaction summarizer (dogfood)" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          system_prompt:
            "You are a helpful assistant. Keep responses very brief (1-2 sentences).",
          auto_compaction: {:summarize, max_tokens: 300, keep_last: 2}
        )

      [client: client]
    end

    @tag timeout: 180_000
    test "captures full trajectory including compaction summarizer calls", %{client: client} do
      {_output, trajectory} =
        Eval.collect(fn ->
          ctx = Puck.Context.new()
          {:ok, _, ctx} = Puck.call(client, "Tell me about cats", ctx)
          {:ok, _, ctx} = Puck.call(client, "What do they eat?", ctx)
          {:ok, _, ctx} = Puck.call(client, "How long do they live?", ctx)
          {:ok, resp, _ctx} = Puck.call(client, "Summarize what we discussed", ctx)
          resp.content
        end)

      # 4 user calls + summarizer calls from compaction
      assert trajectory.total_steps >= 4
      assert trajectory.total_tokens > 0
    end

    @tag timeout: 180_000
    test "trajectory tokens include summarization overhead", %{client: client} do
      {_output, trajectory} =
        Eval.collect(fn ->
          ctx = Puck.Context.new()

          ctx =
            Enum.reduce(1..4, ctx, fn i, ctx ->
              {:ok, _, ctx} = Puck.call(client, "Message number #{i}", ctx)
              ctx
            end)

          {:ok, _, _ctx} = Puck.call(client, "Done", ctx)
          :done
        end)

      # 5 user calls + summarizer calls from compaction
      assert trajectory.total_steps >= 5
      assert trajectory.total_tokens > 0
    end
  end

  describe "BAML eval" do
    @describetag :baml

    setup do
      client_registry = %{
        "clients" => [
          %{
            "name" => "AnthropicHaiku",
            "provider" => "anthropic",
            "options" => %{"model" => "claude-haiku-4-5-20251001"}
          }
        ],
        "primary" => "AnthropicHaiku",
        "Ollama" => "AnthropicHaiku"
      }

      client =
        Puck.Client.new(
          {Puck.Backends.Baml,
           function: "ChooseTool", path: "test/support/baml_src", client_registry: client_registry}
        )

      [client: client, client_registry: client_registry]
    end

    @tag timeout: 120_000
    test "captures trajectory from BAML agent", %{client: client} do
      crm_find = fn name ->
        "Found: #{name}, email: #{String.downcase(name) |> String.replace(" ", ".")}@example.com"
      end

      {output, trajectory} =
        Eval.collect(fn ->
          loop(client, "Find Jane Doe's email", Puck.Context.new(), crm_find)
        end)

      assert is_binary(output)
      assert trajectory.total_steps >= 1

      result =
        Eval.grade(output, trajectory, [
          Graders.output_produced(Done),
          Graders.max_steps(5)
        ])

      assert result.passed?, "Grader failures: #{inspect(Eval.Result.failures(result))}"
    end

    @tag timeout: 120_000
    test "captures trajectory from streaming response", %{client_registry: client_registry} do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml,
           function: "Summarize", path: "test/support/baml_src", client_registry: client_registry}
        )

      {output, trajectory} =
        Eval.collect(fn ->
          {:ok, stream, _ctx} =
            Puck.stream(client, "The quick brown fox jumps over the lazy dog.")

          Enum.map_join(stream, "", & &1.content)
        end)

      assert is_binary(output)
      assert String.length(output) > 0
      assert trajectory.total_steps == 1

      [step] = trajectory.steps
      assert step.metadata[:streamed] == true
      assert step.output == output
    end
  end

  describe "BAML eval + compaction (dogfood)" do
    @describetag :baml

    setup do
      client_registry = %{
        "clients" => [
          %{
            "name" => "AnthropicHaiku",
            "provider" => "anthropic",
            "options" => %{"model" => "claude-haiku-4-5-20251001"}
          }
        ],
        "primary" => "AnthropicHaiku",
        "Ollama" => "AnthropicHaiku",
        "PuckClient" => "AnthropicHaiku"
      }

      client =
        Puck.Client.new(
          {Puck.Backends.Baml,
           function: "Classify", path: "test/support/baml_src", client_registry: client_registry},
          auto_compaction: {:summarize, max_tokens: 100, keep_last: 2}
        )

      [client: client]
    end

    @tag timeout: 300_000
    test "captures trajectory with BAML compaction", %{client: client} do
      {_output, trajectory} =
        Eval.collect(fn ->
          ctx = Puck.Context.new()
          {:ok, _, ctx} = Puck.call(client, "I love this product!", ctx)
          {:ok, _, ctx} = Puck.call(client, "This is terrible.", ctx)
          {:ok, resp, _ctx} = Puck.call(client, "It's okay I guess.", ctx)
          resp.content
        end)

      # 3 user calls + summarizer calls from compaction
      assert trajectory.total_steps >= 3
      assert trajectory.total_tokens > 0
    end
  end

  defp loop(client, input, ctx, crm_find) do
    {:ok, %{content: action}, ctx} = Puck.call(client, input, ctx, output_schema: schema())

    case action do
      %Done{message: msg} ->
        msg

      %LookupContact{name: name} ->
        result = crm_find.(name)
        loop(client, result, ctx, crm_find)
    end
  end
end
