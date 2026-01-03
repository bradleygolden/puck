defmodule Puck.ClientTest do
  use ExUnit.Case, async: true

  alias Puck.Client

  doctest Puck.Client

  describe "backend_module/1" do
    test "returns Mock backend module" do
      client = Client.new({Puck.Backends.Mock, response: "Hello"})
      assert Client.backend_module(client) == Puck.Backends.Mock
    end

    test "returns ReqLLM backend module" do
      client = Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
      assert Client.backend_module(client) == Puck.Backends.ReqLLM
    end

    if Code.ensure_loaded?(BamlElixir.Client) do
      test "returns Baml backend module" do
        client =
          Client.new({Puck.Backends.Baml, function: "ExtractPerson", path: "priv/baml_src"})

        assert Client.backend_module(client) == Puck.Backends.Baml
      end
    end
  end

  describe "backend_config/1" do
    test "returns the backend configuration map" do
      client = Client.new({Puck.Backends.Mock, response: "Hello", delay: 100})
      assert Client.backend_config(client) == %{response: "Hello", delay: 100}
    end

    test "normalizes string model to map" do
      client = Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
      assert Client.backend_config(client) == %{model: "anthropic:claude-sonnet-4-5"}
    end
  end
end
