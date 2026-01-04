defmodule Puck.Integration.ThinkingTest do
  @moduledoc """
  Integration tests for thinking/reasoning token support.
  """

  use Puck.IntegrationCase

  describe "ReqLLM thinking" do
    @describetag :req_llm

    setup do
      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"})
      thinking_opts = [reasoning_effort: :medium]
      [client: client, thinking_opts: thinking_opts]
    end

    @tag timeout: 120_000
    test "returns thinking content in response", %{client: client, thinking_opts: thinking_opts} do
      {:ok, response, _ctx} =
        Puck.call(
          client,
          "What is 15 + 27? Think through this step by step.",
          Puck.Context.new(),
          backend_opts: thinking_opts
        )

      assert is_binary(response.content)
      assert response.content != ""
      assert is_binary(response.thinking)
      assert response.thinking != ""
      assert response.finish_reason == :stop
    end

    # @tag timeout: 120_000
    # test "includes thinking_tokens in usage when available", %{
    #   client: client,
    #   thinking_opts: thinking_opts
    # } do
    # TODO
    # end

    @tag timeout: 120_000
    test "streams thinking chunks", %{client: client, thinking_opts: thinking_opts} do
      {:ok, stream, _ctx} =
        Puck.stream(
          client,
          "What is 2 + 2? Think step by step.",
          Puck.Context.new(),
          backend_opts: thinking_opts
        )

      chunks = Enum.to_list(stream)

      assert chunks != []

      thinking_chunks = Enum.filter(chunks, &(&1.type == :thinking))
      content_chunks = Enum.filter(chunks, &(&1.type == :content))

      assert thinking_chunks != [], "Expected thinking chunks in stream"
      assert content_chunks != [], "Expected content chunks in stream"

      thinking_content = Enum.map_join(thinking_chunks, "", & &1.content)
      assert thinking_content != ""
    end
  end
end
