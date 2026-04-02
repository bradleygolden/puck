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
    - `:args_format` - How to build args: `:auto`, `:messages`, `:messages_multimodal`, `:text`, or `:raw`
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

    ## Telemetry

    When a call or stream returns an error, this backend emits a
    `[:puck, :backend, :baml, :error]` event. See `Puck.Telemetry` for details.
    """

    @behaviour Puck.Backend

    alias Puck.Backends.Baml.TypeBuilder
    alias Puck.Content.Part
    alias Puck.{Message, Response}
    alias Puck.Runtime.Telemetry, as: T

    @impl true
    def call(config, messages, opts) do
      function_name = Map.fetch!(config, :function)
      args = build_args(messages, config)
      output_schema = Keyword.get(opts, :output_schema)
      backend_opts = Keyword.get(opts, :backend_opts, [])
      client_module = client_module(config)
      collector_module = collector_module(config)

      collector = collector_module.new("puck-#{System.unique_integer([:positive])}")

      baml_opts = build_baml_opts(config, output_schema, backend_opts)
      baml_opts = Map.update(baml_opts, :collectors, [collector], &[collector | &1])

      case client_module.call(function_name, args, baml_opts) do
        {:ok, result} ->
          usage = extract_collector_usage(collector_module, collector)
          {:ok, build_response(result, config, output_schema, usage)}

        {:error, reason} ->
          T.event([:backend, :baml, :error], %{}, %{
            function: function_name,
            reason: reason,
            raw_llm_response: extract_raw_response(collector_module, collector)
          })

          {:error, reason}
      end
    end

    @impl true
    def stream(config, messages, opts) do
      function_name = Map.fetch!(config, :function)
      args = build_args(messages, config)
      output_schema = Keyword.get(opts, :output_schema)
      backend_opts = Keyword.get(opts, :backend_opts, [])
      client_module = client_module(config)
      collector_module = collector_module(config)

      collector = collector_module.new("puck-stream-#{System.unique_integer([:positive])}")

      baml_opts = build_baml_opts(config, output_schema, backend_opts)
      baml_opts = Map.update(baml_opts, :collectors, [collector], &[collector | &1])

      caller = self()
      ref = make_ref()

      stream =
        Stream.resource(
          fn -> start_stream(caller, ref, function_name, args, baml_opts, client_module) end,
          fn state ->
            receive_chunks(
              state,
              ref,
              output_schema,
              collector,
              collector_module,
              function_name
            )
          end,
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

        :messages_multimodal ->
          %{messages: format_messages_multimodal(messages)}

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

    defp format_messages_multimodal(messages) do
      Enum.map(messages, fn %Message{role: role, content: content} ->
        %{
          role: to_string(role),
          content: format_content_parts(content)
        }
      end)
    end

    defp format_content_parts(parts) when is_list(parts) do
      Enum.map(parts, &format_content_part/1)
    end

    defp format_content_part(%Part{type: :text, text: text}), do: text

    defp format_content_part(%Part{type: :image_url, url: url, media_type: nil}),
      do: %{url: url}

    defp format_content_part(%Part{type: :image_url, url: url, media_type: media_type}),
      do: %{url: url, media_type: media_type}

    defp format_content_part(%Part{type: :image, data: data, media_type: media_type})
         when is_binary(data) do
      %{base64: Base.encode64(data), media_type: media_type || "image/png"}
    end

    defp format_content_part(%Part{type: :audio, data: data, media_type: media_type})
         when is_binary(data) do
      %{base64: Base.encode64(data), media_type: media_type || "audio/wav"}
    end

    defp format_content_part(%Part{type: :video, data: data, media_type: media_type})
         when is_binary(data) do
      %{base64: Base.encode64(data), media_type: media_type || "video/mp4"}
    end

    defp format_content_part(%Part{type: :file, data: data, media_type: media_type})
         when is_binary(data) do
      %{base64: Base.encode64(data), media_type: media_type || "application/octet-stream"}
    end

    defp format_content_part(%Part{type: type}) do
      raise ArgumentError, "unsupported content part type for BAML backend: #{inspect(type)}"
    end

    @internal_keys [:function, :args_format, :args, :client_module, :collector_module]

    defp build_baml_opts(config, output_schema, backend_opts) do
      opts =
        config
        |> Map.drop(@internal_keys)
        |> Map.to_list()
        |> Keyword.merge(backend_opts)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      if output_schema do
        dynamic_classes = Map.get(opts, :dynamic_classes, %{})
        schema_descriptions = Map.get(opts, :schema_descriptions, %{})

        type_builder = build_type_builder(output_schema, dynamic_classes, schema_descriptions)

        opts
        |> Map.delete(:dynamic_classes)
        |> Map.delete(:schema_descriptions)
        |> Map.put(:parse, false)
        |> maybe_put_type_builder(type_builder)
      else
        opts
      end
    end

    defp maybe_put_type_builder(opts, []), do: opts
    defp maybe_put_type_builder(opts, type_builder), do: Map.put(opts, :tb, type_builder)

    defp build_type_builder(output_schema, dynamic_classes, schema_descriptions)
         when map_size(dynamic_classes) == 0 do
      TypeBuilder.from_schema(output_schema, descriptions: schema_descriptions)
    end

    defp build_type_builder(
           %Zoi.Types.Union{} = union_schema,
           dynamic_classes,
           schema_descriptions
         ) do
      TypeBuilder.from_dynamic_union(union_schema, dynamic_classes, schema_descriptions)
    end

    defp build_type_builder(output_schema, _dynamic_classes, schema_descriptions) do
      TypeBuilder.from_schema(output_schema, descriptions: schema_descriptions)
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

    @doc false
    def extract_raw_response(nil), do: nil

    def extract_raw_response(collector), do: extract_raw_response(BamlElixir.Collector, collector)

    defp extract_raw_response(_collector_module, nil), do: nil

    defp extract_raw_response(collector_module, collector) do
      case collector_module.last_function_log(collector) do
        %{"raw_llm_response" => raw} -> raw
        _ -> nil
      end
    end

    defp extract_collector_usage(collector_module, collector) do
      collector_usage =
        case collector_module.usage(collector) do
          %{} = usage -> usage
          _ -> %{}
        end

      log_usage = extract_function_log_usage(collector_module, collector)

      collector_usage
      |> merge_usage(log_usage)
      |> normalize_collector_usage()
    end

    defp normalize_collector_usage(usage) when is_map(usage) do
      input_tokens = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0
      output_tokens = Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0

      usage
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) or is_binary(key) ->
          Map.put(acc, key, value)

        {key, value}, acc ->
          Map.put(acc, to_string(key), value)
      end)
      |> Map.put(:input_tokens, input_tokens)
      |> Map.put(:output_tokens, output_tokens)
    end

    defp extract_function_log_usage(collector_module, collector) do
      collector
      |> collector_module.last_function_log()
      |> extract_last_call_usage()
    end

    defp extract_last_call_usage(log) when is_map(log) do
      case map_get(log, "calls") do
        calls when is_list(calls) ->
          calls
          |> List.last()
          |> extract_call_usage()

        _ ->
          %{}
      end
    end

    defp extract_last_call_usage(_), do: %{}

    @cache_read_usage_paths [
      ["cache_read_input_tokens"],
      ["cache_read_tokens"],
      ["cached_tokens"],
      ["prompt_tokens_details", "cached_tokens"],
      ["input_token_details", "cached_tokens"],
      ["cache", "read_input_tokens"],
      ["cache", "read_tokens"]
    ]

    @cache_creation_usage_paths [
      ["cache_creation_input_tokens"],
      ["cache_write_input_tokens"],
      ["cache_creation_tokens"],
      ["prompt_tokens_details", "cache_creation_tokens"],
      ["input_token_details", "cache_creation_tokens"],
      ["cache", "creation_input_tokens"],
      ["cache", "write_input_tokens"]
    ]

    defp extract_call_usage(call) when is_map(call) do
      call_usage =
        case map_get(call, "usage") do
          %{} = usage -> usage
          _ -> %{}
        end

      response_usage = extract_response_body_usage(call)
      usage = merge_usage(call_usage, response_usage)
      add_canonical_usage_fields(usage)
    end

    defp extract_call_usage(_), do: %{}

    defp extract_response_body_usage(call) do
      case map_get(call, "response") do
        %{} = response ->
          merge_usage(
            extract_usage_from_map(response),
            response |> map_get("body") |> extract_usage_from_body()
          )

        _ ->
          %{}
      end
    end

    defp extract_usage_from_map(map) when is_map(map) do
      case map_get(map, "usage") do
        %{} = usage -> usage
        _ -> %{}
      end
    end

    defp extract_usage_from_body(body) when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded_body} -> extract_usage_from_map(decoded_body)
        _ -> %{}
      end
    end

    defp extract_usage_from_body(%{} = decoded_body), do: extract_usage_from_map(decoded_body)
    defp extract_usage_from_body(_), do: %{}

    defp add_canonical_usage_fields(usage) when is_map(usage) do
      usage
      |> put_usage_if_missing(
        "cache_read_input_tokens",
        infer_usage_value(usage, @cache_read_usage_paths)
      )
      |> put_usage_if_missing(
        "cache_creation_input_tokens",
        infer_usage_value(usage, @cache_creation_usage_paths)
      )
    end

    defp merge_usage(primary, secondary) when is_map(primary) and is_map(secondary) do
      Map.merge(secondary, primary, fn _key, secondary_value, primary_value ->
        cond do
          is_map(primary_value) and is_map(secondary_value) ->
            merge_usage(primary_value, secondary_value)

          is_nil(primary_value) ->
            secondary_value

          true ->
            primary_value
        end
      end)
    end

    defp put_usage_if_missing(usage, _key, nil), do: usage

    defp put_usage_if_missing(usage, key, value) do
      if is_nil(map_get(usage, key)) do
        Map.put(usage, key, value)
      else
        usage
      end
    end

    defp infer_usage_value(usage, candidate_paths) do
      Enum.find_value(candidate_paths, fn path ->
        path
        |> map_get_path(usage)
        |> parse_integer()
      end)
    end

    defp map_get_path(path, usage) when is_list(path) do
      Enum.reduce_while(path, usage, fn key, acc ->
        case map_get(acc, key) do
          nil -> {:halt, nil}
          value -> {:cont, value}
        end
      end)
    end

    defp map_get(nil, _key), do: nil

    defp map_get(map, key) when is_map(map) and is_atom(key) do
      case Map.get(map, key) do
        nil -> Map.get(map, to_string(key))
        value -> value
      end
    end

    defp map_get(map, key) when is_map(map) and is_binary(key) do
      case Map.get(map, key) do
        nil -> map_get_by_atom_key(map, key)
        value -> value
      end
    end

    defp map_get(_map, _key), do: nil

    defp map_get_by_atom_key(map, key) do
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value, else: nil

        _ ->
          nil
      end)
    end

    defp parse_integer(value) when is_integer(value), do: value
    defp parse_integer(value) when is_float(value), do: trunc(value)

    defp parse_integer(value) when is_binary(value) do
      case Integer.parse(String.trim(value)) do
        {parsed, ""} -> parsed
        _ -> nil
      end
    end

    defp parse_integer(_), do: nil

    defp maybe_parse_schema(schema, result) when is_map(result) and not is_nil(schema) do
      normalized = normalize_nif_result(result)

      case Zoi.parse(schema, normalized) do
        {:ok, parsed} -> parsed
        {:error, _} -> normalized
      end
    end

    defp maybe_parse_schema(_schema, result), do: result

    @doc false
    def normalize_nif_result(%{__baml_enum__: _, value: v}), do: v
    def normalize_nif_result(%{"__baml_enum__" => _, "value" => v}), do: v

    def normalize_nif_result(%{__baml_class__: _} = map) do
      map
      |> Map.delete(:__baml_class__)
      |> Map.new(fn {k, v} -> {k, normalize_nif_result(v)} end)
    end

    def normalize_nif_result(%{"__baml_class__" => _} = map) do
      map
      |> Map.delete("__baml_class__")
      |> Map.new(fn {k, v} -> {k, normalize_nif_result(v)} end)
    end

    def normalize_nif_result(list) when is_list(list),
      do: Enum.map(list, &normalize_nif_result/1)

    def normalize_nif_result(other), do: other

    defp start_stream(caller, ref, function_name, args, opts, client_module) do
      client_module.stream(
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

      {:streaming, nil}
    end

    defp receive_chunks(
           :done,
           _ref,
           _output_schema,
           _collector,
           _collector_module,
           _function_name
         ) do
      {:halt, :done}
    end

    defp receive_chunks(
           {:streaming, prev_content},
           ref,
           output_schema,
           collector,
           collector_module,
           function_name
         ) do
      receive do
        {^ref, {:chunk, result}} ->
          parsed = maybe_parse_schema(output_schema, result)
          sanitized = sanitize_partial_strings(parsed)

          if sanitized == prev_content do
            {[], {:streaming, prev_content}}
          else
            chunk = %{
              type: :content,
              content: sanitized,
              metadata: %{partial: true, backend: :baml}
            }

            {[chunk], {:streaming, sanitized}}
          end

        {^ref, {:done, result}} ->
          parsed = maybe_parse_schema(output_schema, result)
          usage = extract_collector_usage(collector_module, collector)

          chunk = %{
            type: :content,
            content: parsed,
            metadata: %{partial: false, backend: :baml},
            usage: usage
          }

          {[chunk], :done}

        {^ref, {:error, reason}} ->
          T.event([:backend, :baml, :error], %{}, %{
            function: function_name,
            reason: reason,
            raw_llm_response: extract_raw_response(collector_module, collector)
          })

          raise "BAML stream error: #{inspect(reason)}"
      after
        30_000 ->
          raise "BAML stream timeout"
      end
    end

    defp sanitize_partial_strings(value) when is_binary(value) do
      strip_trailing_incomplete_escape(value)
    end

    defp sanitize_partial_strings(%_{} = struct), do: struct

    defp sanitize_partial_strings(value) when is_map(value) do
      Map.new(value, fn {k, v} -> {k, sanitize_partial_strings(v)} end)
    end

    defp sanitize_partial_strings(value) when is_list(value) do
      Enum.map(value, &sanitize_partial_strings/1)
    end

    defp sanitize_partial_strings(value), do: value

    defp strip_trailing_incomplete_escape(str) when is_binary(str) do
      if String.ends_with?(str, "\\") do
        String.slice(str, 0..-2//1)
      else
        str
      end
    end

    defp client_module(config), do: Map.get(config, :client_module, BamlElixir.Client)
    defp collector_module(config), do: Map.get(config, :collector_module, BamlElixir.Collector)
  end
end
