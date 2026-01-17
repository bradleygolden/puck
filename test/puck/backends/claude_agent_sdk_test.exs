if Code.ensure_loaded?(ClaudeAgentSDK) do
  defmodule Puck.Backends.ClaudeAgentSDKTest do
    use ExUnit.Case, async: true

    alias Puck.Backends.ClaudeAgentSDK

    describe "Puck.Backends.ClaudeAgentSDK" do
      test "implements Puck.Backend behaviour" do
        Code.ensure_loaded!(ClaudeAgentSDK)

        assert function_exported?(ClaudeAgentSDK, :call, 3)
        assert function_exported?(ClaudeAgentSDK, :stream, 3)
        assert function_exported?(ClaudeAgentSDK, :introspect, 1)
      end

      test "introspect returns backend info from config" do
        config = %{model: "sonnet", allowed_tools: ["Read", "Glob"]}
        info = ClaudeAgentSDK.introspect(config)

        assert info.provider == "claude_agent_sdk"
        assert info.model == "sonnet"
        assert info.operation == :chat
        assert :streaming in info.capabilities
        assert :tools in info.capabilities
        assert :agentic in info.capabilities
      end

      test "introspect handles missing model" do
        config = %{allowed_tools: ["Read"]}
        info = ClaudeAgentSDK.introspect(config)

        assert info.provider == "claude_agent_sdk"
        assert info.model == "default"
      end

      test "introspect handles empty config" do
        info = ClaudeAgentSDK.introspect(%{})

        assert info.provider == "claude_agent_sdk"
        assert info.model == "default"
        assert info.operation == :chat
      end
    end
  end
end
