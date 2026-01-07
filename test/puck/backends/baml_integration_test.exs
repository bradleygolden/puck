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

      test "call/2 tracks token usage via collector" do
        client =
          Puck.Client.new(
            {Puck.Backends.Baml, function: "Summarize", path: "test/support/baml_src"}
          )

        {:ok, response, _ctx} =
          Puck.call(client, "The quick brown fox jumps over the lazy dog.")

        assert response.usage != %{}
        assert is_integer(response.usage[:input_tokens]) or is_nil(response.usage[:input_tokens])

        assert is_integer(response.usage[:output_tokens]) or
                 is_nil(response.usage[:output_tokens])
      end

      test "call/2 accumulates tokens in context metadata" do
        client =
          Puck.Client.new(
            {Puck.Backends.Baml, function: "Summarize", path: "test/support/baml_src"}
          )

        context = Puck.Context.new()

        {:ok, _response, context} = Puck.call(client, "First message", context)
        {:ok, _response, context} = Puck.call(client, "Second message", context)

        total_tokens = Puck.Context.total_tokens(context)
        assert total_tokens >= 0
      end

      test "BAML with {:summarize, opts} triggers compaction based on token threshold" do
        summarize_client =
          Puck.Client.new({Puck.Backends.Mock, response: "Summary of conversation"})

        client =
          Puck.Client.new(
            {Puck.Backends.Baml, function: "Summarize", path: "test/support/baml_src"},
            auto_compaction: {:summarize, max_tokens: 50, client: summarize_client, keep_last: 1}
          )

        context = Puck.Context.new()

        {:ok, _response, context} = Puck.call(client, "First message", context)
        tokens_after_first = Puck.Context.total_tokens(context)
        messages_after_first = Puck.Context.message_count(context)

        {:ok, _response, final_context} = Puck.call(client, "Second message", context)

        if tokens_after_first >= 50 do
          assert Puck.Context.message_count(final_context) < messages_after_first + 2
        else
          assert Puck.Context.message_count(final_context) == messages_after_first + 2
        end
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
