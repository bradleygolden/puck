if Code.ensure_loaded?(ClaudeAgentSDK) do
  defmodule Puck.Backends.ClaudeAgentSDKTest do
    use ExUnit.Case, async: true

    alias Puck.Backends.ClaudeAgentSDK

    describe "Puck.Backends.ClaudeAgentSDK" do
      test "implements Puck.Backend behaviour" do
        Code.ensure_loaded!(ClaudeAgentSDK)

        assert function_exported?(ClaudeAgentSDK, :call, 3)
        assert function_exported?(ClaudeAgentSDK, :stream, 3)
        assert function_exported?(ClaudeAgentSDK, :introspect, 1)
      end

      test "introspect returns backend info from config" do
        config = %{model: "sonnet", allowed_tools: ["Read", "Glob"]}
        info = ClaudeAgentSDK.introspect(config)

        assert info.provider == "claude_agent_sdk"
        assert info.model == "sonnet"
        assert info.operation == :chat
        assert :streaming in info.capabilities
        assert :tools in info.capabilities
        assert :agentic in info.capabilities
      end

      test "introspect handles missing model" do
        config = %{allowed_tools: ["Read"]}
        info = ClaudeAgentSDK.introspect(config)

        assert info.provider == "claude_agent_sdk"
        assert info.model == "default"
      end

      test "introspect handles empty config" do
        info = ClaudeAgentSDK.introspect(%{})

        assert info.provider == "claude_agent_sdk"
        assert info.model == "default"
        assert info.operation == :chat
      end
    end
  end
end

