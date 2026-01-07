defprotocol Puck.Content.Wrappable do
  @moduledoc """
  Protocol for converting content to `Puck.Content.Part` structs.

  Built-in implementations:
  - Strings become text parts
  - Maps/structs are JSON-encoded
  - Parts pass through unchanged

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
