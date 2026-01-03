defmodule Puck.Message do
  @moduledoc """
  Represents a single message in a conversation.

  Content is always a list of Content.Part structs internally.
  Strings are automatically wrapped for convenience.

  ## Examples

      # Simple text (string wrapped automatically)
      message = Puck.Message.new(:user, "Hello!")

      # Multi-modal with explicit Content.Part
      message = Puck.Message.new(:user, [
        Puck.Content.text("What's in this image?"),
        Puck.Content.image_url("https://example.com/image.png")
      ])

      # Message with metadata
      message = Puck.Message.new(:assistant, "Hi there!", %{tokens: 5})

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
