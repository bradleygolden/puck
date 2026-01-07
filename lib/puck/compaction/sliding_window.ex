defmodule Puck.Compaction.SlidingWindow do
  @moduledoc """
  Sliding window compaction strategy.

  This strategy keeps the most recent N messages, discarding older ones.
  Simple and predictable, but loses conversation history.

  ## Configuration

  - `:window_size` - Number of messages to keep (default: 20)

  ## Example

      {:ok, compacted} = Puck.Compaction.compact(context, {Puck.Compaction.SlidingWindow, %{
        window_size: 30
      }})

  """

  @behaviour Puck.Compaction

  alias Puck.Context

  @default_window_size 20

  @impl true
  def compact(%Context{} = context, config) when is_map(config) do
    window_size = Map.get(config, :window_size, @default_window_size)
    messages = Context.messages(context)

    if length(messages) <= window_size do
      {:ok, context}
    else
      kept = Enum.take(messages, -window_size)
      {:ok, %{context | messages: kept}}
    end
  end

  @impl true
  def should_compact?(%Context{} = context, config) when is_map(config) do
    window_size = Map.get(config, :window_size, @default_window_size)
    Context.message_count(context) > window_size
  end

  @impl true
  def introspect(_config) do
    %{
      strategy: "sliding_window",
      description: "Keeps last N messages"
    }
  end
end
