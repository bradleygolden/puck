if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Backends.BamlTest do
    use ExUnit.Case, async: true
    use Mimic

    alias Puck.Backends.Baml
    alias Puck.Message

    describe "Puck.Backends.Baml" do
      test "implements Puck.Backend behaviour" do
        Code.ensure_loaded!(Baml)

        assert function_exported?(Baml, :call, 3)
        assert function_exported?(Baml, :stream, 3)
        assert function_exported?(Baml, :introspect, 1)
      end

      test "introspect returns backend info from config" do
        config = %{function: "ExtractPerson", llm_client: "anthropic"}
        info = Baml.introspect(config)

        assert info.provider == "baml"
        assert info.model == "anthropic"
        assert info.operation == :chat
        assert info.function == "ExtractPerson"
        assert :streaming in info.capabilities
        assert :structured_output in info.capabilities
      end

      test "introspect handles missing llm_client" do
        config = %{function: "MyFunction"}
        info = Baml.introspect(config)

        assert info.provider == "baml"
        assert info.model == "default"
        assert info.function == "MyFunction"
      end

      test "introspect handles empty config" do
        info = Baml.introspect(%{})

        assert info.provider == "baml"
        assert info.model == "default"
        assert info.function == "unknown"
      end
    end

    describe "extract_raw_response/1" do
      test "returns nil for unused collector" do
        collector = BamlElixir.Collector.new("test-#{System.unique_integer([:positive])}")
        assert is_nil(Baml.extract_raw_response(collector))
      end

      test "returns nil for nil collector" do
        assert is_nil(Baml.extract_raw_response(nil))
      end
    end

    describe "usage extraction" do
      test "enriches usage with provider cache fields from response body usage" do
        collector = :collector_ref

        expect(BamlElixir.Collector, :new, fn _name -> collector end)

        expect(BamlElixir.Client, :call, fn "DreambeamChat", %{text: "hello"}, opts ->
          assert opts.collectors == [collector]
          {:ok, "ok"}
        end)

        expect(BamlElixir.Collector, :usage, fn ^collector ->
          %{"input_tokens" => 100, "output_tokens" => 20}
        end)

        expect(BamlElixir.Collector, :last_function_log, fn ^collector ->
          %{
            "calls" => [
              %{
                "usage" => %{"input_tokens" => 100, "output_tokens" => 20},
                "response" => %{
                  "body" =>
                    ~s({"usage":{"cache_creation_input_tokens":12,"prompt_tokens_details":{"cached_tokens":64}}})
                }
              }
            ]
          }
        end)

        {:ok, response} =
          Baml.call(%{function: "DreambeamChat"}, [Message.new(:user, "hello")], [])

        assert response.usage[:input_tokens] == 100
        assert response.usage[:output_tokens] == 20
        assert response.usage["cache_creation_input_tokens"] == 12
        assert get_in(response.usage, ["prompt_tokens_details", "cached_tokens"]) == 64
        assert response.usage["cache_read_input_tokens"] == 64
      end

      test "falls back to Fireworks cache headers when cache fields are missing in usage body" do
        collector = :collector_ref

        expect(BamlElixir.Collector, :new, fn _name -> collector end)

        expect(BamlElixir.Client, :call, fn "DreambeamChat", %{text: "hello"}, _opts ->
          {:ok, "ok"}
        end)

        expect(BamlElixir.Collector, :usage, fn ^collector ->
          %{"input_tokens" => 100, "output_tokens" => 20}
        end)

        expect(BamlElixir.Collector, :last_function_log, fn ^collector ->
          %{
            "calls" => [
              %{
                "response" => %{
                  "body" => ~s({"usage":{"prompt_tokens":100}}),
                  "headers" => %{"fireworks-cached-prompt-tokens" => "256"}
                }
              }
            ]
          }
        end)

        {:ok, response} =
          Baml.call(%{function: "DreambeamChat"}, [Message.new(:user, "hello")], [])

        assert response.usage["cache_read_input_tokens"] == 256
      end

      test "does not override collector cache usage with inferred fallback values" do
        collector = :collector_ref

        expect(BamlElixir.Collector, :new, fn _name -> collector end)

        expect(BamlElixir.Client, :call, fn "DreambeamChat", %{text: "hello"}, _opts ->
          {:ok, "ok"}
        end)

        expect(BamlElixir.Collector, :usage, fn ^collector ->
          %{"input_tokens" => 100, "output_tokens" => 20, "cache_read_input_tokens" => 9}
        end)

        expect(BamlElixir.Collector, :last_function_log, fn ^collector ->
          %{
            "calls" => [
              %{
                "response" => %{
                  "body" => ~s({"usage":{"prompt_tokens":100}}),
                  "headers" => %{"fireworks-cached-prompt-tokens" => "256"}
                }
              }
            ]
          }
        end)

        {:ok, response} =
          Baml.call(%{function: "DreambeamChat"}, [Message.new(:user, "hello")], [])

        assert response.usage["cache_read_input_tokens"] == 9
      end
    end

    describe "NIF result normalization (issue #22)" do
      defmodule ActionA do
        @moduledoc false
        defstruct type: "action_a", name: nil
      end

      defmodule ActionB do
        @moduledoc false
        defstruct type: "action_b", count: nil
      end

      defp union_schema do
        Zoi.union([
          Zoi.struct(ActionA, %{type: Zoi.literal("action_a"), name: Zoi.string()}, coerce: true),
          Zoi.struct(ActionB, %{type: Zoi.literal("action_b"), count: Zoi.integer()},
            coerce: true
          )
        ])
      end

      test "Zoi.parse fails when enum values have BAML metadata (atom keys)" do
        result = %{
          __baml_class__: "ActionA",
          type: %{__baml_enum__: "ActionType", value: "action_a"},
          name: "test"
        }

        assert {:error, _} = Zoi.parse(union_schema(), result)
      end

      test "Zoi.parse fails when enum values have BAML metadata (string keys)" do
        result = %{
          "__baml_class__" => "ActionA",
          "type" => %{"__baml_enum__" => "ActionType", "value" => "action_a"},
          "name" => "test"
        }

        assert {:error, _} = Zoi.parse(union_schema(), result)
      end

      test "Zoi.parse succeeds with clean data (expected after normalization)" do
        clean = %{type: "action_a", name: "test"}

        assert {:ok, %ActionA{type: "action_a", name: "test"}} = Zoi.parse(union_schema(), clean)
      end

      test "Zoi.parse fails with nested BAML metadata in list elements" do
        schema =
          Zoi.struct(
            ActionA,
            %{type: Zoi.literal("action_a"), name: Zoi.string()},
            coerce: true
          )

        list_schema = Zoi.array(schema)

        result = [
          %{
            __baml_class__: "ActionA",
            type: %{__baml_enum__: "ActionType", value: "action_a"},
            name: "first"
          }
        ]

        assert {:error, _} = Zoi.parse(list_schema, result)
      end

      test "normalize_nif_result strips __baml_enum__ wrappers (atom keys)" do
        result = %{
          __baml_class__: "ActionA",
          type: %{__baml_enum__: "ActionType", value: "action_a"},
          name: "test"
        }

        normalized = Baml.normalize_nif_result(result)

        assert normalized == %{type: "action_a", name: "test"}
        assert {:ok, %ActionA{}} = Zoi.parse(union_schema(), normalized)
      end

      test "normalize_nif_result strips __baml_enum__ wrappers (string keys)" do
        result = %{
          "__baml_class__" => "ActionA",
          "type" => %{"__baml_enum__" => "ActionType", "value" => "action_a"},
          "name" => "test"
        }

        normalized = Baml.normalize_nif_result(result)

        assert normalized == %{"type" => "action_a", "name" => "test"}
      end

      test "normalize_nif_result handles nested maps recursively" do
        result = %{
          __baml_class__: "Root",
          status: %{__baml_enum__: "Status", value: "active"},
          address: %{
            __baml_class__: "Address",
            city: "NYC"
          }
        }

        normalized = Baml.normalize_nif_result(result)

        assert normalized == %{status: "active", address: %{city: "NYC"}}
      end

      test "normalize_nif_result handles lists with BAML metadata" do
        result = [
          %{
            __baml_class__: "ActionA",
            type: %{__baml_enum__: "ActionType", value: "action_a"},
            name: "first"
          },
          %{
            __baml_class__: "ActionB",
            type: %{__baml_enum__: "ActionType", value: "action_b"},
            count: 42
          }
        ]

        normalized = Baml.normalize_nif_result(result)

        assert normalized == [
                 %{type: "action_a", name: "first"},
                 %{type: "action_b", count: 42}
               ]
      end

      test "normalize_nif_result passes through plain values unchanged" do
        assert Baml.normalize_nif_result("hello") == "hello"
        assert Baml.normalize_nif_result(42) == 42
        assert Baml.normalize_nif_result(nil) == nil
        assert Baml.normalize_nif_result(%{name: "test"}) == %{name: "test"}
      end
    end
  end
end
