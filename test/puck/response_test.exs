defmodule Puck.ResponseTest do
  use ExUnit.Case, async: true

  alias Puck.Response

  doctest Puck.Response

  describe "new/1" do
    test "creates response with defaults" do
      response = Response.new()

      assert response.content == nil
      assert response.tool_calls == []
      assert response.finish_reason == nil
      assert response.usage == %{}
      assert response.metadata == %{}
    end

    test "creates response with content" do
      response = Response.new(content: "Hello!")

      assert response.content == "Hello!"
    end
  end

  describe "has_tool_calls?/1" do
    test "returns true when tool_calls is non-empty" do
      response = Response.new(tool_calls: [%{id: "1", name: "search", arguments: %{}}])

      assert Response.has_tool_calls?(response) == true
    end

    test "returns false when tool_calls is empty" do
      response = Response.new(content: "Hello!")

      assert Response.has_tool_calls?(response) == false
    end
  end

  describe "complete?/1" do
    test "returns true for :stop finish_reason" do
      response = Response.new(finish_reason: :stop)

      assert Response.complete?(response) == true
    end

    test "returns false for :tool_use finish_reason" do
      response = Response.new(finish_reason: :tool_use)

      assert Response.complete?(response) == false
    end
  end

  describe "total_tokens/1" do
    test "returns total_tokens when present" do
      response = Response.new(usage: %{total_tokens: 50})

      assert Response.total_tokens(response) == 50
    end

    test "calculates from input + output tokens" do
      response = Response.new(usage: %{input_tokens: 10, output_tokens: 20})

      assert Response.total_tokens(response) == 30
    end
  end

  describe "thinking/1" do
    test "returns thinking content when present" do
      response = Response.new(thinking: "Let me analyze this step by step...")

      assert Response.thinking(response) == "Let me analyze this step by step..."
    end

    test "returns nil when thinking is nil" do
      response = Response.new(content: "Hello!")

      assert Response.thinking(response) == nil
    end

    test "returns empty string when thinking is empty string" do
      response = Response.new(thinking: "")

      assert Response.thinking(response) == ""
    end
  end

  describe "thinking field" do
    test "defaults to nil" do
      response = Response.new()

      assert response.thinking == nil
    end

    test "can be set with content" do
      response = Response.new(content: "Answer", thinking: "Reasoning process")

      assert response.content == "Answer"
      assert response.thinking == "Reasoning process"
    end
  end

  describe "usage with thinking_tokens" do
    test "supports thinking_tokens in usage" do
      response = Response.new(usage: %{input_tokens: 10, output_tokens: 20, thinking_tokens: 100})

      assert response.usage.thinking_tokens == 100
    end
  end
end
