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
end
