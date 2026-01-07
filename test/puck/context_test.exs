defmodule Puck.ContextTest do
  use ExUnit.Case, async: true

  alias Puck.{Content, Context, Message}
  alias Puck.Content.Part

  describe "new/1" do
    test "creates an empty context" do
      context = Context.new()

      assert context.messages == []
      assert context.metadata == %{}
    end

    test "creates a context with metadata" do
      context = Context.new(metadata: %{session_id: "abc123"})

      assert context.metadata == %{session_id: "abc123"}
    end

    test "creates a context with initial messages" do
      message = Message.new(:user, "Hello!")
      context = Context.new(messages: [message])

      assert length(context.messages) == 1
    end
  end

  describe "add_message/4" do
    test "adds a message to the context" do
      context =
        Context.new()
        |> Context.add_message(:user, "Hello!")

      assert length(context.messages) == 1
      assert hd(context.messages).role == :user
      assert hd(context.messages).content == [%Part{type: :text, text: "Hello!"}]
    end

    test "appends messages in order" do
      context =
        Context.new()
        |> Context.add_message(:user, "First")
        |> Context.add_message(:assistant, "Second")
        |> Context.add_message(:user, "Third")

      assert length(context.messages) == 3
      assert Enum.at(context.messages, 0).content == [Content.text("First")]
      assert Enum.at(context.messages, 1).content == [Content.text("Second")]
      assert Enum.at(context.messages, 2).content == [Content.text("Third")]
    end

    test "adds message with metadata" do
      context =
        Context.new()
        |> Context.add_message(:assistant, "Hi!", %{tokens: 5})

      message = hd(context.messages)
      assert message.metadata == %{tokens: 5}
    end

    test "adds message with Content.Part content" do
      parts = [Content.text("What's this?"), Content.image_url("https://example.com/img.png")]

      context =
        Context.new()
        |> Context.add_message(:user, parts)

      assert hd(context.messages).content == parts
    end
  end

  describe "messages/1" do
    test "returns Message structs" do
      context =
        Context.new()
        |> Context.add_message(:user, "Hello!")
        |> Context.add_message(:assistant, "Hi there!")

      messages = Context.messages(context)

      assert length(messages) == 2
      assert [%Message{role: :user}, %Message{role: :assistant}] = messages
    end

    test "returns empty list for empty context" do
      assert Context.messages(Context.new()) == []
    end
  end

  describe "last_message/1" do
    test "returns nil for empty context" do
      assert Context.last_message(Context.new()) == nil
    end

    test "returns the last message" do
      context =
        Context.new()
        |> Context.add_message(:user, "First")
        |> Context.add_message(:assistant, "Last")

      last = Context.last_message(context)
      assert last.content == [Content.text("Last")]
    end
  end

  describe "message_count/1" do
    test "returns 0 for empty context" do
      assert Context.message_count(Context.new()) == 0
    end

    test "returns correct count" do
      context =
        Context.new()
        |> Context.add_message(:user, "One")
        |> Context.add_message(:assistant, "Two")

      assert Context.message_count(context) == 2
    end
  end

  describe "metadata operations" do
    test "put_metadata/3 adds metadata" do
      context =
        Context.new()
        |> Context.put_metadata(:session_id, "abc123")

      assert context.metadata == %{session_id: "abc123"}
    end

    test "get_metadata/3 retrieves metadata" do
      context = Context.new(metadata: %{session_id: "abc123"})

      assert Context.get_metadata(context, :session_id) == "abc123"
      assert Context.get_metadata(context, :missing) == nil
      assert Context.get_metadata(context, :missing, "default") == "default"
    end
  end

  describe "compact/2" do
    test "delegates to Puck.Compaction.compact/2" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, compacted} =
        Context.compact(context, {Puck.Compaction.SlidingWindow, %{window_size: 2}})

      assert Context.message_count(compacted) == 2
    end
  end

  describe "total_tokens/1" do
    test "returns 0 when no metadata" do
      context = Context.new()

      assert Context.total_tokens(context) == 0
    end

    test "returns value from metadata" do
      context =
        Context.new()
        |> Context.put_metadata(:total_tokens, 5000)

      assert Context.total_tokens(context) == 5000
    end
  end
end
