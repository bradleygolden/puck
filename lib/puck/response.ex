defmodule Puck.Response do
  @moduledoc """
  Normalized response struct for LLM outputs.

  ## Fields

  - `content` - Response content (text or structured data)
  - `thinking` - Thinking/reasoning content from extended thinking models (nil if not available)
  - `finish_reason` - Why the model stopped (`:stop`, `:max_tokens`, etc.)
  - `usage` - Token usage information (includes `thinking_tokens` if available)
  - `metadata` - Backend-specific data

  """

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:thinking_tokens) => non_neg_integer()
        }

  @type finish_reason ::
          :stop
          | :max_tokens
          | :content_filter
          | :error
          | atom()

  @typedoc """
  Standardized metadata keys for observability.

  These align with OpenTelemetry GenAI semantic conventions.
  """
  @type metadata :: %{
          optional(:response_id) => String.t(),
          optional(:model) => String.t(),
          optional(:provider) => String.t(),
          optional(:latency_ms) => non_neg_integer(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          content: term(),
          thinking: String.t() | nil,
          finish_reason: finish_reason() | nil,
          usage: usage(),
          metadata: metadata()
        }

  defstruct content: nil,
            thinking: nil,
            finish_reason: nil,
            usage: %{},
            metadata: %{}

  @doc """
  Creates a new response with the given attributes.

  ## Examples

      iex> Puck.Response.new(content: "Hello!")
      %Puck.Response{content: "Hello!", thinking: nil, finish_reason: nil, usage: %{}, metadata: %{}}

  """
  def new(attrs \\ []) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Returns true if this response is complete (stopped naturally).

  ## Examples

      iex> response = Puck.Response.new(finish_reason: :stop)
      iex> Puck.Response.complete?(response)
      true

      iex> response = Puck.Response.new(finish_reason: :max_tokens)
      iex> Puck.Response.complete?(response)
      false

  """
  def complete?(%__MODULE__{finish_reason: :stop}), do: true
  def complete?(%__MODULE__{finish_reason: :end_turn}), do: true
  def complete?(%__MODULE__{}), do: false

  @doc """
  Gets the total token count from usage, if available.

  ## Examples

      iex> response = Puck.Response.new(usage: %{input_tokens: 10, output_tokens: 20})
      iex> Puck.Response.total_tokens(response)
      30

      iex> response = Puck.Response.new(usage: %{total_tokens: 50})
      iex> Puck.Response.total_tokens(response)
      50

      iex> response = Puck.Response.new()
      iex> Puck.Response.total_tokens(response)
      nil

  """
  def total_tokens(%__MODULE__{usage: %{total_tokens: total}}), do: total

  def total_tokens(%__MODULE__{usage: usage}) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)

    if input == 0 and output == 0 do
      nil
    else
      input + output
    end
  end

  @doc """
  Gets the text content from the response.

  Returns the content if it's a string, or nil if content is nil or non-string.
  This is a convenience for the common case of extracting text responses.

  ## Examples

      iex> response = Puck.Response.new(content: "Hello, world!")
      iex> Puck.Response.text(response)
      "Hello, world!"

      iex> response = Puck.Response.new(content: nil)
      iex> Puck.Response.text(response)
      nil

  """
  def text(%__MODULE__{content: content}) when is_binary(content), do: content
  def text(%__MODULE__{}), do: nil

  @doc """
  Gets the thinking/reasoning content from the response.

  Returns the thinking content if available, or nil if the model doesn't support
  extended thinking or thinking was not enabled.

  ## Examples

      iex> response = Puck.Response.new(thinking: "Let me think about this...")
      iex> Puck.Response.thinking(response)
      "Let me think about this..."

      iex> response = Puck.Response.new(content: "Hello!")
      iex> Puck.Response.thinking(response)
      nil

  """
  def thinking(%__MODULE__{thinking: thinking}) when is_binary(thinking), do: thinking
  def thinking(%__MODULE__{}), do: nil
end
