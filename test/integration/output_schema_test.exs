defmodule Puck.OutputSchemaTest do
  @moduledoc """
  Integration tests for structured output parsing with Zoi schemas.
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

  setup :check_ollama_available!

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

  describe "BAML backend" do
    @describetag :baml

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml, function: "ChooseTool", path: "test/support/baml_src"}
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "parses union schema to user-defined structs", %{client: client} do
      {:ok, response, _ctx} =
        Puck.call(client, "Find Jane Doe in the CRM", Puck.Context.new(), output_schema: schema())

      assert response.content != nil
      assert response.metadata.provider == "baml"
      assert response.metadata.function == "ChooseTool"

      assert %LookupContact{} = response.content
      assert response.content.type == "lookup_contact"
      assert is_binary(response.content.name)
      assert response.content.name =~ ~r/jane|doe/i
    end
  end
end
