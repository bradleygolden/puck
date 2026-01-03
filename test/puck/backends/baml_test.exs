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
