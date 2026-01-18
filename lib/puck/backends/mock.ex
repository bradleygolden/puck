defmodule Puck.Backends.Mock do
  @moduledoc """
  Mock backend for testing.

  Supports two modes: static (single response) and queue-based (multiple sequential responses).

  ## Static Mode Options

  - `:response` - Response content (default: "Mock response")
  - `:stream_chunks` - List of chunks for streaming
  - `:error` - Return this error instead of response
  - `:finish_reason` - Finish reason (default: `:stop`)
  - `:delay` - Delay in milliseconds
  - `:model` - Model name for introspection (default: "mock")

  ## Queue Mode Options

  - `:queue_pid` - PID of an Agent holding a list of responses (enables queue mode)
  - `:default` - Response when queue is exhausted (default: `{:error, :mock_responses_exhausted}`)
  - `:finish_reason` - Finish reason (default: `:stop`)
  - `:delay` - Delay in milliseconds
  - `:model` - Model name for introspection (default: "mock")

  ## Response Types (Queue Mode)

  In queue mode, each response can be:
  - Any term (returned as response content)
  - `{:error, reason}` (simulates LLM error)
  - `fn messages -> response end` (dynamic, receives conversation history)

  ## Examples

      # Static mode
      client = Puck.Client.new({Puck.Backends.Mock, response: "Hello!"})
      client = Puck.Client.new({Puck.Backends.Mock, error: :rate_limited})

      # Queue mode (prefer using Puck.Test.mock_client/2)
      {:ok, queue} = Agent.start_link(fn -> ["First", "Second", "Third"] end)
      client = Puck.Client.new({Puck.Backends.Mock, queue_pid: queue})

  See `Puck.Test.mock_client/2` for the preferred way to create queue-based mock clients.
  """

  @behaviour Puck.Backend

  alias Puck.Response

  @impl true
  def call(config, messages, opts) do
    maybe_delay(config)

    case get_response(config, messages) do
      {:error, _} = error ->
        error

      response ->
        output_schema = Keyword.get(opts, :output_schema)
        {:ok, build_response(response, config, output_schema)}
    end
  end

  @impl true
  def stream(config, messages, opts) do
    maybe_delay(config)

    case get_stream_chunks(config, messages) do
      {:error, _} = error ->
        error

      chunks ->
        output_schema = Keyword.get(opts, :output_schema)

        stream =
          Stream.map(chunks, fn chunk ->
            content = maybe_parse_chunk(chunk, output_schema)
            %{type: :content, content: content, metadata: %{partial: true, backend: :mock}}
          end)

        {:ok, stream}
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

  # Queue mode (when queue_pid is present)
  defp get_response(%{queue_pid: queue_pid} = config, messages) do
    response = pop_response(queue_pid, config)
    resolve_response(response, messages)
  end

  # Static mode (legacy behavior)
  defp get_response(config, _messages) do
    case Map.get(config, :error) do
      nil -> Map.get(config, :response, "Mock response")
      error -> {:error, error}
    end
  end

  defp pop_response(queue_pid, config) do
    default = Map.get(config, :default, {:error, :mock_responses_exhausted})

    Agent.get_and_update(queue_pid, fn
      [next | rest] -> {next, rest}
      [] -> {default, []}
    end)
  end

  # Function receives messages, returns response (Req.stub-style)
  defp resolve_response(fun, messages) when is_function(fun, 1) do
    fun.(messages)
  end

  defp resolve_response(response, _messages), do: response

  defp build_response(raw_content, config, output_schema) do
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

  defp get_stream_chunks(%{queue_pid: _} = config, messages) do
    case get_response(config, messages) do
      {:error, _} = error -> error
      response -> [response]
    end
  end

  defp get_stream_chunks(config, _messages) do
    case Map.get(config, :error) do
      nil ->
        case Map.get(config, :stream_chunks) do
          nil ->
            content = Map.get(config, :response, "Mock response")
            String.split(content, " ", trim: true)

          chunks when is_list(chunks) ->
            chunks
        end

      error ->
        {:error, error}
    end
  end

  defp maybe_delay(config) do
    case Map.get(config, :delay) do
      nil -> :ok
      delay when is_integer(delay) -> Process.sleep(delay)
    end
  end
end
