defmodule Puck.StreamingSchemaTest do
  use ExUnit.Case, async: true

  alias Puck.{Client, Context}

  defmodule Person do
    @moduledoc false
    defstruct [:name, :age]
  end

  defp person_schema do
    Zoi.struct(
      Person,
      %{
        name: Zoi.string(),
        age: Zoi.integer()
      },
      coerce: true
    )
  end

  describe "Puck.stream/4 with output_schema" do
    test "passes output_schema to backend and parses JSON chunks to structs" do
      json_chunks = [
        ~s({"name": "Alice", "age": 30}),
        ~s({"name": "Bob", "age": 25})
      ]

      client = Client.new({Puck.Backends.Mock, stream_chunks: json_chunks})
      context = Context.new()

      assert {:ok, stream, _ctx} =
               Puck.stream(client, "Get people", context, output_schema: person_schema())

      chunks = Enum.to_list(stream)

      assert length(chunks) == 2

      [first, second] = chunks
      assert %Person{name: "Alice", age: 30} = first.content
      assert %Person{name: "Bob", age: 25} = second.content
    end

    test "chunks include partial metadata" do
      json_chunks = [~s({"name": "Test", "age": 42})]
      client = Client.new({Puck.Backends.Mock, stream_chunks: json_chunks})

      {:ok, stream, _ctx} =
        Puck.stream(client, "Get person", Context.new(), output_schema: person_schema())

      [chunk] = Enum.to_list(stream)

      assert chunk.metadata.partial == true
      assert chunk.metadata.backend == :mock
    end

    test "handles map chunks directly" do
      map_chunks = [
        %{"name" => "Charlie", "age" => 35}
      ]

      client = Client.new({Puck.Backends.Mock, stream_chunks: map_chunks})

      {:ok, stream, _ctx} =
        Puck.stream(client, "Get person", Context.new(), output_schema: person_schema())

      [chunk] = Enum.to_list(stream)

      assert %Person{name: "Charlie", age: 35} = chunk.content
    end

    test "returns raw content when no schema provided" do
      chunks = ["Hello", " ", "world"]
      client = Client.new({Puck.Backends.Mock, stream_chunks: chunks})

      {:ok, stream, _ctx} = Puck.stream(client, "Say hello", Context.new())

      result = Enum.map(Enum.to_list(stream), & &1.content)
      assert result == ["Hello", " ", "world"]
    end

    test "passes through invalid JSON as-is" do
      chunks = ["not json", "also not json"]
      client = Client.new({Puck.Backends.Mock, stream_chunks: chunks})

      {:ok, stream, _ctx} =
        Puck.stream(client, "Get data", Context.new(), output_schema: person_schema())

      result = Enum.map(Enum.to_list(stream), & &1.content)
      assert result == ["not json", "also not json"]
    end

    test "returns raw map when schema parsing fails" do
      chunks = [%{"invalid" => "data"}]
      client = Client.new({Puck.Backends.Mock, stream_chunks: chunks})

      {:ok, stream, _ctx} =
        Puck.stream(client, "Get data", Context.new(), output_schema: person_schema())

      [chunk] = Enum.to_list(stream)

      assert chunk.content == %{"invalid" => "data"}
    end
  end

  describe "runtime output_schema passthrough" do
    test "stream includes output_schema in backend opts" do
      client = Client.new({Puck.Backends.Mock, stream_chunks: ["test"]})

      {:ok, _stream, ctx} =
        Puck.stream(client, "Hello", Context.new(), output_schema: person_schema())

      assert Context.message_count(ctx) == 1
    end
  end
end
