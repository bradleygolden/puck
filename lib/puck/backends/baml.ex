if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Backends.Baml do
    @moduledoc """
    Backend implementation using BAML for structured outputs.

    BAML provides type-safe structured outputs and is well-suited for building
    agentic loops. See the [BAML documentation](https://docs.boundaryml.com/)
    for details on defining functions and building agentic patterns.

    ## Configuration

    - `:function` - (required) The BAML function name to call
    - `:args` - Custom arguments map or function
    - `:args_format` - How to build args: `:auto`, `:messages`, `:text`, or `:raw`
    - `:client_registry` - Runtime client registry for LLM provider configuration
    - `:path` - Path to BAML source files (defaults to `baml_src`)

    ## Examples

        # Basic usage
        client = Puck.Client.new({Puck.Backends.Baml, function: "ExtractPerson"})
        {:ok, result, _ctx} = Puck.call(client, "John is 30 years old")

        # With custom args
        client = Puck.Client.new({Puck.Backends.Baml,
          function: "ClassifyIntent",
          args: %{categories: ["question", "statement", "command"]}
        })

    """

    @behaviour Puck.Backend

    alias Puck.{Message, Response}

    @impl true
    def call(config, messages, opts) do
      function_name = Map.fetch!(config, :function)
      args = build_args(messages, config)
      output_schema = Keyword.get(opts, :output_schema)
      backend_opts = Keyword.get(opts, :backend_opts, [])

      collector = BamlElixir.Collector.new("puck-#{System.unique_integer([:positive])}")

      baml_opts = build_baml_opts(config, output_schema, backend_opts)
      baml_opts = Map.update(baml_opts, :collectors, [collector], &[collector | &1])

      case BamlElixir.Client.call(function_name, args, baml_opts) do
        {:ok, result} ->
          usage = extract_collector_usage(collector)
          {:ok, build_response(result, config, output_schema, usage)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def stream(config, messages, opts) do
      function_name = Map.fetch!(config, :function)
      args = build_args(messages, config)
      output_schema = Keyword.get(opts, :output_schema)
      backend_opts = Keyword.get(opts, :backend_opts, [])

      collector = BamlElixir.Collector.new("puck-stream-#{System.unique_integer([:positive])}")

      baml_opts = build_baml_opts(config, output_schema, backend_opts)
      baml_opts = Map.update(baml_opts, :collectors, [collector], &[collector | &1])

      caller = self()
      ref = make_ref()

      stream =
        Stream.resource(
          fn -> start_stream(caller, ref, function_name, args, baml_opts) end,
          fn state -> receive_chunks(state, ref, output_schema) end,
          fn _state -> :ok end
        )

      {:ok, stream}
    end

    @impl true
    def introspect(config) do
      %{
        provider: "baml",
        model: Map.get(config, :llm_client, "default"),
        operation: :chat,
        function: Map.get(config, :function, "unknown"),
        capabilities: [:streaming, :structured_output]
      }
    end

    defp build_args(messages, config) do
      case Map.get(config, :args_format, :auto) do
        :auto ->
          auto_build_args(messages, config)

        :messages ->
          %{messages: format_messages(messages)}

        :text ->
          %{text: extract_last_user_text(messages)}

        :raw ->
          Map.get(config, :args, %{})
      end
    end

    defp auto_build_args(messages, config) do
      case Map.get(config, :args) do
        nil ->
          text = extract_last_user_text(messages)
          %{text: text}

        args when is_map(args) ->
          text = extract_last_user_text(messages)
          Map.put_new(args, :text, text)

        args when is_function(args, 1) ->
          args.(messages)
      end
    end

    defp extract_last_user_text(messages) do
      messages
      |> Enum.filter(&(&1.role == :user))
      |> List.last()
      |> case do
        nil -> ""
        %Message{content: content} -> extract_text_from_content(content)
      end
    end

    defp extract_text_from_content(parts) when is_list(parts) do
      parts
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("\n", & &1.text)
    end

    defp format_messages(messages) do
      Enum.map(messages, fn %Message{role: role, content: content} ->
        %{
          role: to_string(role),
          content: extract_text_from_content(content)
        }
      end)
    end

    @internal_keys [:function, :args_format, :args]

    defp build_baml_opts(config, output_schema, backend_opts) do
      opts =
        config
        |> Map.drop(@internal_keys)
        |> Map.to_list()
        |> Keyword.merge(backend_opts)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      if output_schema do
        Map.put(opts, :parse, false)
      else
        opts
      end
    end

    defp build_response(result, config, output_schema, usage) do
      content = maybe_parse_schema(output_schema, result)

      Response.new(
        content: content,
        thinking: nil,
        finish_reason: :stop,
        usage: usage,
        metadata: %{
          provider: "baml",
          function: Map.get(config, :function),
          backend: :baml
        }
      )
    end

    defp extract_collector_usage(collector) do
      case BamlElixir.Collector.usage(collector) do
        %{} = usage ->
          %{
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          }

        _ ->
          %{}
      end
    end

    defp maybe_parse_schema(schema, result) when is_map(result) and not is_nil(schema) do
      case Zoi.parse(schema, result) do
        {:ok, parsed} -> parsed
        {:error, _} -> result
      end
    end

    defp maybe_parse_schema(_schema, result), do: result

    defp start_stream(caller, ref, function_name, args, opts) do
      spawn_link(fn ->
        BamlElixir.Client.stream(
          function_name,
          args,
          fn
            {:partial, result} ->
              send(caller, {ref, {:chunk, result}})

            {:done, result} ->
              send(caller, {ref, {:done, result}})

            {:error, reason} ->
              send(caller, {ref, {:error, reason}})
          end,
          opts
        )
      end)

      :streaming
    end

    defp receive_chunks(:done, _ref, _output_schema) do
      {:halt, :done}
    end

    defp receive_chunks(:streaming, ref, output_schema) do
      receive do
        {^ref, {:chunk, result}} ->
          parsed = maybe_parse_schema(output_schema, result)
          chunk = %{type: :content, content: parsed, metadata: %{partial: true, backend: :baml}}
          {[chunk], :streaming}

        {^ref, {:done, result}} ->
          parsed = maybe_parse_schema(output_schema, result)
          chunk = %{type: :content, content: parsed, metadata: %{partial: false, backend: :baml}}
          {[chunk], :done}

        {^ref, {:error, reason}} ->
          raise "BAML stream error: #{inspect(reason)}"
      after
        30_000 ->
          raise "BAML stream timeout"
      end
    end
  end
end
