defmodule Puck.Compaction.Summarize do
  @moduledoc """
  LLM-based summarization compaction strategy.

  This strategy uses an LLM to summarize older conversation history while
  preserving the most recent messages verbatim. Similar to Claude Code's
  `/compact` command.

  ## Configuration

  - `:client` (required) - `Puck.Client` to use for summarization calls
  - `:keep_last` - Number of recent messages to preserve verbatim (default: 3)
  - `:prompt` - Custom summarization prompt (optional)
  - `:max_tokens` (required for auto-compaction) - Token threshold; `should_compact?/2` returns
    `false` unless this is set

  ## How It Works

  1. Splits messages: older messages to summarize vs last K messages to keep
  2. Formats older messages as a conversation transcript
  3. Calls the LLM with a summarization prompt
  4. Returns new context: `[summary_message] ++ last_k_messages`

  ## Example

      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

      {:ok, compacted} = Puck.Compaction.compact(context, {Puck.Compaction.Summarize, %{
        client: client,
        keep_last: 3
      }})

  """

  @behaviour Puck.Compaction

  alias Puck.{Context, Message}

  @default_keep_last 3

  @default_prompt """
  Summarize the conversation so far, preserving:
  - What was accomplished
  - Current work in progress
  - Files involved and their status
  - Next steps / actions needed
  - Key user requests, constraints, preferences

  Be concise but comprehensive. This summary will replace the conversation history.

  <conversation>
  <%= conversation %>
  </conversation>
  """

  @impl true
  def compact(%Context{} = context, config) when is_map(config) do
    client = Map.fetch!(config, :client)
    keep_last = Map.get(config, :keep_last, @default_keep_last)

    messages = Context.messages(context)
    message_count = length(messages)

    cond do
      message_count == 0 ->
        {:ok, context}

      message_count <= keep_last ->
        {:ok, context}

      true ->
        do_compact(context, client, keep_last, config)
    end
  end

  defp do_compact(context, client, keep_last, config) do
    messages = Context.messages(context)
    {to_summarize, to_keep} = Enum.split(messages, length(messages) - keep_last)

    conversation_text = format_conversation(to_summarize)
    prompt = build_prompt(conversation_text, config)

    case Puck.call(client, prompt) do
      {:ok, response, _summary_context} ->
        summary_text = response.content
        new_context = build_compacted_context(context, summary_text, to_keep)
        {:ok, new_context}

      {:error, reason} ->
        {:error, {:summarization_failed, reason}}
    end
  end

  defp format_conversation(messages) do
    Enum.map_join(messages, "\n\n", &format_message/1)
  end

  defp format_message(%Message{role: role, content: parts}) do
    content_text =
      parts
      |> Enum.map(&extract_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    role_label = role |> to_string() |> String.capitalize()
    "#{role_label}: #{content_text}"
  end

  defp extract_text(%{type: :text, text: text}), do: text
  defp extract_text(%{type: :image}), do: "[image]"
  defp extract_text(%{type: :image_url}), do: "[image]"
  defp extract_text(%{type: :file, filename: filename}), do: "[file: #{filename}]"
  defp extract_text(_), do: nil

  defp build_prompt(conversation_text, config) do
    custom_prompt = Map.get(config, :prompt)

    if custom_prompt do
      String.replace(custom_prompt, "<%= conversation %>", conversation_text)
    else
      String.replace(@default_prompt, "<%= conversation %>", conversation_text)
    end
  end

  defp build_compacted_context(original_context, summary_text, kept_messages) do
    summary_message = Message.new(:user, "[Conversation Summary]\n\n#{summary_text}")

    new_context =
      original_context
      |> Context.clear()
      |> Map.put(:messages, [summary_message | kept_messages])
      |> Context.put_metadata(:compacted_at, DateTime.utc_now())
      |> Context.put_metadata(:compaction_strategy, __MODULE__)

    new_context
  end

  @impl true
  def should_compact?(%Context{} = context, config) when is_map(config) do
    case Map.get(config, :max_tokens) do
      nil ->
        false

      max_tokens ->
        total_tokens = Context.get_metadata(context, :total_tokens, 0)
        total_tokens >= max_tokens
    end
  end

  @impl true
  def introspect(_config) do
    %{
      strategy: "summarize",
      description: "LLM-based conversation summarization"
    }
  end
end
