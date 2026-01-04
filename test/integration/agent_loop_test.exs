defmodule Puck.AgentLoopTest do
  @moduledoc """
  Integration tests for the agent loop pattern with discriminated unions.
  """

  use Puck.IntegrationCase

  defmodule LookupContact do
    @moduledoc false
    defstruct type: "lookup_contact", name: nil
  end

  defmodule Done do
    @moduledoc false
    defstruct type: "done", message: nil
  end

  defp schema do
    Zoi.union([
      Zoi.struct(
        LookupContact,
        %{
          type: Zoi.literal("lookup_contact"),
          name: Zoi.string(description: "Name of the contact to look up")
        },
        coerce: true
      ),
      Zoi.struct(
        Done,
        %{
          type: Zoi.literal("done"),
          message: Zoi.string(description: "Final response message")
        },
        coerce: true
      )
    ])
  end

  describe "BAML agent loop" do
    @describetag :baml

    setup :check_ollama_available!

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml, function: "ChooseTool", path: "test/support/baml_src"}
        )

      [client: client]
    end

    @tag timeout: 120_000
    test "agent loop pattern works end-to-end", %{client: client} do
      crm_find = fn name ->
        "Found contact: #{name}, email: #{String.downcase(name) |> String.replace(" ", ".")}@example.com"
      end

      loop = fn loop_fn, input, ctx ->
        {:ok, %{content: action}, ctx} = Puck.call(client, input, ctx, output_schema: schema())

        case action do
          %Done{message: msg} ->
            {:ok, msg}

          %LookupContact{name: name} ->
            result = crm_find.(name)
            loop_fn.(loop_fn, result, ctx)
        end
      end

      {:ok, result} = loop.(loop, "Find John Smith and tell me their email", Puck.Context.new())

      assert is_binary(result)
      assert result =~ ~r/john|smith|email/i
    end
  end

  describe "ReqLLM agent loop" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          system_prompt: """
          You are a CRM assistant. Given a user request:
          - If they want to find a contact, use lookup_contact with the person's name.
          - If you have found the information they need, use done with a summary message.
          """
        )

      [client: client]
    end

    @tag timeout: 120_000
    test "agent loop pattern works end-to-end", %{client: client} do
      crm_find = fn name ->
        "Found contact: #{name}, email: #{String.downcase(name) |> String.replace(" ", ".")}@example.com"
      end

      loop = fn loop_fn, input, ctx ->
        {:ok, %{content: action}, ctx} = Puck.call(client, input, ctx, output_schema: schema())

        case action do
          %Done{message: msg} ->
            {:ok, msg}

          %LookupContact{name: name} ->
            result = crm_find.(name)
            loop_fn.(loop_fn, result, ctx)
        end
      end

      {:ok, result} = loop.(loop, "Find John Smith and tell me their email", Puck.Context.new())

      assert is_binary(result)
      assert result =~ ~r/john|smith|email/i
    end
  end
end
