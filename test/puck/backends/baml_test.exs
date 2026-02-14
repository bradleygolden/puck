if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Backends.BamlTest do
    use ExUnit.Case, async: true

    alias Puck.Backends.Baml

    describe "Puck.Backends.Baml" do
      test "implements Puck.Backend behaviour" do
        Code.ensure_loaded!(Baml)

        assert function_exported?(Baml, :call, 3)
        assert function_exported?(Baml, :stream, 3)
        assert function_exported?(Baml, :introspect, 1)
      end

      test "introspect returns backend info from config" do
        config = %{function: "ExtractPerson", llm_client: "anthropic"}
        info = Baml.introspect(config)

        assert info.provider == "baml"
        assert info.model == "anthropic"
        assert info.operation == :chat
        assert info.function == "ExtractPerson"
        assert :streaming in info.capabilities
        assert :structured_output in info.capabilities
      end

      test "introspect handles missing llm_client" do
        config = %{function: "MyFunction"}
        info = Baml.introspect(config)

        assert info.provider == "baml"
        assert info.model == "default"
        assert info.function == "MyFunction"
      end

      test "introspect handles empty config" do
        info = Baml.introspect(%{})

        assert info.provider == "baml"
        assert info.model == "default"
        assert info.function == "unknown"
      end
    end
  end
end

defmodule Puck.Backends.Baml.OptsThreadingTest do
  use ExUnit.Case, async: true
  use Mimic

  alias BamlElixir.TypeBuilder, as: TB
  alias Puck.Backends.Baml
  alias Puck.Message

  describe "build_baml_opts schema_descriptions threading" do
    test "passes schema_descriptions through to TypeBuilder" do
      schema =
        Zoi.union([
          Zoi.object(%{type: Zoi.literal("search"), query: Zoi.string()}),
          Zoi.object(%{type: Zoi.literal("list_skills"), name: Zoi.string()})
        ])

      expect(BamlElixir.Client, :call, fn _function, _args, opts ->
        tb = opts.tb
        classes = Enum.filter(tb, &match?(%TB.Class{}, &1))

        list_class = Enum.find(classes, &(&1.name == "DynamicOutputListSkills"))
        type_field = Enum.find(list_class.fields, &(&1.name == "type"))
        assert type_field.description == "Lists all available skills"

        {:ok, "result"}
      end)

      config = %{function: "TestFunction"}
      messages = [Message.new(:user, "hello")]

      opts = [
        output_schema: schema,
        backend_opts: [schema_descriptions: %{"list_skills" => "Lists all available skills"}]
      ]

      {:ok, _response} = Baml.call(config, messages, opts)
    end
  end
end
