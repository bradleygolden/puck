defmodule Puck.Integration.MultiTurnTest do
  @moduledoc """
  Integration tests for multi-turn conversations.
  """

  use Puck.IntegrationCase

  setup :check_ollama_available!

  describe "BAML multi-turn" do
    @describetag :baml

    setup do
      client =
        Puck.Client.new({Puck.Backends.Baml, function: "Classify", path: "test/support/baml_src"})

      [client: client]
    end

    @tag timeout: 120_000
    test "maintains context across calls", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, resp1, ctx} = Puck.call(client, "I love this product!", ctx)
      assert is_binary(resp1.content)

      {:ok, resp2, ctx} = Puck.call(client, "This is terrible.", ctx)
      assert is_binary(resp2.content)

      {:ok, resp3, _ctx} = Puck.call(client, "It's okay I guess.", ctx)
      assert is_binary(resp3.content)

      assert length(ctx.messages) >= 2
    end

    @tag timeout: 60_000
    test "context tracks message history", %{client: client} do
      ctx = Puck.Context.new()

      {:ok, _resp, ctx} = Puck.call(client, "Great experience!", ctx)

      assert length(ctx.messages) == 2

      [user_msg, assistant_msg] = ctx.messages
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end
  end
end
