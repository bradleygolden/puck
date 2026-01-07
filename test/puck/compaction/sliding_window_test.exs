defmodule Puck.Compaction.SlidingWindowTest do
  use ExUnit.Case, async: true

  alias Puck.Compaction.SlidingWindow
  alias Puck.Context

  describe "compact/2" do
    test "returns unchanged context when empty" do
      context = Context.new()

      {:ok, compacted} = SlidingWindow.compact(context, %{window_size: 10})

      assert Context.message_count(compacted) == 0
    end

    test "returns unchanged context when messages <= window_size" do
      context =
        Context.new()
        |> Context.add_message(:user, "Hello")
        |> Context.add_message(:assistant, "Hi")

      {:ok, compacted} = SlidingWindow.compact(context, %{window_size: 5})

      assert Context.message_count(compacted) == 2
    end

    test "keeps only last N messages when exceeding window_size" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")
        |> Context.add_message(:user, "Q3")
        |> Context.add_message(:assistant, "A3")

      {:ok, compacted} = SlidingWindow.compact(context, %{window_size: 2})

      assert Context.message_count(compacted) == 2

      messages = Context.messages(compacted)
      [first, second] = messages

      assert first.role == :user
      assert hd(first.content).text == "Q3"
      assert second.role == :assistant
      assert hd(second.content).text == "A3"
    end

    test "uses default window_size of 20" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")

      {:ok, compacted} = SlidingWindow.compact(context, %{})

      assert Context.message_count(compacted) == 2
    end

    test "preserves context metadata" do
      context =
        Context.new(metadata: %{session_id: "test123"})
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, compacted} = SlidingWindow.compact(context, %{window_size: 2})

      assert Context.get_metadata(compacted, :session_id) == "test123"
    end
  end

  describe "should_compact?/2" do
    test "returns true when message count exceeds window_size" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")

      assert SlidingWindow.should_compact?(context, %{window_size: 2})
    end

    test "returns false when message count equals window_size" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")

      refute SlidingWindow.should_compact?(context, %{window_size: 2})
    end

    test "returns false when message count below window_size" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")

      refute SlidingWindow.should_compact?(context, %{window_size: 5})
    end

    test "uses default window_size of 20" do
      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")

      refute SlidingWindow.should_compact?(context, %{})
    end
  end

  describe "introspect/1" do
    test "returns strategy metadata" do
      result = SlidingWindow.introspect(%{})

      assert result.strategy == "sliding_window"
      assert is_binary(result.description)
    end
  end
end
