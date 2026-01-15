defmodule Puck.Backends.Mock do
  @moduledoc """
  Mock backend for testing.

  ## Options

  - `:response` - Response text (default: "Mock response")
  - `:stream_chunks` - List of chunks for streaming
  - `:error` - Return this error instead of response
  - `:finish_reason` - Finish reason (default: `:stop`)
  - `:delay` - Delay in milliseconds

  ## Example

      client = Puck.Client.new({Puck.Backends.Mock, response: "Hello!"})
      client = Puck.Client.new({Puck.Backends.Mock, error: :rate_limited})

  """

  @behaviour Puck.Backend

  alias Puck.Response

  @impl true
  def call(config, _messages, opts) do
    maybe_delay(config)

    case Map.get(config, :error) do
      nil ->
        output_schema = Keyword.get(opts, :output_schema)
        {:ok, build_response(config, output_schema)}

      error ->
        {:error, error}
    end
  end

  @impl true
  def stream(config, _messages, opts) do
    maybe_delay(config)

    case Map.get(config, :error) do
      nil ->
        output_schema = Keyword.get(opts, :output_schema)
        chunks = get_stream_chunks(config)

        stream =
          Stream.map(chunks, fn chunk ->
            content = maybe_parse_chunk(chunk, output_schema)
            %{type: :content, content: content, metadata: %{partial: true, backend: :mock}}
          end)

        {:ok, stream}

      error ->
        {:error, error}
    end
  end

  defp maybe_parse_chunk(chunk, nil), do: chunk

  defp maybe_parse_chunk(chunk, schema) when is_binary(chunk) do
    case Jason.decode(chunk) do
      {:ok, object} when is_map(object) -> parse_with_schema(object, schema)
      _ -> chunk
    end
  end

  defp maybe_parse_chunk(chunk, schema) when is_map(chunk) do
    parse_with_schema(chunk, schema)
  end

  defp maybe_parse_chunk(chunk, _schema), do: chunk

  defp parse_with_schema(object, schema) do
    case Zoi.parse(schema, object) do
      {:ok, parsed} -> parsed
      {:error, _} -> object
    end
  end

  @impl true
  def introspect(config) do
    %{
      provider: "mock",
      model: Map.get(config, :model, "mock"),
      operation: :chat,
      capabilities: [:streaming, :deterministic]
    }
  end

  # Private helpers

  defp build_response(config, output_schema) do
    raw_content = get_response_content(config)
    content = maybe_parse_content(raw_content, output_schema)

    Response.new(
      content: content,
      finish_reason: Map.get(config, :finish_reason, :stop),
      usage: %{
        input_tokens: 10,
        output_tokens: estimate_tokens(raw_content)
      },
      metadata: %{
        backend: :mock,
        model: Map.get(config, :model, "mock")
      }
    )
  end

  defp maybe_parse_content(content, nil), do: content

  defp maybe_parse_content(content, schema) when is_map(content) do
    parse_with_schema(content, schema)
  end

  defp maybe_parse_content(content, _schema), do: content

  defp estimate_tokens(nil), do: 0
  defp estimate_tokens(content) when is_binary(content), do: String.length(content)
  defp estimate_tokens(content), do: content |> inspect() |> String.length()

  defp get_response_content(config) do
    Map.get(config, :response, "Mock response")
  end

  defp get_stream_chunks(config) do
    case Map.get(config, :stream_chunks) do
      nil ->
        # Default: split response into words
        content = get_response_content(config)
        String.split(content, " ", trim: true)

      chunks when is_list(chunks) ->
        chunks
    end
  end

  defp maybe_delay(config) do
    case Map.get(config, :delay) do
      nil -> :ok
      delay when is_integer(delay) -> Process.sleep(delay)
    end
  end
end
