if Code.ensure_loaded?(ReqLLM) do
  defmodule Puck.Backends.ReqLLMTest do
    use ExUnit.Case, async: true

    alias Puck.Backends.ReqLLM

    describe "Puck.Backends.ReqLLM" do
      test "implements Puck.Backend behaviour" do
        Code.ensure_loaded!(ReqLLM)

        assert function_exported?(ReqLLM, :call, 3)
        assert function_exported?(ReqLLM, :stream, 3)
        assert function_exported?(ReqLLM, :introspect, 1)
      end

      test "introspect returns backend info from config" do
        config = %{model: "anthropic:claude-sonnet-4-5"}
        info = ReqLLM.introspect(config)

        assert info.provider == "anthropic"
        assert info.model == "anthropic:claude-sonnet-4-5"
        assert info.operation == :chat
        assert :streaming in info.capabilities
        assert :multi_provider in info.capabilities
      end

      test "introspect handles missing model" do
        info = ReqLLM.introspect(%{})

        assert info.provider == "unknown"
        assert info.model == "unknown"
      end
    end
  end
end