if Code.ensure_loaded?(ClaudeAgentSDK) do
  defmodule Puck.Backends.ClaudeAgentSDK.SessionResumeTest do
    use ExUnit.Case, async: true
    use Mimic

    alias Puck.Backends.ClaudeAgentSDK, as: Backend
    alias Puck.Message

    defp stub_query(session_id) do
      stub(ClaudeAgentSDK, :query, fn _prompt, _opts ->
        sdk_messages(session_id)
      end)
    end

    defp sdk_messages(session_id) do
      [
        %ClaudeAgentSDK.Message{
          type: :system,
          subtype: :init,
          data: %{session_id: session_id},
          raw: %{}
        },
        %ClaudeAgentSDK.Message{
          type: :assistant,
          data: %{
            session_id: session_id,
            message: %{content: [%{"type" => "text", "text" => "Hello from session"}]}
          },
          raw: %{}
        },
        %ClaudeAgentSDK.Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: session_id,
            result: "Hello from session",
            subtype: :success,
            usage: %{input_tokens: 10, output_tokens: 5},
            num_turns: 1,
            duration_ms: 100,
            total_cost_usd: 0.001
          },
          raw: %{}
        }
      ]
    end

    setup do
      config = %{permission_mode: :bypass_permissions}
      {:ok, config: config}
    end

    describe "tools config forwarding" do
      test "forwards tools from config to SDK options", %{config: config} do
        config = Map.put(config, :tools, [])

        expect(ClaudeAgentSDK, :query, fn _prompt, opts ->
          assert opts.tools == []
          sdk_messages("s1")
        end)

        messages = [Message.new(:user, "hello")]
        {:ok, _response} = Backend.call(config, messages, [])
      end

      test "tools defaults to nil when not in config", %{config: config} do
        expect(ClaudeAgentSDK, :query, fn _prompt, opts ->
          assert opts.tools == nil
          sdk_messages("s1")
        end)

        messages = [Message.new(:user, "hello")]
        {:ok, _response} = Backend.call(config, messages, [])
      end
    end

    describe "call/3 session resume" do
      test "starts new session when no session_id in messages", %{config: config} do
        expect(ClaudeAgentSDK, :query, fn "hello", _opts ->
          sdk_messages("new-session")
        end)

        reject(&ClaudeAgentSDK.resume/3)

        messages = [Message.new(:user, "hello")]
        {:ok, _response} = Backend.call(config, messages, [])
      end

      test "resumes session when assistant message has session_id", %{config: config} do
        expect(ClaudeAgentSDK, :resume, fn "sess-123", "what did I say?", _opts ->
          sdk_messages("sess-123")
        end)

        reject(&ClaudeAgentSDK.query/2)

        messages = [
          Message.new(:user, "hello"),
          Message.new(:assistant, "hi", %{session_id: "sess-123"}),
          Message.new(:user, "what did I say?")
        ]

        {:ok, _response} = Backend.call(config, messages, [])
      end

      test "uses most recent session_id when multiple assistant messages exist", %{config: config} do
        expect(ClaudeAgentSDK, :resume, fn "sess-latest", "third", _opts ->
          sdk_messages("sess-latest")
        end)

        reject(&ClaudeAgentSDK.query/2)

        messages = [
          Message.new(:user, "hello"),
          Message.new(:assistant, "hi", %{session_id: "sess-old"}),
          Message.new(:user, "second"),
          Message.new(:assistant, "reply", %{session_id: "sess-latest"}),
          Message.new(:user, "third")
        ]

        {:ok, _response} = Backend.call(config, messages, [])
      end

      test "ignores nil session_id in metadata", %{config: config} do
        expect(ClaudeAgentSDK, :query, fn "what did I say?", _opts ->
          sdk_messages("new-session")
        end)

        reject(&ClaudeAgentSDK.resume/3)

        messages = [
          Message.new(:user, "hello"),
          Message.new(:assistant, "hi", %{session_id: nil}),
          Message.new(:user, "what did I say?")
        ]

        {:ok, _response} = Backend.call(config, messages, [])
      end

      test "ignores empty string session_id in metadata", %{config: config} do
        expect(ClaudeAgentSDK, :query, fn "what did I say?", _opts ->
          sdk_messages("new-session")
        end)

        reject(&ClaudeAgentSDK.resume/3)

        messages = [
          Message.new(:user, "hello"),
          Message.new(:assistant, "hi", %{session_id: ""}),
          Message.new(:user, "what did I say?")
        ]

        {:ok, _response} = Backend.call(config, messages, [])
      end

      test "returns session_id in response metadata", %{config: config} do
        stub_query("my-session-id")

        messages = [Message.new(:user, "hello")]
        {:ok, response} = Backend.call(config, messages, [])

        assert response.metadata.session_id == "my-session-id"
      end
    end

    describe "stream/3 partial chunks" do
      test "emits partial chunks for content_block_delta stream events", %{config: config} do
        stub(ClaudeAgentSDK, :query, fn _prompt, _opts ->
          [
            %ClaudeAgentSDK.Message{
              type: :stream_event,
              data: %{
                event: %{
                  "type" => "content_block_delta",
                  "delta" => %{"text" => "hello"}
                }
              },
              raw: %{}
            },
            %ClaudeAgentSDK.Message{
              type: :result,
              subtype: :success,
              data: %{
                session_id: "s1",
                result: "hello",
                subtype: :success,
                usage: %{input_tokens: 1, output_tokens: 1}
              },
              raw: %{}
            }
          ]
        end)

        messages = [Message.new(:user, "hi")]
        {:ok, stream} = Backend.stream(config, messages, [])
        chunks = Enum.to_list(stream)

        partial = Enum.filter(chunks, &(&1.metadata[:partial] == true))
        assert length(partial) == 1
        assert hd(partial).content == "hello"
      end

      test "emits partial chunks for EventParser-transformed text_delta events", %{config: config} do
        stub(ClaudeAgentSDK, :query, fn _prompt, _opts ->
          [
            %ClaudeAgentSDK.Message{
              type: :stream_event,
              data: %{
                event: %{type: :text_delta, text: "hello", accumulated: "hello"}
              },
              raw: %{}
            },
            %ClaudeAgentSDK.Message{
              type: :result,
              subtype: :success,
              data: %{
                session_id: "s1",
                result: "hello",
                subtype: :success,
                usage: %{input_tokens: 1, output_tokens: 1}
              },
              raw: %{}
            }
          ]
        end)

        messages = [Message.new(:user, "hi")]
        {:ok, stream} = Backend.stream(config, messages, [])
        chunks = Enum.to_list(stream)

        partial = Enum.filter(chunks, &(&1.metadata[:partial] == true))
        assert length(partial) == 1
        assert hd(partial).content == "hello"
      end

      test "ignores non-delta stream events", %{config: config} do
        stub(ClaudeAgentSDK, :query, fn _prompt, _opts ->
          [
            %ClaudeAgentSDK.Message{
              type: :stream_event,
              data: %{
                event: %{
                  "type" => "content_block_start",
                  "content_block" => %{"type" => "text", "text" => ""}
                }
              },
              raw: %{}
            },
            %ClaudeAgentSDK.Message{
              type: :result,
              subtype: :success,
              data: %{
                session_id: "s1",
                result: "done",
                subtype: :success,
                usage: %{input_tokens: 1, output_tokens: 1}
              },
              raw: %{}
            }
          ]
        end)

        messages = [Message.new(:user, "hi")]
        {:ok, stream} = Backend.stream(config, messages, [])
        chunks = Enum.to_list(stream)

        partial = Enum.filter(chunks, &(&1.metadata[:partial] == true))
        assert partial == []
      end

      test "collects multiple partial chunks from a stream", %{config: config} do
        stub(ClaudeAgentSDK, :query, fn _prompt, _opts ->
          [
            %ClaudeAgentSDK.Message{
              type: :stream_event,
              data: %{
                event: %{
                  "type" => "content_block_delta",
                  "delta" => %{"text" => "one"}
                }
              },
              raw: %{}
            },
            %ClaudeAgentSDK.Message{
              type: :stream_event,
              data: %{
                event: %{
                  "type" => "content_block_delta",
                  "delta" => %{"text" => " two"}
                }
              },
              raw: %{}
            },
            %ClaudeAgentSDK.Message{
              type: :stream_event,
              data: %{
                event: %{
                  "type" => "content_block_delta",
                  "delta" => %{"text" => " three"}
                }
              },
              raw: %{}
            },
            %ClaudeAgentSDK.Message{
              type: :result,
              subtype: :success,
              data: %{
                session_id: "s1",
                result: "one two three",
                subtype: :success,
                usage: %{input_tokens: 1, output_tokens: 3}
              },
              raw: %{}
            }
          ]
        end)

        messages = [Message.new(:user, "count")]
        {:ok, stream} = Backend.stream(config, messages, [])
        chunks = Enum.to_list(stream)

        partial = Enum.filter(chunks, &(&1.metadata[:partial] == true))
        assert length(partial) == 3
        texts = Enum.map(partial, & &1.content)
        assert texts == ["one", " two", " three"]
      end
    end

    describe "stream/3 session resume" do
      test "starts new session without session_id", %{config: config} do
        expect(ClaudeAgentSDK, :query, fn "hello", _opts ->
          sdk_messages("new-session")
        end)

        reject(&ClaudeAgentSDK.resume/3)

        messages = [Message.new(:user, "hello")]
        {:ok, stream} = Backend.stream(config, messages, [])
        _chunks = Enum.to_list(stream)
      end

      test "resumes with session_id", %{config: config} do
        expect(ClaudeAgentSDK, :resume, fn "sess-456", "follow up", _opts ->
          sdk_messages("sess-456")
        end)

        reject(&ClaudeAgentSDK.query/2)

        messages = [
          Message.new(:user, "hello"),
          Message.new(:assistant, "hi", %{session_id: "sess-456"}),
          Message.new(:user, "follow up")
        ]

        {:ok, stream} = Backend.stream(config, messages, [])
        _chunks = Enum.to_list(stream)
      end

      test "final chunk includes session_id in metadata", %{config: config} do
        stub_query("stream-session-id")

        messages = [Message.new(:user, "hello")]
        {:ok, stream} = Backend.stream(config, messages, [])
        chunks = Enum.to_list(stream)

        final_chunk = Enum.find(chunks, &(Map.get(&1.metadata, :final) == true))
        assert final_chunk != nil
        assert final_chunk.metadata.session_id == "stream-session-id"
      end
    end
  end
end
