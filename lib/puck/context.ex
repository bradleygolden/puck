defmodule Puck.Context do
  @moduledoc """
  Conversation context with message history and metadata.

  ## Example

      context = Puck.Context.new()
      context = Puck.Context.add_message(context, :user, "Hello!")

  """

  alias Puck.Content.Part
  alias Puck.Message

  @type t :: %__MODULE__{
          messages: [Message.t()],
          metadata: map()
        }

  defstruct messages: [], metadata: %{}

  @doc """
  Creates a new empty context.

  ## Examples

      iex> Puck.Context.new()
      %Puck.Context{messages: [], metadata: %{}}

      iex> Puck.Context.new(metadata: %{session_id: "abc123"})
      %Puck.Context{messages: [], metadata: %{session_id: "abc123"}}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      messages: Keyword.get(opts, :messages, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Adds a message to the context.

  Content can be a string (wrapped automatically), a single Part, or a list of Parts.

  ## Examples

      iex> context = Puck.Context.new()
      iex> context = Puck.Context.add_message(context, :user, "Hello!")
      iex> length(context.messages)
      1

  """
  @spec add_message(t(), Message.role(), String.t() | Part.t() | [Part.t()], map()) :: t()
  def add_message(%__MODULE__{} = context, role, content, metadata \\ %{}) do
    message = Message.new(role, content, metadata)
    %{context | messages: context.messages ++ [message]}
  end

  @doc """
  Returns the messages in the context.

  ## Examples

      iex> context = Puck.Context.new()
      iex> context = Puck.Context.add_message(context, :user, "Hello!")
      iex> length(Puck.Context.messages(context))
      1

  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{messages: messages}), do: messages

  @doc """
  Returns the last message in the context, or nil if empty.

  ## Examples

      iex> context = Puck.Context.new()
      iex> Puck.Context.last_message(context)
      nil

  """
  @spec last_message(t()) :: Message.t() | nil
  def last_message(%__MODULE__{messages: []}), do: nil
  def last_message(%__MODULE__{messages: messages}), do: List.last(messages)

  @doc """
  Returns the number of messages in the context.

  ## Examples

      iex> context = Puck.Context.new()
      iex> Puck.Context.message_count(context)
      0

  """
  @spec message_count(t()) :: non_neg_integer()
  def message_count(%__MODULE__{messages: messages}), do: length(messages)

  @doc """
  Updates the context metadata.

  ## Examples

      iex> context = Puck.Context.new()
      iex> context = Puck.Context.put_metadata(context, :session_id, "abc123")
      iex> context.metadata
      %{session_id: "abc123"}

  """
  @spec put_metadata(t(), atom(), term()) :: t()
  def put_metadata(%__MODULE__{} = context, key, value) do
    %{context | metadata: Map.put(context.metadata, key, value)}
  end

  @doc """
  Gets a value from the context metadata.

  ## Examples

      iex> context = Puck.Context.new(metadata: %{session_id: "abc123"})
      iex> Puck.Context.get_metadata(context, :session_id)
      "abc123"

      iex> Puck.Context.get_metadata(context, :missing)
      nil

  """
  @spec get_metadata(t(), atom(), term()) :: term()
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Clears all messages from the context, preserving metadata.

  Useful for starting a fresh conversation while keeping session information.

  ## Examples

      iex> context = Puck.Context.new(metadata: %{session_id: "abc123"})
      iex> context = Puck.Context.add_message(context, :user, "Hello!")
      iex> context = Puck.Context.clear(context)
      iex> {context.messages, context.metadata}
      {[], %{session_id: "abc123"}}

  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = context) do
    %{context | messages: []}
  end
end
