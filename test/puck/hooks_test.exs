defmodule Puck.HooksTest do
  use ExUnit.Case, async: true

  alias Puck.{Client, Context, Hooks, Response}

  defmodule TrackingHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(client, prompt, context) do
      send(self(), {:hook, :on_call_start, client, prompt, context})
      {:cont, prompt}
    end

    @impl true
    def on_call_end(client, response, context) do
      send(self(), {:hook, :on_call_end, client, response, context})
      {:cont, response}
    end

    @impl true
    def on_call_error(client, error, context) do
      send(self(), {:hook, :on_call_error, client, error, context})
    end

    @impl true
    def on_stream_start(client, prompt, context) do
      send(self(), {:hook, :on_stream_start, client, prompt, context})
      {:cont, prompt}
    end

    @impl true
    def on_stream_chunk(client, chunk, context) do
      send(self(), {:hook, :on_stream_chunk, client, chunk, context})
    end

    @impl true
    def on_stream_end(client, context) do
      send(self(), {:hook, :on_stream_end, client, context})
    end

    @impl true
    def on_backend_request(config, messages) do
      send(self(), {:hook, :on_backend_request, config, messages})
      {:cont, messages}
    end

    @impl true
    def on_backend_response(config, response) do
      send(self(), {:hook, :on_backend_response, config, response})
      {:cont, response}
    end
  end

  defmodule PartialHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, prompt, _context) do
      send(self(), {:hook, :partial_call_start})
      {:cont, prompt}
    end
  end

  defmodule TransformingHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, content, _context) do
      {:cont, "transformed: #{content}"}
    end

    @impl true
    def on_call_end(_client, response, _context) do
      {:cont, %{response | content: "modified: #{response.content}"}}
    end

    @impl true
    def on_backend_request(_config, messages) do
      {:cont, messages ++ [%{role: "injected", content: "extra"}]}
    end

    @impl true
    def on_backend_response(_config, response) do
      {:cont, %{response | metadata: Map.put(response.metadata, :transformed, true)}}
    end
  end

  defmodule PrefixHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, content, _context) do
      {:cont, "[prefix] #{content}"}
    end
  end

  defmodule SuffixHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, content, _context) do
      {:cont, "#{content} [suffix]"}
    end
  end

  defmodule HaltingHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, _content, _context) do
      {:halt, %Response{content: "cached response", metadata: %{}}}
    end
  end

  defmodule ErrorHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, _content, _context) do
      {:error, :blocked_by_guardrails}
    end
  end

  defmodule CompactionContHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_compaction_start(context, _strategy, _config) do
      send(self(), {:hook, :on_compaction_start})
      {:cont, context}
    end

    @impl true
    def on_compaction_end(context, _strategy) do
      send(self(), {:hook, :on_compaction_end})
      {:cont, context}
    end
  end

  defmodule CompactionHaltHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_compaction_start(context, _strategy, _config) do
      {:halt, context}
    end
  end

  defmodule CompactionErrorHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_compaction_start(_context, _strategy, _config) do
      {:error, :compaction_blocked}
    end
  end

  defmodule CompactionTransformHooks do
    @behaviour Puck.Hooks

    @impl true
    def on_compaction_end(context, _strategy) do
      updated = Context.put_metadata(context, :transformed_by_hook, true)
      {:cont, updated}
    end
  end

  describe "Hooks.invoke/4 (transforming)" do
    test "passes through value when callback returns {:cont, value}" do
      assert {:cont, "hello"} =
               Hooks.invoke(TrackingHooks, :on_call_start, [:agent, "hello", :context], "hello")

      assert_received {:hook, :on_call_start, :agent, "hello", :context}
    end

    test "handles nil hooks" do
      assert {:cont, "value"} =
               Hooks.invoke(nil, :on_call_start, [:agent, "prompt", :context], "value")

      refute_received {:hook, _, _, _, _}
    end

    test "invokes callback on list of modules" do
      assert {:cont, "prompt"} =
               Hooks.invoke(
                 [TrackingHooks, PartialHooks],
                 :on_call_start,
                 [:agent, "prompt", :context],
                 "prompt"
               )

      assert_received {:hook, :on_call_start, :agent, "prompt", :context}
      assert_received {:hook, :partial_call_start}
    end

    test "passes through when callback not implemented" do
      assert {:cont, "value"} =
               Hooks.invoke(PartialHooks, :on_call_end, [:agent, :response, :context], "value")

      refute_received {:hook, _, _, _, _}
    end

    test "returns transformed value" do
      assert {:cont, "transformed: hello"} =
               Hooks.invoke(
                 TransformingHooks,
                 :on_call_start,
                 [:agent, "hello", :context],
                 "hello"
               )
    end

    test "chains transformations across multiple hooks" do
      assert {:cont, "[prefix] hello [suffix]"} =
               Hooks.invoke(
                 [PrefixHooks, SuffixHooks],
                 :on_call_start,
                 [:agent, "hello", :context],
                 "hello"
               )
    end

    test "returns halt with response" do
      assert {:halt, %Response{content: "cached response"}} =
               Hooks.invoke(HaltingHooks, :on_call_start, [:agent, "hello", :context], "hello")
    end

    test "returns error" do
      assert {:error, :blocked_by_guardrails} =
               Hooks.invoke(ErrorHooks, :on_call_start, [:agent, "hello", :context], "hello")
    end
  end

  describe "Hooks.invoke/3 (observational)" do
    test "invokes callback and returns :ok" do
      assert :ok = Hooks.invoke(TrackingHooks, :on_call_error, [:agent, :error, :context])
      assert_received {:hook, :on_call_error, :agent, :error, :context}
    end

    test "handles nil hooks" do
      assert :ok = Hooks.invoke(nil, :on_call_error, [:agent, :error, :context])
      refute_received {:hook, _, _, _, _}
    end

    test "invokes on list of modules" do
      assert :ok = Hooks.invoke([TrackingHooks], :on_call_error, [:agent, :error, :context])
      assert_received {:hook, :on_call_error, :agent, :error, :context}
    end
  end

  describe "Hooks.merge/2" do
    test "returns nil when both are nil" do
      assert Hooks.merge(nil, nil) == nil
    end

    test "returns agent hooks when call hooks are nil" do
      assert Hooks.merge(TrackingHooks, nil) == [TrackingHooks]
    end

    test "returns call hooks when agent hooks are nil" do
      assert Hooks.merge(nil, TrackingHooks) == [TrackingHooks]
    end

    test "merges agent and call hooks" do
      assert Hooks.merge(TrackingHooks, PartialHooks) == [TrackingHooks, PartialHooks]
    end

    test "normalizes single modules to lists" do
      assert Hooks.merge([TrackingHooks], PartialHooks) == [TrackingHooks, PartialHooks]
    end
  end

  describe "call/4 with hooks" do
    test "invokes call lifecycle hooks" do
      client = Client.new({Puck.Backends.Mock, response: "Hello!"}, hooks: TrackingHooks)
      context = Context.new()

      {:ok, response, _context} = Puck.call(client, "Hi!", context)

      assert_received {:hook, :on_call_start, ^client, "Hi!", ^context}
      assert_received {:hook, :on_backend_request, _config, _messages}
      assert_received {:hook, :on_backend_response, _config, ^response}
      assert_received {:hook, :on_call_end, ^client, ^response, _updated_context}
    end

    test "invokes on_call_error on failure" do
      client = Client.new({Puck.Backends.Mock, error: :rate_limited}, hooks: TrackingHooks)
      context = Context.new()

      {:error, :rate_limited} = Puck.call(client, "Hi!", context)

      assert_received {:hook, :on_call_start, ^client, "Hi!", ^context}
      assert_received {:hook, :on_call_error, ^client, :rate_limited, ^context}
    end

    test "per-call hooks override client hooks" do
      client = Client.new({Puck.Backends.Mock, response: "Hello!"}, hooks: PartialHooks)
      context = Context.new()

      {:ok, _response, _context} = Puck.call(client, "Hi!", context, hooks: TrackingHooks)

      assert_received {:hook, :partial_call_start}
      assert_received {:hook, :on_call_start, _, _, _}
    end

    test "works without any hooks" do
      client = Client.new({Puck.Backends.Mock, response: "Hello!"})
      context = Context.new()

      {:ok, response, _context} = Puck.call(client, "Hi!", context)
      assert response.content == "Hello!"
    end

    test "halts execution and returns cached response" do
      client =
        Client.new({Puck.Backends.Mock, response: "Should not be called"}, hooks: HaltingHooks)

      context = Context.new()

      {:ok, response, _context} = Puck.call(client, "Hi!", context)

      assert response.content == "cached response"
    end

    test "returns error when hook errors" do
      client =
        Client.new({Puck.Backends.Mock, response: "Should not be called"}, hooks: ErrorHooks)

      context = Context.new()

      {:error, :blocked_by_guardrails} = Puck.call(client, "Hi!", context)
    end

    test "transforms content and response" do
      client = Client.new({Puck.Backends.Mock, response: "Hello!"}, hooks: TransformingHooks)
      context = Context.new()

      {:ok, response, _context} = Puck.call(client, "Hi!", context)

      assert response.content == "modified: Hello!"
      assert response.metadata[:transformed] == true
    end
  end

  describe "stream/4 with hooks" do
    test "invokes stream lifecycle hooks" do
      client =
        Client.new({Puck.Backends.Mock, stream_chunks: ["Hello", " ", "world"]},
          hooks: TrackingHooks
        )

      context = Context.new()

      {:ok, stream, _context} = Puck.stream(client, "Hi!", context)

      assert_received {:hook, :on_stream_start, ^client, "Hi!", ^context}
      assert_received {:hook, :on_backend_request, _config, _messages}

      chunks = Enum.to_list(stream)
      assert length(chunks) == 3

      assert_received {:hook, :on_stream_chunk, ^client, _, _}
      assert_received {:hook, :on_stream_chunk, ^client, _, _}
      assert_received {:hook, :on_stream_chunk, ^client, _, _}

      assert_received {:hook, :on_stream_end, ^client, ^context}
    end
  end

  describe "compaction hooks via Hooks.invoke/4" do
    test "on_compaction_start passes through context when callback returns {:cont, context}" do
      context = Context.new()

      assert {:cont, ^context} =
               Hooks.invoke(
                 CompactionContHooks,
                 :on_compaction_start,
                 [context, :test_strategy, %{}],
                 context
               )

      assert_received {:hook, :on_compaction_start}
    end

    test "on_compaction_start halts when callback returns {:halt, context}" do
      context = Context.new()

      assert {:halt, ^context} =
               Hooks.invoke(
                 CompactionHaltHooks,
                 :on_compaction_start,
                 [context, :test_strategy, %{}],
                 context
               )
    end

    test "on_compaction_start returns error when callback returns {:error, reason}" do
      context = Context.new()

      assert {:error, :compaction_blocked} =
               Hooks.invoke(
                 CompactionErrorHooks,
                 :on_compaction_start,
                 [context, :test_strategy, %{}],
                 context
               )
    end

    test "on_compaction_end transforms context" do
      context = Context.new()

      assert {:cont, transformed_context} =
               Hooks.invoke(
                 CompactionTransformHooks,
                 :on_compaction_end,
                 [context, :test_strategy],
                 context
               )

      assert Context.get_metadata(transformed_context, :transformed_by_hook) == true
    end
  end
end
