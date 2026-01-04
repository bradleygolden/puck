defmodule Puck.Integration.FewShotTest do
  @moduledoc """
  Integration tests for few-shot prompting.
  """

  use Puck.IntegrationCase

  setup :check_ollama_available!

  describe "BAML few-shot prompting" do
    @describetag :baml

    setup do
      client =
        Puck.Client.new({Puck.Backends.Baml, function: "Classify", path: "test/support/baml_src"})

      [client: client]
    end

    @tag timeout: 120_000
    test "few-shot examples via context improve responses", %{client: client} do
      ctx =
        Puck.Context.new()
        |> Puck.Context.add_message(:user, "I love this!")
        |> Puck.Context.add_message(:assistant, "positive")
        |> Puck.Context.add_message(:user, "This is terrible.")
        |> Puck.Context.add_message(:assistant, "negative")
        |> Puck.Context.add_message(:user, "It's okay.")
        |> Puck.Context.add_message(:assistant, "neutral")

      {:ok, response, _ctx} = Puck.call(client, "I absolutely adore it!", ctx)

      assert is_binary(response.content)
      assert response.content =~ ~r/positive/i
    end

    @tag timeout: 60_000
    test "works with message list input", %{client: client} do
      messages = [
        %{role: :user, content: "Amazing product!"},
        %{role: :assistant, content: "positive"},
        %{role: :user, content: "Worst experience ever."}
      ]

      ctx =
        Enum.reduce(messages, Puck.Context.new(), fn msg, acc ->
          Puck.Context.add_message(acc, msg.role, msg.content)
        end)

      {:ok, response, _ctx} = Puck.call(client, "How would you classify this?", ctx)

      assert is_binary(response.content)
    end
  end
end
