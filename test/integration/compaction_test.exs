defmodule Puck.Integration.CompactionTest do
  @moduledoc """
  Integration tests for context compaction with LLM judge verification.
  """

  use Puck.IntegrationCase

  defmodule JudgeResult do
    defstruct [:passed, :reason]
  end

  @judge_schema Zoi.struct(
                  JudgeResult,
                  %{
                    passed:
                      Zoi.boolean(
                        description: "Whether the compaction preserved context correctly"
                      ),
                    reason: Zoi.string(description: "Brief explanation of the verdict")
                  },
                  coerce: true
                )

  describe "ReqLLM sliding_window auto-compaction" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          system_prompt: "You are a helpful assistant. Keep responses brief.",
          auto_compaction: {:sliding_window, window_size: 4}
        )

      [client: client]
    end

    @tag timeout: 120_000
    test "compacts context when messages exceed window size", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, _, ctx} = Puck.call(client, "What is 2+2?", ctx)
      original_after_first = Puck.Context.messages(ctx)

      {:ok, _, ctx} = Puck.call(client, "What is 3+3?", ctx)
      {:ok, _, ctx} = Puck.call(client, "What is 4+4?", ctx)

      original_messages = original_after_first ++ Puck.Context.messages(ctx)

      assert Puck.Context.message_count(ctx) <= 4

      judge_result =
        judge_compaction(
          original_messages,
          ctx,
          """
          For sliding window compaction (which DROPS old messages, does NOT summarize):
          - The most recent 2-4 messages should be preserved
          - It is EXPECTED and CORRECT that older messages are completely removed
          - The remaining messages should be coherent on their own
          - Pass if the most recent exchanges are present, even if earlier context is lost
          """
        )

      assert judge_result.passed, "Judge failed: #{judge_result.reason}"
    end
  end

  describe "ReqLLM summarize auto-compaction" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          system_prompt: "You are a helpful assistant. Keep responses brief.",
          auto_compaction: {:summarize, max_tokens: 500, keep_last: 2}
        )

      [client: client]
    end

    @tag timeout: 180_000
    test "summarizes context when tokens exceed threshold", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, _, ctx} = Puck.call(client, "Tell me a short story about a cat named Whiskers.", ctx)
      {:ok, _, ctx} = Puck.call(client, "What adventures did Whiskers have?", ctx)
      original_messages = Puck.Context.messages(ctx)

      {:ok, _, ctx} = Puck.call(client, "How does the story end?", ctx)

      messages = Puck.Context.messages(ctx)
      assert length(messages) <= 5

      judge_result =
        judge_compaction(
          original_messages,
          ctx,
          """
          For summarize compaction:
          - The summary should mention the cat named Whiskers
          - Key story elements should be captured
          - The most recent messages (last 2) should be preserved
          - An LLM reading this context could continue the conversation coherently
          """
        )

      assert judge_result.passed, "Judge failed: #{judge_result.reason}"
    end
  end

  describe "BAML sliding_window auto-compaction" do
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
        "primary" => "AnthropicHaiku"
      }

      client =
        Puck.Client.new(
          {Puck.Backends.Baml,
           function: "Classify", path: "test/support/baml_src", client_registry: client_registry},
          auto_compaction: {:sliding_window, window_size: 4}
        )

      [client: client]
    end

    @tag timeout: 240_000
    test "compacts context when messages exceed window size", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, _, ctx} = Puck.call(client, "I love this product!", ctx)
      original_after_first = Puck.Context.messages(ctx)

      {:ok, _, ctx} = Puck.call(client, "This is terrible.", ctx)
      {:ok, _, ctx} = Puck.call(client, "It's okay I guess.", ctx)

      original_messages = original_after_first ++ Puck.Context.messages(ctx)

      assert Puck.Context.message_count(ctx) <= 4

      judge_result =
        judge_compaction(
          original_messages,
          ctx,
          """
          For sliding window compaction (which DROPS old messages, does NOT summarize):
          - The most recent 2-4 messages should be preserved
          - It is EXPECTED and CORRECT that older messages are completely removed
          - The remaining messages should be coherent on their own
          - Pass if the most recent exchanges are present, even if earlier context is lost
          """
        )

      assert judge_result.passed, "Judge failed: #{judge_result.reason}"
    end
  end

  describe "BAML auto-compaction with built-in Summarize" do
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
    test "auto-detects BAML backend and uses built-in Summarize function", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, _, ctx} = Puck.call(client, "I love this amazing product!", ctx)
      {:ok, _, ctx} = Puck.call(client, "This product is terrible and broken.", ctx)

      {:ok, _, ctx} = Puck.call(client, "It's okay I guess.", ctx)

      messages = Puck.Context.messages(ctx)

      # Compaction should have reduced message count (was 6, now <= 5)
      assert length(messages) <= 5,
             "Expected compaction to reduce messages, got #{length(messages)}"

      # First message should be the summary (contains "Summary")
      first_message = hd(messages)
      first_content = extract_content_text(first_message.content)
      assert first_message.role == :user

      assert String.contains?(first_content, "Summary"),
             "Expected summary message, got: #{first_content}"
    end
  end

  describe "BAML manual summarize compaction" do
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
        "primary" => "AnthropicHaiku"
      }

      summarize_client =
        Puck.Client.new(
          {Puck.Backends.Baml,
           function: "Summarize", path: "test/support/baml_src", client_registry: client_registry}
        )

      client =
        Puck.Client.new(
          {Puck.Backends.Baml,
           function: "Classify", path: "test/support/baml_src", client_registry: client_registry}
        )

      [client: client, summarize_client: summarize_client]
    end

    @tag timeout: 300_000
    test "manually compacts context with summarize strategy", %{
      client: client,
      summarize_client: summarize_client
    } do
      ctx = Puck.Context.new()

      {:ok, _, ctx} = Puck.call(client, "I love this amazing product!", ctx)
      {:ok, _, ctx} = Puck.call(client, "This product is terrible and broken.", ctx)
      {:ok, _, ctx} = Puck.call(client, "It's okay I guess.", ctx)

      original_messages = Puck.Context.messages(ctx)
      assert length(original_messages) == 6

      {:ok, compacted_ctx} =
        Puck.Compaction.compact(
          ctx,
          {Puck.Compaction.Summarize,
           %{
             client: summarize_client,
             keep_last: 2
           }}
        )

      messages = Puck.Context.messages(compacted_ctx)
      assert length(messages) <= 3

      judge_result =
        judge_compaction(
          original_messages,
          compacted_ctx,
          """
          For summarize compaction (testing structure, not summary quality):
          - There should be a summary message at the start
          - The most recent 2 messages should be preserved
          - The summary should reference SOME aspect of the original conversation
          - Pass as long as compaction structure is correct (summary + recent messages)
          - Do NOT fail based on summary quality - that's the LLM's job, not the compaction logic
          """
        )

      assert judge_result.passed, "Judge failed: #{judge_result.reason}"
    end
  end

  defp judge_compaction(original_messages, compacted_context, criteria) do
    judge_client =
      Puck.Client.new(
        {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
        system_prompt:
          "You are a judge evaluating conversation compaction quality. Be strict but fair."
      )

    original_text = format_messages(original_messages)
    compacted_text = format_context(compacted_context)

    prompt = """
    ## Original Conversation
    #{original_text}

    ## After Compaction
    #{compacted_text}

    ## Evaluation Criteria
    #{criteria}

    Judge whether the compaction preserved the essential context.
    Return passed: true if the criteria are met, false otherwise.
    """

    {:ok, %{content: result}, _} =
      Puck.call(judge_client, prompt, Puck.Context.new(), output_schema: @judge_schema)

    result
  end

  defp format_messages(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      content_text = extract_content_text(msg.content)
      "#{msg.role}: #{content_text}"
    end)
  end

  defp extract_content_text(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{type: :text, text: text} -> text
      %{type: type} -> "[#{type}]"
      other -> inspect(other, limit: :infinity)
    end)
  end

  defp extract_content_text(content), do: inspect(content, limit: :infinity)

  defp format_context(context) do
    context
    |> Puck.Context.messages()
    |> format_messages()
  end
end
