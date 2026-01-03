defprotocol Puck.Content.Wrappable do
  @moduledoc """
  Protocol for converting content to a list of `Puck.Content.Part` structs.

  This protocol defines the boundary between arbitrary content (strings, maps,
  structs, etc.) and the Part-based representation used for LLM messages.

  ## Why a Protocol?

  Different content types need different handling when stored in context
  or sent to LLMs:

  - Strings become text parts
  - Maps/structs are JSON-encoded for LLM consumption
  - Parts pass through unchanged

  Using a protocol allows:
  1. Clear boundary definition
  2. Extensibility for custom types
  3. Idiomatic Elixir polymorphism

  ## Implementing for Custom Types

  If you have custom structs that should be stored differently:

      defimpl Puck.Content.Wrappable, for: MyApp.CustomResponse do
        def wrap(response) do
          [Puck.Content.text(MyApp.CustomResponse.to_string(response))]
        end
      end

  """

  @fallback_to_any true

  @doc """
  Converts content to a list of Content.Part structs.

  ## Examples

      iex> Puck.Content.Wrappable.wrap("Hello")
      [%Puck.Content.Part{type: :text, text: "Hello"}]

      iex> Puck.Content.Wrappable.wrap(%{result: 42})
      [%Puck.Content.Part{type: :text, text: ~s({"result":42})}]

  """
  @spec wrap(t) :: [Puck.Content.Part.t()]
  def wrap(content)
end

defimpl Puck.Content.Wrappable, for: BitString do
  def wrap(text) do
    [Puck.Content.text(text)]
  end
end

defimpl Puck.Content.Wrappable, for: Puck.Content.Part do
  def wrap(part) do
    [part]
  end
end

defimpl Puck.Content.Wrappable, for: List do
  def wrap([]), do: []

  def wrap([%Puck.Content.Part{} | _] = parts) do
    parts
  end

  def wrap(list) do
    [Puck.Content.text(Jason.encode!(list))]
  end
end

defimpl Puck.Content.Wrappable, for: Map do
  def wrap(map) do
    [Puck.Content.text(Jason.encode!(map))]
  end
end

defimpl Puck.Content.Wrappable, for: Any do
  def wrap(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__baml_class__])
    |> Jason.encode!()
    |> Puck.Content.text()
    |> List.wrap()
  end

  def wrap(other) do
    [Puck.Content.text(inspect(other))]
  end
end
