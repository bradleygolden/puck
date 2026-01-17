defmodule Puck.Integration.ClaudeAgentSDKTest do
  @moduledoc """
  Integration tests for the Claude Agent SDK backend.

  These tests require:
  1. Claude Code CLI installed: `npm install -g @anthropic-ai/claude-code`
  2. Authentication via: `claude login`

  Run with: `mix test --only claude_agent_sdk`
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

  defp sandbox_config do
    sandbox_root = Path.join(System.tmp_dir!(), "puck_test_sandbox")
    File.mkdir_p!(sandbox_root)
    %{enabled: true, root: sandbox_root, network_disabled: true}
  end

  describe "ClaudeAgentSDK basic call" do
    @describetag :claude_agent_sdk

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ClaudeAgentSDK,
           %{
             allowed_tools: ["Read", "Glob", "Grep"],
             permission_mode: :bypass_permissions,
             sandbox: sandbox_config()
           }}
        )

      [client: client]
    end

    @tag timeout: 120_000
    test "returns text response", %{client: client} do
      {:ok, response, _ctx} =
        Puck.call(client, "Say hello in exactly 3 words.", Puck.Context.new())

      assert is_binary(response.content)
      assert response.content != ""
      assert response.finish_reason == :stop
      assert response.metadata.provider == "claude_agent_sdk"
    end

    @tag timeout: 120_000
    test "works with context", %{client: client} do
      ctx = Puck.Context.new()
      {:ok, response, ctx} = Puck.call(client, "What is 2 + 2? Answer with just the number.", ctx)

      assert is_binary(response.content)
      assert is_struct(ctx, Puck.Context)
    end

    @tag timeout: 120_000
    test "can use file tools", %{client: client} do
      {:ok, response, _ctx} =
        Puck.call(
          client,
          "List the files in the current directory. Just list them briefly.",
          Puck.Context.new()
        )

      assert is_binary(response.content)
      assert response.content != ""
    end
  end

  describe "ClaudeAgentSDK streaming" do
    @describetag :claude_agent_sdk

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ClaudeAgentSDK,
           %{
             allowed_tools: ["Read", "Glob"],
             permission_mode: :bypass_permissions,
             sandbox: sandbox_config()
           }}
        )

      [client: client]
    end

    @tag timeout: 120_000
    test "streams chunks", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(client, "Count from 1 to 5, one number per line.", Puck.Context.new())

      chunks = Enum.to_list(stream)
      assert chunks != []
    end

    @tag timeout: 120_000
    test "can collect final result from stream", %{client: client} do
      {:ok, stream, _ctx} =
        Puck.stream(client, "What is the capital of France? Answer briefly.", Puck.Context.new())

      chunks = Enum.to_list(stream)
      final_chunks = Enum.filter(chunks, &(Map.get(&1.metadata, :final) == true))

      if final_chunks != [] do
        final = List.last(final_chunks)
        assert is_binary(final.content)
      end
    end
  end

  describe "ClaudeAgentSDK with custom config" do
    @describetag :claude_agent_sdk

    @tag timeout: 120_000
    test "respects max_turns limit" do
      client =
        Puck.Client.new(
          {Puck.Backends.ClaudeAgentSDK,
           %{
             allowed_tools: [],
             permission_mode: :bypass_permissions,
             max_turns: 1,
             sandbox: sandbox_config()
           }}
        )

      {:ok, response, _ctx} = Puck.call(client, "Say one word.", Puck.Context.new())
      assert is_binary(response.content)
    end

    @tag timeout: 120_000
    test "works with cwd option" do
      sandbox = sandbox_config()

      client =
        Puck.Client.new(
          {Puck.Backends.ClaudeAgentSDK,
           %{
             allowed_tools: ["Glob"],
             permission_mode: :bypass_permissions,
             cwd: sandbox.root,
             sandbox: sandbox
           }}
        )

      {:ok, response, _ctx} =
        Puck.call(
          client,
          "What directory are you working in? Answer with just the path.",
          Puck.Context.new()
        )

      assert is_binary(response.content)
    end
  end

  describe "ClaudeAgentSDK structured output" do
    @describetag :claude_agent_sdk

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ClaudeAgentSDK,
           %{
             allowed_tools: [],
             permission_mode: :bypass_permissions,
             max_turns: 3,
             sandbox: sandbox_config()
           }}
        )

      [client: client]
    end

    @tag timeout: 120_000
    test "parses struct schema", %{client: client} do
      simple_schema =
        Zoi.struct(
          LookupContact,
          %{
            type: Zoi.literal("lookup_contact"),
            name: Zoi.string(description: "Name of the contact to look up")
          },
          coerce: true
        )

      {:ok, response, _ctx} =
        Puck.call(
          client,
          "Return a lookup_contact for Jane Doe",
          Puck.Context.new(),
          output_schema: simple_schema
        )

      assert response.content != nil
      assert response.metadata.provider == "claude_agent_sdk"
      assert %LookupContact{} = response.content
      assert response.content.type == "lookup_contact"
      assert is_binary(response.content.name)
      assert response.content.name =~ ~r/jane|doe/i
    end

    @tag timeout: 120_000
    test "parses union schema", %{client: client} do
      {:ok, response, _ctx} =
        Puck.call(
          client,
          "Return a done action with message 'Task completed'",
          Puck.Context.new(),
          output_schema: schema()
        )

      assert response.content != nil
      assert %Done{} = response.content
      assert response.content.type == "done"
      assert is_binary(response.content.message)
    end
  end
end
