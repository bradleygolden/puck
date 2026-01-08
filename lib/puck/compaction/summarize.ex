defmodule Puck.Compaction.Summarize do
  @moduledoc """
  LLM-based summarization compaction strategy.

  This strategy uses an LLM to summarize older conversation history while
  preserving the most recent messages verbatim. Similar to Claude Code's
  `/compact` command.

  Supports both ReqLLM and BAML backends transparently:
  - **ReqLLM**: Pass a `:client` option with a `Puck.Client`
  - **BAML**: Pass a `:client_registry` option to use Puck's built-in BAML function

  ## Configuration

  Common options:
  - `:keep_last` - Number of recent messages to preserve verbatim (default: 3)
  - `:max_tokens` (required for auto-compaction) - Token threshold; `should_compact?/2`
    returns `false` unless this is set
  - `:prompt` - Custom summarization prompt (optional)

  ReqLLM-specific:
  - `:client` (required for ReqLLM) - `Puck.Client` to use for summarization calls

  BAML-specific:
  - `:client_registry` (required for BAML) - Client registry map for LLM provider configuration

  ## How It Works

  1. Splits messages: older messages to summarize vs last K messages to keep
  2. Formats older messages as a conversation transcript
  3. Calls the LLM with a summarization prompt
  4. Returns new context: `[summary_message] ++ last_k_messages`

  ## Examples

  ReqLLM:

      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

      {:ok, compacted} = Puck.Compaction.compact(context, {Puck.Compaction.Summarize, %{
        client: client,
        keep_last: 3
      }})

  BAML (auto-detected when using BAML backend with auto_compaction):

      registry = %{
        primary: "claude",
        clients: [%{
          name: "claude",
          provider: "anthropic",
          options: %{model: "claude-sonnet-4-5", api_key: System.get_env("ANTHROPIC_API_KEY")}
        }]
      }

      {:ok, compacted} = Puck.Compaction.compact(context, {Puck.Compaction.Summarize, %{
        client_registry: registry,
        keep_last: 3
      }})

  """

  @behaviour Puck.Compaction

  alias Puck.{Client, Context, Message}

  @default_keep_last 3

  @default_prompt """
  Summarize the conversation so far, preserving:
  - What was accomplished
  - Current work in progress
  - Files involved and their status
  - Next steps / actions needed
  - Key user requests, constraints, preferences

  Be concise but comprehensive. This summary will replace the conversation history.
  """

  @impl true
  def compact(%Context{} = context, config) when is_map(config) do
    keep_last = Map.get(config, :keep_last, @default_keep_last)

    messages = Context.messages(context)
    message_count = length(messages)

    cond do
      message_count == 0 ->
        {:ok, context}

      message_count <= keep_last ->
        {:ok, context}

      true ->
        do_compact(context, keep_last, config)
    end
  end

  defp do_compact(context, keep_last, config) do
    messages = Context.messages(context)
    {to_summarize, to_keep} = Enum.split(messages, length(messages) - keep_last)
    conversation_text = format_conversation(to_summarize)

    case detect_backend(config) do
      :baml -> compact_with_baml(context, conversation_text, to_keep, config)
      :req_llm -> compact_with_req_llm(context, conversation_text, to_keep, config)
    end
  end

  defp detect_backend(%{client_registry: _}), do: :baml
  defp detect_backend(%{client: _}), do: :req_llm
  defp detect_backend(_), do: :req_llm

  defp compact_with_baml(context, conversation_text, to_keep, config) do
    if Code.ensure_loaded?(Puck.Backends.Baml) do
      client_registry = Map.get(config, :client_registry)
      prompt = Map.get(config, :prompt) || @default_prompt

      baml_path = Application.app_dir(:puck, "priv/baml_src")
      args = %{text: conversation_text, instructions: prompt}

      baml_config =
        [function: "PuckSummarize", path: baml_path, args_format: :raw, args: args]
        |> maybe_add_client_registry(client_registry)

      client = Client.new({Puck.Backends.Baml, baml_config})

      case Puck.call(client, "summarize", Context.new()) do
        {:ok, response, _ctx} ->
          new_context = build_compacted_context(context, response.content, to_keep)
          {:ok, new_context}

        {:error, reason} ->
          {:error, {:summarization_failed, reason}}
      end
    else
      {:error, {:summarization_failed, :baml_not_available}}
    end
  end

  defp maybe_add_client_registry(config, nil), do: config

  defp maybe_add_client_registry(config, registry),
    do: Keyword.put(config, :client_registry, registry)

  defp compact_with_req_llm(context, conversation_text, to_keep, config) do
    client = Map.fetch!(config, :client)
    instructions = Map.get(config, :prompt, @default_prompt)
    prompt = build_req_llm_prompt(instructions, conversation_text)

    case Puck.call(client, prompt) do
      {:ok, response, _summary_context} ->
        summary_text = response.content
        new_context = build_compacted_context(context, summary_text, to_keep)
        {:ok, new_context}

      {:error, reason} ->
        {:error, {:summarization_failed, reason}}
    end
  end

  defp build_req_llm_prompt(instructions, conversation_text) do
    """
    #{instructions}

    <conversation>
    #{conversation_text}
    </conversation>
    """
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

  defp build_compacted_context(original_context, summary_text, kept_messages) do
    summary_message = Message.new(:user, "[Conversation Summary]\n\n#{summary_text}")

    original_context
    |> Context.clear()
    |> Map.put(:messages, [summary_message | kept_messages])
    |> Context.put_metadata(:compacted_at, DateTime.utc_now())
    |> Context.put_metadata(:compaction_strategy, __MODULE__)
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
  def introspect(config) do
    backend = detect_backend(config)

    %{
      strategy: "summarize",
      backend: backend,
      description: "LLM-based conversation summarization"
    }
  end
end
