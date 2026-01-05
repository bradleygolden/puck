defmodule Puck.Integration.StreamingSchemaTest do
  @moduledoc """
  Integration tests for streaming structured output with schemas.
  """

  use Puck.IntegrationCase

  defmodule Person do
    @moduledoc false
    defstruct [:name, :age, :occupation]
  end

  defp person_schema do
    Zoi.struct(
      Person,
      %{
        name: Zoi.string(description: "Person's full name"),
        age: Zoi.integer(description: "Person's age"),
        occupation: Zoi.string(description: "Person's job or occupation")
      },
      coerce: true
    )
  end

  describe "ReqLLM streaming with schema" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          system_prompt: """
          You are a helpful assistant that extracts person information.
          Extract the name, age, and occupation from the user's message.
          """
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "streams partial structured objects", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "John Smith is a 35 year old software engineer.",
          Puck.Context.new(),
          output_schema: person_schema()
        )

      chunks = Enum.to_list(stream)

      assert chunks != []

      Enum.each(chunks, fn chunk ->
        assert chunk.type == :content or chunk.type == :thinking
        assert chunk.metadata.backend == :req_llm
      end)

      content_chunks = Enum.filter(chunks, &(&1.type == :content))
      assert content_chunks != []

      Enum.each(content_chunks, fn chunk ->
        assert chunk.metadata.partial == true
      end)
    end

    @tag timeout: 60_000
    test "final chunk contains complete struct", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "Alice Johnson is a 28 year old doctor.",
          Puck.Context.new(),
          output_schema: person_schema()
        )

      chunks = Enum.to_list(stream)
      content_chunks = Enum.filter(chunks, &(&1.type == :content))

      assert content_chunks != []

      final_chunk = List.last(content_chunks)

      assert %Person{} = final_chunk.content
      assert is_binary(final_chunk.content.name)
      assert is_integer(final_chunk.content.age)
      assert is_binary(final_chunk.content.occupation)
    end
  end

  describe "BAML streaming with schema" do
    @describetag :baml

    setup :check_ollama_available!

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml, function: "ExtractPerson", path: "test/support/baml_src"}
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "streams partial structured objects", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "Bob Williams is a 42 year old teacher.",
          Puck.Context.new(),
          output_schema: person_schema()
        )

      chunks = Enum.to_list(stream)

      assert chunks != []

      Enum.each(chunks, fn chunk ->
        assert chunk.type == :content
        assert chunk.metadata.backend == :baml
      end)
    end

    @tag timeout: 60_000
    test "partial chunks have partial flag", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "Carol Davis is a 31 year old nurse.",
          Puck.Context.new(),
          output_schema: person_schema()
        )

      chunks = Enum.to_list(stream)

      non_final_chunks = Enum.slice(chunks, 0..-2//1)
      final_chunk = List.last(chunks)

      Enum.each(non_final_chunks, fn chunk ->
        assert chunk.metadata.partial == true
      end)

      assert final_chunk.metadata.partial == false
    end

    @tag timeout: 60_000
    test "final chunk parses to struct with schema", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "David Lee is a 55 year old chef.",
          Puck.Context.new(),
          output_schema: person_schema()
        )

      chunks = Enum.to_list(stream)
      final_chunk = List.last(chunks)

      assert %Person{} = final_chunk.content
      assert is_binary(final_chunk.content.name)
      assert is_integer(final_chunk.content.age)
      assert is_binary(final_chunk.content.occupation)
    end
  end
end
