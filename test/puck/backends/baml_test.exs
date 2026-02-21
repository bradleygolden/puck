if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Backends.BamlTest do
    use ExUnit.Case, async: true
    use Mimic

    alias Puck.Backends.Baml
    alias Puck.Message
    alias Puck.TestSupport.BamlClientMock
    alias Puck.TestSupport.BamlCollectorMock

    setup_all do
      Mimic.copy(BamlClientMock)
      Mimic.copy(BamlCollectorMock)
      :ok
    end

    defp test_config(overrides \\ %{}) do
      %{
        function: "DreambeamChat",
        client_module: BamlClientMock,
        collector_module: BamlCollectorMock
      }
      |> Map.merge(overrides)
    end

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

        expect(BamlCollectorMock, :new, fn _name -> collector end)

        expect(BamlClientMock, :call, fn "DreambeamChat", %{text: "hello"}, opts ->
          assert opts.collectors == [collector]
          {:ok, "ok"}
        end)

        expect(BamlCollectorMock, :usage, fn ^collector ->
          %{"input_tokens" => 100, "output_tokens" => 20}
        end)

        expect(BamlCollectorMock, :last_function_log, fn ^collector ->
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
          Baml.call(test_config(), [Message.new(:user, "hello")], [])

        assert response.usage[:input_tokens] == 100
        assert response.usage[:output_tokens] == 20
        assert response.usage["cache_creation_input_tokens"] == 12
        assert get_in(response.usage, ["prompt_tokens_details", "cached_tokens"]) == 64
        assert response.usage["cache_read_input_tokens"] == 64
      end

      test "infers canonical cache fields from generic usage aliases" do
        collector = :collector_ref

        expect(BamlCollectorMock, :new, fn _name -> collector end)

        expect(BamlClientMock, :call, fn "DreambeamChat", %{text: "hello"}, _opts ->
          {:ok, "ok"}
        end)

        expect(BamlCollectorMock, :usage, fn ^collector ->
          %{"input_tokens" => 100, "output_tokens" => 20}
        end)

        expect(BamlCollectorMock, :last_function_log, fn ^collector ->
          %{
            "calls" => [
              %{
                "response" => %{
                  "body" =>
                    ~s({"usage":{"prompt_tokens":100,"input_token_details":{"cached_tokens":"256"},"cache":{"creation_input_tokens":7}}})
                }
              }
            ]
          }
        end)

        {:ok, response} =
          Baml.call(test_config(), [Message.new(:user, "hello")], [])

        assert response.usage["cache_read_input_tokens"] == 256
        assert response.usage["cache_creation_input_tokens"] == 7
        assert get_in(response.usage, ["input_token_details", "cached_tokens"]) == "256"
      end

      test "does not override collector cache usage with inferred alias values" do
        collector = :collector_ref

        expect(BamlCollectorMock, :new, fn _name -> collector end)

        expect(BamlClientMock, :call, fn "DreambeamChat", %{text: "hello"}, _opts ->
          {:ok, "ok"}
        end)

        expect(BamlCollectorMock, :usage, fn ^collector ->
          %{"input_tokens" => 100, "output_tokens" => 20, "cache_read_input_tokens" => 9}
        end)

        expect(BamlCollectorMock, :last_function_log, fn ^collector ->
          %{
            "calls" => [
              %{
                "response" => %{
                  "body" =>
                    ~s({"usage":{"prompt_tokens":100,"prompt_tokens_details":{"cached_tokens":256}}})
                }
              }
            ]
          }
        end)

        {:ok, response} =
          Baml.call(test_config(), [Message.new(:user, "hello")], [])

        assert response.usage["cache_read_input_tokens"] == 9
      end

      test "deep merges nested usage maps to preserve unknown provider fields" do
        collector = :collector_ref

        expect(BamlCollectorMock, :new, fn _name -> collector end)

        expect(BamlClientMock, :call, fn "DreambeamChat", %{text: "hello"}, _opts ->
          {:ok, "ok"}
        end)

        expect(BamlCollectorMock, :usage, fn ^collector ->
          %{
            "input_tokens" => 100,
            "output_tokens" => 20,
            "provider_meta" => %{"tier" => "priority"},
            "prompt_tokens_details" => %{"custom_flag" => 1}
          }
        end)

        expect(BamlCollectorMock, :last_function_log, fn ^collector ->
          %{
            "calls" => [
              %{
                "response" => %{
                  "body" =>
                    ~s({"usage":{"prompt_tokens_details":{"cached_tokens":32},"provider_meta":{"region":"us-east"}}})
                }
              }
            ]
          }
        end)

        {:ok, response} =
          Baml.call(test_config(), [Message.new(:user, "hello")], [])

        assert get_in(response.usage, ["provider_meta", "tier"]) == "priority"
        assert get_in(response.usage, ["provider_meta", "region"]) == "us-east"
        assert get_in(response.usage, ["prompt_tokens_details", "custom_flag"]) == 1
        assert get_in(response.usage, ["prompt_tokens_details", "cached_tokens"]) == 32
      end
    end

    describe "stream lifecycle" do
      test "stream does not abort when client stream callback is async" do
        collector = :collector_ref

        expect(BamlCollectorMock, :new, fn _name -> collector end)
        stub(BamlCollectorMock, :usage, fn _collector -> %{} end)
        stub(BamlCollectorMock, :last_function_log, fn _collector -> %{} end)

        expect(BamlClientMock, :stream, fn "DreambeamChat", %{text: "hello"}, callback, opts ->
          assert opts.collectors == [collector]

          stream_caller = self()
          stream_ref = Process.monitor(stream_caller)

          spawn(fn ->
            receive do
              {:DOWN, ^stream_ref, :process, ^stream_caller, _} ->
                callback.({:error, "AbortError"})
            after
              10 ->
                callback.({:done, %{type: "done", message: "ok"}})
            end
          end)

          :ok
        end)

        {:ok, stream} = Baml.stream(test_config(), [Message.new(:user, "hello")], [])

        assert [
                 %{
                   type: :content,
                   content: %{type: "done", message: "ok"},
                   metadata: %{partial: false, backend: :baml}
                 }
               ] = Enum.to_list(stream)
      end

      test "final chunk includes usage data from collector" do
        collector = :collector_ref

        expect(BamlCollectorMock, :new, fn _name -> collector end)

        expect(BamlCollectorMock, :usage, fn ^collector ->
          %{"input_tokens" => 50, "output_tokens" => 10}
        end)

        expect(BamlCollectorMock, :last_function_log, fn ^collector ->
          %{
            "calls" => [
              %{
                "usage" => %{"input_tokens" => 50, "output_tokens" => 10}
              }
            ]
          }
        end)

        expect(BamlClientMock, :stream, fn "DreambeamChat", %{text: "hello"}, callback, _opts ->
          spawn(fn ->
            callback.({:done, "final result"})
          end)

          :ok
        end)

        {:ok, stream} = Baml.stream(test_config(), [Message.new(:user, "hello")], [])

        chunks = Enum.to_list(stream)
        assert [final_chunk] = chunks
        assert final_chunk.type == :content
        assert final_chunk.content == "final result"
        assert final_chunk.metadata.partial == false
        assert final_chunk.usage[:input_tokens] == 50
        assert final_chunk.usage[:output_tokens] == 10
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
