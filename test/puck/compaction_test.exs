defmodule Puck.CompactionTest do
  use ExUnit.Case, async: true

  alias Puck.{Compaction, Context}

  defmodule TestStrategy do
    @behaviour Puck.Compaction

    @impl true
    def compact(context, config) do
      keep_last = Map.get(config, :keep_last, 1)
      messages = Context.messages(context)

      if length(messages) <= keep_last do
        {:ok, context}
      else
        kept = Enum.take(messages, -keep_last)
        new_context = %{context | messages: kept}
        {:ok, new_context}
      end
    end

    @impl true
    def should_compact?(context, config) do
      threshold = Map.get(config, :threshold, 5)
      Context.message_count(context) > threshold
    end

    @impl true
    def introspect(_config) do
      %{strategy: "test"}
    end
  end

  defmodule MinimalStrategy do
    @behaviour Puck.Compaction

    @impl true
    def compact(context, _config) do
      {:ok, Context.clear(context)}
    end
  end

  describe "compact/2" do
    test "delegates to strategy module" do
      context =
        Context.new()
        |> Context.add_message(:user, "First")
        |> Context.add_message(:assistant, "Second")
        |> Context.add_message(:user, "Third")

      {:ok, compacted} = Compaction.compact(context, {TestStrategy, %{keep_last: 1}})

      assert Context.message_count(compacted) == 1
      assert Context.last_message(compacted).content == [Puck.Content.text("Third")]
    end

    test "works with minimal strategy implementation" do
      context =
        Context.new()
        |> Context.add_message(:user, "Hello")

      {:ok, compacted} = Compaction.compact(context, {MinimalStrategy, %{}})

      assert Context.message_count(compacted) == 0
    end
  end

  describe "should_compact?/2" do
    test "delegates to strategy when implemented" do
      context =
        Context.new()
        |> Context.add_message(:user, "1")
        |> Context.add_message(:assistant, "2")
        |> Context.add_message(:user, "3")

      refute Compaction.should_compact?(context, {TestStrategy, %{threshold: 5}})
      assert Compaction.should_compact?(context, {TestStrategy, %{threshold: 2}})
    end

    test "returns true when strategy doesn't implement should_compact?" do
      context = Context.new()

      assert Compaction.should_compact?(context, {MinimalStrategy, %{}})
    end
  end
end
