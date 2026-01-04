defmodule Puck.Integration.StreamingTest do
  @moduledoc """
  Integration tests for streaming responses.
  """

  use Puck.IntegrationCase

  describe "BAML streaming" do
    @describetag :baml

    setup :check_ollama_available!

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml, function: "Summarize", path: "test/support/baml_src"}
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "streams chunks", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(client, "Elixir is a dynamic, functional language.", Puck.Context.new())

      chunks = Enum.to_list(stream)

      assert chunks != []

      Enum.each(chunks, fn chunk ->
        assert Map.has_key?(chunk, :content)
      end)

      last_chunk = List.last(chunks)
      assert last_chunk.metadata.partial == false
    end

    @tag timeout: 60_000
    test "can collect streamed content", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(client, "LiveView enables real-time web apps.", Puck.Context.new())

      chunks = Enum.to_list(stream)
      final_chunk = List.last(chunks)

      assert is_binary(final_chunk.content)
      assert final_chunk.content != ""
    end
  end

  describe "ReqLLM streaming" do
    @describetag :req_llm

    setup do
      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"})
      [client: client]
    end

    @tag timeout: 60_000
    test "streams chunks", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "Summarize in one sentence: Elixir is a dynamic, functional language.",
          Puck.Context.new()
        )

      chunks = Enum.to_list(stream)

      assert chunks != []

      Enum.each(chunks, fn chunk ->
        assert Map.has_key?(chunk, :content)
      end)
    end

    @tag timeout: 60_000
    test "can collect streamed content", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "Summarize in one sentence: LiveView enables real-time web apps.",
          Puck.Context.new()
        )

      chunks = Enum.to_list(stream)
      full_content = Enum.map_join(chunks, "", & &1.content)

      assert is_binary(full_content)
      assert full_content != ""
    end
  end
end
