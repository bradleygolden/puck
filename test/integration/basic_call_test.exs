defmodule Puck.Integration.BasicCallTest do
  @moduledoc """
  Integration tests for basic LLM calls.
  """

  use Puck.IntegrationCase

  setup :check_ollama_available!

  describe "BAML basic call" do
    @describetag :baml

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
end
