if Code.ensure_loaded?(ReqLLM) do
  defmodule Puck.Backends.ReqLLM do
    @moduledoc """
    Backend implementation using the ReqLLM library.

    ReqLLM provides a unified interface to multiple LLM providers.

    ## Model Specification

    The model must include the provider in `"provider:model"` format:

        model: "anthropic:claude-sonnet-4-5"

    ## Configuration

    Backend options are passed in the client tuple and forwarded to ReqLLM:

    - `:temperature` - Sampling temperature (0.0 to 2.0)
    - `:max_tokens` - Maximum tokens in response
    - `:top_p` - Nucleus sampling parameter
    - `:stop` - Stop sequences

    ## Examples

        # Basic usage
        client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

        # With options
        client = Puck.Client.new(
          {Puck.Backends.ReqLLM, model: "anthropic:claude-sonnet-4-5", temperature: 0.7}
        )

    See ReqLLM documentation for supported providers and additional options.
    """

    @behaviour Puck.Backend

    alias Puck.Content.Part
    alias Puck.{Message, Response}
    alias ReqLLM.Message.ContentPart

    @impl true
    def call(config, messages, opts) do
      model = Map.fetch!(config, :model)
      output_schema = Keyword.get(opts, :output_schema)
      backend_opts = Keyword.get(opts, :backend_opts, [])
      options = build_options(config, backend_opts)
      req_messages = Enum.map(messages, &to_req_llm_message/1)

      if output_schema do
        call_with_schema(model, req_messages, output_schema, options)
      else
        call_text(model, req_messages, options)
      end
    end

    defp call_text(model, req_messages, options) do
      case ReqLLM.generate_text(model, req_messages, options) do
        {:ok, response} -> {:ok, normalize_response(response, model)}
        {:error, reason} -> {:error, reason}
      end
    end

    defp call_with_schema(model, messages, output_schema, options) do
      # Convert struct schemas to object schemas for LLM (struct schemas can't be JSON encoded)
      llm_schema = to_llm_schema(output_schema)

      case ReqLLM.generate_object(model, messages, llm_schema, options) do
        {:ok, response} -> {:ok, normalize_object_response(response, model, output_schema)}
        {:error, reason} -> {:error, reason}
      end
    end

    defp to_llm_schema(%Zoi.Types.Struct{fields: fields}), do: Zoi.object(fields)
    defp to_llm_schema(schema), do: schema

    @impl true
    def stream(config, messages, opts) do
      model = Map.fetch!(config, :model)
      backend_opts = Keyword.get(opts, :backend_opts, [])
      options = build_options(config, backend_opts)
      req_messages = Enum.map(messages, &to_req_llm_message/1)

      case ReqLLM.stream_text(model, req_messages, options) do
        {:ok, stream_response} ->
          text_stream =
            stream_response
            |> ReqLLM.StreamResponse.tokens()
            |> Stream.map(fn text ->
              %{content: text, metadata: %{backend: :req_llm}}
            end)

          {:ok, text_stream}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def introspect(config) do
      model = Map.get(config, :model, "unknown")
      {provider, _model_name} = parse_model_string(model)

      %{
        provider: provider,
        model: model,
        operation: :chat,
        capabilities: [:streaming, :multi_provider]
      }
    end

    # Private helpers

    defp build_options(config, backend_opts) do
      config
      |> Map.drop([:model])
      |> Map.to_list()
      |> Keyword.merge(backend_opts)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    end

    defp normalize_response(response, model) do
      content = ReqLLM.Response.text(response)
      tool_calls = extract_tool_calls(response)
      usage = ReqLLM.Response.usage(response) || %{}
      finish_reason = ReqLLM.Response.finish_reason(response)

      Response.new(
        content: content,
        tool_calls: tool_calls,
        finish_reason: normalize_finish_reason(finish_reason),
        usage: normalize_usage(usage),
        metadata: build_metadata(response, model, finish_reason)
      )
    end

    defp normalize_object_response(response, model, output_schema) do
      object = ReqLLM.Response.object(response)
      content = maybe_parse_struct(output_schema, object)
      usage = ReqLLM.Response.usage(response) || %{}
      finish_reason = ReqLLM.Response.finish_reason(response)

      Response.new(
        content: content,
        finish_reason: normalize_finish_reason(finish_reason),
        usage: normalize_usage(usage),
        metadata: build_metadata(response, model, finish_reason)
      )
    end

    defp maybe_parse_struct(%Zoi.Types.Struct{} = schema, object) when is_map(object) do
      case Zoi.parse(schema, object) do
        {:ok, struct} -> struct
        {:error, _} -> object
      end
    end

    defp maybe_parse_struct(_schema, object), do: object

    defp build_metadata(response, model, raw_finish_reason) do
      {provider, _model_name} = parse_model_string(model)

      %{
        provider: provider,
        model: response.model,
        response_id: response.id,
        raw_finish_reason: raw_finish_reason
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end

    defp parse_model_string(model) when is_binary(model) do
      case String.split(model, ":", parts: 2) do
        [provider, model_name] -> {provider, model_name}
        [model_name] -> {"unknown", model_name}
      end
    end

    defp extract_tool_calls(response) do
      response
      |> ReqLLM.Response.tool_calls()
      |> Enum.map(&normalize_tool_call/1)
    end

    defp normalize_tool_call(%ReqLLM.ToolCall{id: id, function: %{name: name, arguments: args}}) do
      %{
        id: id,
        name: name,
        arguments: decode_arguments(args)
      }
    end

    defp normalize_tool_call(%{id: id, name: name, arguments: args}) do
      %{
        id: id,
        name: name,
        arguments: decode_arguments(args)
      }
    end

    defp normalize_tool_call(%{name: name, arguments: args}) do
      %{
        id: nil,
        name: name,
        arguments: decode_arguments(args)
      }
    end

    defp decode_arguments(args) when is_binary(args) do
      case Jason.decode(args) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end
    end

    defp decode_arguments(args) when is_map(args), do: args
    defp decode_arguments(_), do: %{}

    defp normalize_finish_reason(:stop), do: :stop
    defp normalize_finish_reason(:length), do: :max_tokens
    defp normalize_finish_reason(:tool_calls), do: :tool_use
    defp normalize_finish_reason(:content_filter), do: :content_filter
    defp normalize_finish_reason(:error), do: :error
    defp normalize_finish_reason(nil), do: nil

    defp normalize_usage(usage) when is_map(usage) do
      %{
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0)
      }
    end

    defp normalize_usage(_), do: %{}

    # Convert Puck.Message → ReqLLM message format
    # Single text → use plain map with string content (loose map)
    # Multi-part → use ReqLLM.Message struct with ContentPart list
    defp to_req_llm_message(%Message{role: role, content: [%Part{type: :text, text: text}]}) do
      %{role: role, content: text}
    end

    defp to_req_llm_message(%Message{role: role, content: parts}) do
      content_parts = Enum.map(parts, &to_req_llm_part/1)
      %ReqLLM.Message{role: role, content: content_parts}
    end

    defp to_req_llm_part(%Part{type: :text, text: text}) do
      ContentPart.text(text)
    end

    defp to_req_llm_part(%Part{type: :image_url, url: url}) do
      ContentPart.image_url(url)
    end

    defp to_req_llm_part(%Part{type: :image, data: data, media_type: media_type}) do
      ContentPart.image(data, media_type)
    end

    defp to_req_llm_part(%Part{
           type: :file,
           data: data,
           filename: filename,
           media_type: media_type
         }) do
      ContentPart.file(data, filename, media_type)
    end

    defp to_req_llm_part(%Part{type: type} = part) do
      # Fallback for other types (audio, video, custom) - pass as map
      part |> Map.from_struct() |> Map.delete(:metadata) |> Map.put(:type, type)
    end
  end
end
