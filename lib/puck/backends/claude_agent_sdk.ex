if Code.ensure_loaded?(ClaudeAgentSDK) do
  defmodule Puck.Backends.ClaudeAgentSDK do
    @moduledoc """
    Backend implementation using the Claude Agent SDK.

    This backend uses the Claude Code CLI (via the Elixir SDK) to run prompts.
    It supports your existing Claude subscription (Pro/Max) when authenticated
    via `claude login`.

    ## Authentication

    The backend uses your Claude subscription. Make sure you're logged in:

        # In your terminal
        claude login

    If `ANTHROPIC_API_KEY` is set, it will use API credits instead.

    ## Configuration

    Backend options are passed in the client tuple:

    - `:cwd` - Working directory for file operations (defaults to current directory)
    - `:allowed_tools` - List of tools Claude can use (e.g., `["Read", "Glob", "Grep"]`)
    - `:disallowed_tools` - List of tools to disable
    - `:permission_mode` - Permission handling (`:default`, `:accept_edits`, `:bypass_permissions`)
    - `:max_turns` - Maximum conversation turns
    - `:model` - Model to use (e.g., `"sonnet"`, `"opus"`)
    - `:output_format` - Response format (`:text`, `:json`, or schema map)
    - `:sandbox` - Sandbox settings map with `:enabled`, `:root`, `:allowed_paths`, etc.

    ## Examples

        # Basic usage - read-only agent
        client = Puck.Client.new(
          {Puck.Backends.ClaudeAgentSDK, %{
            allowed_tools: ["Read", "Glob", "Grep"],
            permission_mode: :bypass_permissions
          }}
        )

        {:ok, response, _ctx} = Puck.call(client, "What files are in this directory?")

        # Code editing agent
        client = Puck.Client.new(
          {Puck.Backends.ClaudeAgentSDK, %{
            allowed_tools: ["Read", "Edit", "Write", "Glob", "Grep", "Bash"],
            permission_mode: :accept_edits,
            cwd: "/path/to/project"
          }}
        )

        {:ok, response, _ctx} = Puck.call(client, "Fix the bug in auth.py")

    ## Notes

    - The Claude Agent SDK is an agentic system - it may make multiple tool calls
      before returning a final result
    - For structured outputs, use the `:output_schema` option with a Zoi schema
    - Streaming returns intermediate messages as Claude works

    See the [claude_agent_sdk documentation](https://hexdocs.pm/claude_agent_sdk) for more details.
    """

    @behaviour Puck.Backend

    alias Puck.{Message, Response}

    @impl true
    def call(config, messages, opts) do
      output_schema = Keyword.get(opts, :output_schema)
      prompt = extract_user_prompt(messages)
      {sdk_opts, schema_wrapped?} = build_sdk_options(config, messages, output_schema)

      {content, _session_id, result_data} =
        ClaudeAgentSDK.query(prompt, sdk_opts)
        |> Enum.reduce({nil, nil, %{}}, &accumulate_message/2)

      {:ok, build_response(content, result_data, config, output_schema, schema_wrapped?)}
    end

    @impl true
    def stream(config, messages, opts) do
      output_schema = Keyword.get(opts, :output_schema)
      prompt = extract_user_prompt(messages)
      {sdk_opts, _schema_wrapped?} = build_sdk_options(config, messages, output_schema)

      stream =
        ClaudeAgentSDK.query(prompt, sdk_opts)
        |> Stream.flat_map(&to_chunk/1)

      {:ok, stream}
    end

    @impl true
    def introspect(config) do
      %{
        provider: "claude_agent_sdk",
        model: Map.get(config, :model, "default"),
        operation: :chat,
        capabilities: [:streaming, :tools, :agentic]
      }
    end

    defp extract_user_prompt(messages) do
      messages
      |> Enum.filter(&(&1.role == :user))
      |> List.last()
      |> case do
        nil -> ""
        %Message{content: content} -> extract_text(content)
      end
    end

    defp extract_system_prompt(messages) do
      messages
      |> Enum.find(&(&1.role == :system))
      |> case do
        nil -> nil
        %Message{content: content} -> extract_text(content)
      end
    end

    defp extract_text(parts) when is_list(parts) do
      parts
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("\n", & &1.text)
    end

    defp build_sdk_options(config, messages, output_schema) do
      opts = %ClaudeAgentSDK.Options{
        cwd: config[:cwd],
        allowed_tools: config[:allowed_tools],
        disallowed_tools: config[:disallowed_tools],
        permission_mode: config[:permission_mode],
        max_turns: config[:max_turns],
        verbose: config[:verbose] || false,
        include_partial_messages: true,
        sandbox: config[:sandbox]
      }

      {opts, schema_wrapped?} =
        case output_schema do
          nil ->
            {opts, false}

          schema ->
            {json_schema, wrapped?} = zoi_to_json_schema(schema)
            {%{opts | output_format: {:json_schema, json_schema}}, wrapped?}
        end

      system_prompt =
        case {extract_system_prompt(messages), output_schema} do
          {nil, nil} -> nil
          {nil, _schema} -> "Respond with JSON only."
          {prompt, nil} -> prompt
          {prompt, _schema} -> prompt <> "\n\nRespond with JSON only."
        end

      opts = if system_prompt, do: %{opts | system_prompt: system_prompt}, else: opts

      {opts, schema_wrapped?}
    end

    # The Anthropic API doesn't support anyOf/oneOf/allOf at the top level.
    # We wrap them in a "result" property and unwrap the response later.
    defp zoi_to_json_schema(schema) do
      json_schema =
        schema
        |> to_llm_schema()
        |> Zoi.JSONSchema.encode()
        |> Jason.encode!()
        |> Jason.decode!()
        |> strip_unsupported_fields()

      if has_top_level_combinator?(json_schema) do
        {wrap_in_result(json_schema), true}
      else
        {json_schema, false}
      end
    end

    defp has_top_level_combinator?(schema) when is_map(schema) do
      Map.has_key?(schema, "anyOf") or Map.has_key?(schema, "oneOf") or
        Map.has_key?(schema, "allOf")
    end

    defp has_top_level_combinator?(_), do: false

    defp wrap_in_result(schema) do
      %{"type" => "object", "properties" => %{"result" => schema}, "required" => ["result"]}
    end

    defp strip_unsupported_fields(schema) when is_map(schema) do
      schema
      |> Map.drop(["$schema", "additionalProperties"])
      |> Map.new(fn {k, v} -> {k, strip_unsupported_fields(v)} end)
    end

    defp strip_unsupported_fields(list) when is_list(list) do
      Enum.map(list, &strip_unsupported_fields/1)
    end

    defp strip_unsupported_fields(value), do: value

    defp to_llm_schema(%Zoi.Types.Struct{fields: fields}), do: Zoi.object(fields, strict: true)

    defp to_llm_schema(%Zoi.Types.Union{schemas: schemas} = union) do
      %{union | schemas: Enum.map(schemas, &to_llm_schema/1)}
    end

    defp to_llm_schema(schema), do: schema

    defp accumulate_message(
           %ClaudeAgentSDK.Message{type: :result, data: data},
           {_, session_id, _}
         ) do
      content = get_in_any(data, [:structured_output, :result])
      {content, session_id, data}
    end

    defp accumulate_message(
           %ClaudeAgentSDK.Message{type: :assistant, data: data},
           {content, session_id, result_data}
         ) do
      session = get_in_any(data, [:session_id]) || session_id
      new_content = get_message_content(data) || content
      {new_content, session, result_data}
    end

    defp accumulate_message(
           %ClaudeAgentSDK.Message{type: :system, data: data},
           {content, _, result_data}
         ) do
      session = get_in_any(data, [:session_id])
      {content, session, result_data}
    end

    defp accumulate_message(_message, acc), do: acc

    defp get_in_any(data, keys) do
      Enum.find_value(keys, fn key ->
        Map.get(data, key) || Map.get(data, to_string(key))
      end)
    end

    defp get_message_content(data) do
      message = get_in_any(data, [:message]) || %{}
      content = get_in_any(message, [:content]) || []

      content
      |> List.wrap()
      |> Enum.find_value(fn
        %{type: "text", text: text} -> text
        %{"type" => "text", "text" => text} -> text
        _ -> nil
      end)
    end

    defp to_chunk(%ClaudeAgentSDK.Message{type: :assistant, data: data}) do
      case get_message_content(data) do
        nil -> []
        text -> [%{type: :content, content: text, metadata: %{backend: :claude_agent_sdk}}]
      end
    end

    defp to_chunk(%ClaudeAgentSDK.Message{type: :result, data: data}) do
      case get_in_any(data, [:result]) do
        nil ->
          []

        result ->
          [
            %{
              type: :content,
              content: result,
              metadata: %{backend: :claude_agent_sdk, final: true}
            }
          ]
      end
    end

    defp to_chunk(%ClaudeAgentSDK.Message{type: :stream_event, data: data}) do
      case data do
        %{event: %{type: "content_block_delta", delta: %{text: text}}} when is_binary(text) ->
          [
            %{
              type: :content,
              content: text,
              metadata: %{backend: :claude_agent_sdk, partial: true}
            }
          ]

        _ ->
          []
      end
    end

    defp to_chunk(_message), do: []

    defp build_response(content, result_data, config, output_schema, schema_wrapped?) do
      content = maybe_unwrap(content, schema_wrapped?)
      content = maybe_parse_schema(output_schema, content)

      Response.new(
        content: content,
        thinking: nil,
        finish_reason: determine_finish_reason(result_data),
        usage: extract_usage(result_data),
        metadata: %{
          provider: "claude_agent_sdk",
          model: config[:model] || "default",
          backend: :claude_agent_sdk,
          session_id: get_in_any(result_data, [:session_id]),
          num_turns: get_in_any(result_data, [:num_turns]),
          duration_ms: get_in_any(result_data, [:duration_ms]),
          total_cost_usd: get_in_any(result_data, [:total_cost_usd])
        }
      )
    end

    defp maybe_unwrap(content, true) when is_map(content) do
      get_in_any(content, [:result]) || content
    end

    defp maybe_unwrap(content, _), do: content

    defp extract_usage(result_data) do
      usage = get_in_any(result_data, [:usage]) || %{}

      %{
        input_tokens: get_in_any(usage, [:input_tokens]) || 0,
        output_tokens: get_in_any(usage, [:output_tokens]) || 0
      }
    end

    defp determine_finish_reason(result_data) do
      case get_in_any(result_data, [:subtype]) do
        subtype when subtype in [:success, "success"] -> :stop
        subtype when subtype in [:error_max_turns, "error_max_turns"] -> :max_tokens
        _ -> :stop
      end
    end

    defp maybe_parse_schema(nil, content), do: content

    defp maybe_parse_schema(schema, content) when is_map(content) do
      case Zoi.parse(schema, content) do
        {:ok, parsed} -> parsed
        _ -> content
      end
    end

    defp maybe_parse_schema(schema, content) when is_binary(content) do
      json_string = extract_json_from_response(content)

      with {:ok, json} <- Jason.decode(json_string),
           {:ok, parsed} <- Zoi.parse(schema, json) do
        parsed
      else
        _ -> content
      end
    end

    defp maybe_parse_schema(_schema, content), do: content

    defp extract_json_from_response(content) do
      case Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/, content) do
        [_, json] -> String.trim(json)
        _ -> String.trim(content)
      end
    end
  end
end
