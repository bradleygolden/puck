defmodule Puck.Integration.BasicCallTest do
  @moduledoc """
  Integration tests for basic LLM calls.
  """

  use Puck.IntegrationCase

  describe "BAML basic call" do
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
    test "returns text response", %{client: client} do
      {:ok, response, _ctx} =
        Puck.call(client, "Elixir is a functional programming language.", Puck.Context.new())

      assert is_binary(response.content)
      assert response.content != ""
      assert response.finish_reason == :stop
      assert response.metadata.provider == "baml"
      assert response.metadata.function == "Summarize"
    end

    @tag timeout: 60_000
    test "works with context", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, response, ctx} =
        Puck.call(client, "Phoenix is a web framework for Elixir.", ctx)

      assert is_binary(response.content)
      assert is_struct(ctx, Puck.Context)
    end
  end

  describe "ReqLLM basic call" do
    @describetag :req_llm

    setup do
      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"})
      [client: client]
    end

    @tag timeout: 60_000
    test "returns text response", %{client: client} do
      {:ok, response, _ctx} =
        Puck.call(
          client,
          "Summarize in one sentence: Elixir is a functional programming language.",
          Puck.Context.new()
        )

      assert is_binary(response.content)
      assert response.content != ""
      assert response.finish_reason == :stop
      assert response.metadata.provider == "anthropic"
    end

    @tag timeout: 60_000
    test "works with context", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, response, ctx} =
        Puck.call(
          client,
          "Summarize in one sentence: Phoenix is a web framework for Elixir.",
          ctx
        )

      assert is_binary(response.content)
      assert is_struct(ctx, Puck.Context)
    end
  end
end
