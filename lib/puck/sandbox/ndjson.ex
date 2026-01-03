defmodule Puck.Sandbox.NDJSON do
  @moduledoc false

  @doc """
  Transforms a stream of binary chunks into a stream of decoded JSON objects.

  Handles partial lines across chunk boundaries by buffering incomplete lines.
  """
  @spec stream(Enumerable.t()) :: Enumerable.t()
  def stream(enum) do
    enum
    |> Stream.transform("", &parse_lines/2)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
  end

  defp parse_lines(chunk, buffer) do
    data = buffer <> chunk
    lines = String.split(data, "\n")
    {complete, [partial]} = Enum.split(lines, -1)
    {complete, partial}
  end
end
