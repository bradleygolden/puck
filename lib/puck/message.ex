defmodule Puck.Message do
  @moduledoc """
  A single message in a conversation.

  ## Example

      Puck.Message.new(:user, "Hello!")
      Puck.Message.new(:user, [Puck.Content.text("Hi"), Puck.Content.image_url("...")])

  """

  alias Puck.Content
  alias Puck.Content.Part

  @type role :: :system | :user | :assistant
  @type t :: %__MODULE__{
          role: role(),
          content: [Part.t()],
          metadata: map()
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content, metadata: %{}]

  @doc """
  Creates a new message.

  Content can be a string (wrapped to Content.Part), a single Part, or a list of Parts.

  ## Examples

      iex> Puck.Message.new(:user, "Hello!")
      %Puck.Message{role: :user, content: [%Puck.Content.Part{type: :text, text: "Hello!"}], metadata: %{}}

      iex> Puck.Message.new(:user, Puck.Content.text("Hi!"))
      %Puck.Message{role: :user, content: [%Puck.Content.Part{type: :text, text: "Hi!"}], metadata: %{}}

  """
  @spec new(role(), String.t() | Part.t() | [Part.t()], map()) :: t()
  def new(role, content, metadata \\ %{})
      when role in [:system, :user, :assistant] do
    %__MODULE__{
      role: role,
      content: Content.wrap(content),
      metadata: metadata
    }
  end
end
