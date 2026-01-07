defmodule Puck.Compaction.SummarizeTest do
  use ExUnit.Case, async: true

  alias Puck.Backends.Mock
  alias Puck.{Client, Context}
  alias Puck.Compaction.Summarize

  describe "compact/2" do
    test "returns unchanged context when empty" do
      client = Client.new({Mock, response: "Summary"})
      context = Context.new()

      {:ok, compacted} = Summarize.compact(context, %{client: client})

      assert Context.message_count(compacted) == 0
    end

    test "returns unchanged context when messages <= keep_last" do
      client = Client.new({Mock, response: "Summary"})

      context =
        Context.new()
        |> Context.add_message(:user, "Hello")
        |> Context.add_message(:assistant, "Hi")

      {:ok, compacted} = Summarize.compact(context, %{client: client, keep_last: 3})

      assert Context.message_count(compacted) == 2
    end

    test "summarizes older messages and keeps last K" do
      client = Client.new({Mock, response: "This is a summary of the conversation."})

      context =
        Context.new()
        |> Context.add_message(:user, "First question")
        |> Context.add_message(:assistant, "First answer")
        |> Context.add_message(:user, "Second question")
        |> Context.add_message(:assistant, "Second answer")
        |> Context.add_message(:user, "Third question")
        |> Context.add_message(:assistant, "Third answer")

      {:ok, compacted} = Summarize.compact(context, %{client: client, keep_last: 2})

      # Should have: 1 summary message + 2 kept messages = 3
      assert Context.message_count(compacted) == 3

      messages = Context.messages(compacted)
      [summary_msg | kept_messages] = messages

      assert summary_msg.role == :user
      assert hd(summary_msg.content).text =~ "Conversation Summary"
      assert hd(summary_msg.content).text =~ "This is a summary of the conversation."

      assert length(kept_messages) == 2
    end

    test "adds compaction metadata to context" do
      client = Client.new({Mock, response: "Summary"})

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, compacted} = Summarize.compact(context, %{client: client, keep_last: 1})

      assert Context.get_metadata(compacted, :compaction_strategy) == Summarize
      assert Context.get_metadata(compacted, :compacted_at) != nil
    end

    test "preserves existing context metadata" do
      client = Client.new({Mock, response: "Summary"})

      context =
        Context.new(metadata: %{session_id: "test123"})
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, compacted} = Summarize.compact(context, %{client: client, keep_last: 1})

      assert Context.get_metadata(compacted, :session_id) == "test123"
    end

    test "uses custom prompt when provided" do
      client = Client.new({Mock, response: "Custom summary result"})

      context =
        Context.new()
        |> Context.add_message(:user, "Hello")
        |> Context.add_message(:assistant, "Hi")
        |> Context.add_message(:user, "World")
        |> Context.add_message(:assistant, "!")

      custom_prompt = "Just list the topics: <%= conversation %>"

      {:ok, _compacted} =
        Summarize.compact(context, %{client: client, keep_last: 1, prompt: custom_prompt})

      # The mock doesn't actually use the prompt, but we verify no errors
    end

    test "returns error when LLM call fails" do
      client = Client.new({Mock, error: :api_error})

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:error, {:summarization_failed, :api_error}} =
        Summarize.compact(context, %{client: client, keep_last: 1})
    end
  end

  describe "should_compact?/2" do
    test "returns true when total_tokens exceeds max_tokens" do
      context =
        Context.new()
        |> Context.put_metadata(:total_tokens, 5000)
        |> Context.add_message(:user, "Q1")

      assert Summarize.should_compact?(context, %{max_tokens: 4000})
      refute Summarize.should_compact?(context, %{max_tokens: 10_000})
    end

    test "returns false when max_tokens not provided" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      refute Summarize.should_compact?(context, %{})
      refute Summarize.should_compact?(context, %{keep_last: 1})
    end
  end

  describe "introspect/1" do
    test "returns strategy metadata" do
      result = Summarize.introspect(%{})

      assert result.strategy == "summarize"
      assert is_binary(result.description)
    end
  end
end
