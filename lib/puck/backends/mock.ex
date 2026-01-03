defmodule Puck.Backends.Mock do
  @moduledoc """
  Mock backend for testing.

  ## Options

  - `:response` - Response text (default: "Mock response")
  - `:stream_chunks` - List of chunks for streaming
  - `:error` - Return this error instead of response
  - `:finish_reason` - Finish reason (default: `:stop`)
  - `:tool_calls` - Tool calls to include
  - `:delay` - Delay in milliseconds

  ## Example

      client = Puck.Client.new({Puck.Backends.Mock, response: "Hello!"})
      client = Puck.Client.new({Puck.Backends.Mock, error: :rate_limited})

  """

  @behaviour Puck.Backend

  alias Puck.Response

  @impl true
  def call(config, _messages, _opts) do
    maybe_delay(config)

    case Map.get(config, :error) do
      nil -> {:ok, build_response(config)}
      error -> {:error, error}
    end
  end

  @impl true
  def stream(config, _messages, _opts) do
    maybe_delay(config)

    case Map.get(config, :error) do
      nil ->
        chunks = get_stream_chunks(config)

        stream =
          Stream.map(chunks, fn chunk ->
            %{content: chunk, metadata: %{}}
          end)

        {:ok, stream}

      error ->
        {:error, error}
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

  defp build_response(config) do
    content = get_response_content(config)

    Response.new(
      content: content,
      finish_reason: Map.get(config, :finish_reason, :stop),
      tool_calls: Map.get(config, :tool_calls, []),
      usage: %{
        input_tokens: 10,
        output_tokens: estimate_tokens(content)
      },
      metadata: %{
        backend: :mock,
        model: Map.get(config, :model, "mock")
      }
    )
  end

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
