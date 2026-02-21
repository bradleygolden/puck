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
      case check_fireworks_available() do
        :ok ->
          :ok

        {:error, reason} ->
          flunk("FIREWORKS_API_KEY not set: #{reason}")
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

    describe "output_schema NIF normalization (issue #22)" do
      defmodule LookupContact do
        @moduledoc false
        defstruct type: nil, name: nil
      end

      @tag timeout: 60_000
      test "strips __baml_class__ metadata so Zoi can parse struct" do
        schema =
          Zoi.struct(
            LookupContact,
            %{type: Zoi.string(), name: Zoi.string()},
            coerce: true
          )

        client =
          Puck.Client.new(
            {Puck.Backends.Baml, function: "ChooseTool", path: "test/support/baml_src"}
          )

        {:ok, response, _ctx} =
          Puck.call(
            client,
            "Find Jane Doe in the CRM",
            Puck.Context.new(),
            output_schema: schema
          )

        assert response.metadata.provider == "baml"
        assert response.metadata.function == "ChooseTool"

        assert %LookupContact{} = response.content,
               "Expected a LookupContact struct but got: #{inspect(response.content)}"

        assert is_binary(response.content.type)
        assert is_binary(response.content.name)
      end
    end

    describe "dynamic_classes prompt rendering" do
      defmodule ActionSearch do
        @moduledoc false
        defstruct type: "search", query: nil
      end

      defmodule ActionDone do
        @moduledoc false
        defstruct type: "done", message: nil
      end

      @tag timeout: 60_000
      test "dynamic fields do not render // nil comments in prompt" do
        alias Puck.Backends.Baml.TypeBuilder

        schema =
          Zoi.union([
            Zoi.struct(ActionSearch, %{type: Zoi.enum(["search"]), query: Zoi.string()}),
            Zoi.struct(ActionDone, %{type: Zoi.enum(["done"]), message: Zoi.string()})
          ])

        dynamic_classes = %{"PluginAction" => [ActionSearch, ActionDone]}
        descriptions = %{"search" => "Search for items", "done" => "Task complete"}

        tb = TypeBuilder.from_dynamic_union(schema, dynamic_classes, descriptions)

        collector = BamlElixir.Collector.new("prompt-check")

        {:ok, _result} =
          BamlElixir.Client.call(
            "ChoosePluginAction",
            %{text: "Search for cats"},
            %{
              path: "test/support/baml_src",
              parse: false,
              tb: tb,
              collectors: [collector]
            }
          )

        log = BamlElixir.Collector.last_function_log(collector)
        body = get_in(log, ["calls", Access.at(0), "request", "body"])
        prompt = Jason.decode!(body)
        system_content = Enum.find(prompt["messages"], &(&1["role"] == "system"))["content"]

        refute system_content =~ "// nil",
               "Prompt should not contain '// nil' comments but got:\n#{system_content}"
      end
    end

    defp check_fireworks_available do
      case System.get_env("FIREWORKS_API_KEY") do
        key when is_binary(key) and key != "" -> :ok
        _ -> {:error, "FIREWORKS_API_KEY is not set"}
      end
    end
  end
end
