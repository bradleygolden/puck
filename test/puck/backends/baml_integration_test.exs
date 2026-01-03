if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Backends.BamlIntegrationTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :integration
    @moduletag :baml

    defmodule TestBaml do
      use BamlElixir.Client, path: "test/support/baml_src"
    end

    setup do
      case check_ollama_available() do
        :ok ->
          :ok

        {:error, reason} ->
          flunk("Ollama is not available: #{reason}. Start Ollama with: ollama serve")
      end
    end

    describe "direct BAML function calls" do
      test "ExtractPerson extracts structured data" do
        {:ok, result} = TestBaml.ExtractPerson.call(%{text: "John Smith is 30 years old"})

        assert is_struct(result, TestBaml.Person) or is_map(result)
        assert result.name =~ ~r/john/i or result.name =~ ~r/smith/i
      end
    end

    describe "Puck BAML backend integration" do
      test "call/2 with :baml backend executes BAML function" do
        client =
          Puck.Client.new(
            {Puck.Backends.Baml, function: "Summarize", path: "test/support/baml_src"}
          )

        {:ok, response, _ctx} =
          Puck.call(client, "The quick brown fox jumps over the lazy dog.")

        assert response.content != nil
        assert is_binary(response.content)
        assert response.metadata.provider == "baml"
        assert response.metadata.function == "Summarize"
      end
    end

    defp check_ollama_available do
      url = "http://localhost:11434/api/tags"

      case :httpc.request(:get, {~c"#{url}", []}, [timeout: 5000], []) do
        {:ok, {{_, 200, _}, _, _}} ->
          :ok

        {:ok, {{_, status, _}, _, _}} ->
          {:error, "Ollama returned status #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end
end
