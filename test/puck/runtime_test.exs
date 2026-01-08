defmodule Puck.RuntimeTest do
  use ExUnit.Case, async: true

  alias Puck.Backends.Mock
  alias Puck.{Client, Context}

  defmodule TestCompactionStrategy do
    @behaviour Puck.Compaction

    @impl true
    def compact(context, config) do
      keep_last = Map.get(config, :keep_last, 1)
      messages = Context.messages(context)

      if length(messages) <= keep_last do
        {:ok, context}
      else
        kept = Enum.take(messages, -keep_last)
        new_context = %{context | messages: kept}
        {:ok, new_context}
      end
    end

    @impl true
    def should_compact?(context, config) do
      threshold = Map.get(config, :threshold, 3)
      Context.message_count(context) > threshold
    end

    @impl true
    def introspect(_config), do: %{strategy: "test"}
  end

  describe "auto-compaction in call/4" do
    test "triggers compaction when threshold exceeded" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, %{threshold: 2, keep_last: 2}}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) == 2
    end

    test "does not compact when below threshold" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, %{threshold: 10, keep_last: 1}}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")

      {:ok, _response, final_context} = Puck.call(client, "Q2", context)

      assert Context.message_count(final_context) == 4
    end

    test "does not compact when auto_compaction is nil" do
      client = Client.new({Mock, response: "Response"})

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) == 6
    end

    test "does not compact when auto_compaction is false" do
      client = Client.new({Mock, response: "Response"}, auto_compaction: false)

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) == 6
    end

    test "{:summarize, opts} with explicit client performs compaction" do
      summarize_client = Client.new({Mock, response: "Summary of conversation"})

      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {:summarize, max_tokens: 15, client: summarize_client, keep_last: 1}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")

      {:ok, _response, context} = Puck.call(client, "Q2", context)
      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) <= 4
    end

    test "{module, keyword_list} is accepted and converted to map" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, [threshold: 5, keep_last: 2]}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")
        |> Context.add_message(:user, "Q3")
        |> Context.add_message(:assistant, "A3")

      {:ok, _response, final_context} = Puck.call(client, "Q4", context)

      assert Context.message_count(final_context) == 2
    end
  end

  describe "auto-compaction in stream/4" do
    test "compacts before streaming when threshold exceeded" do
      client =
        Client.new(
          {Mock, stream: [%{content: "chunk"}]},
          auto_compaction: {TestCompactionStrategy, %{threshold: 2, keep_last: 1}}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _stream, compacted_context} = Puck.stream(client, "Q3", context)

      assert Context.message_count(compacted_context) == 2
    end
  end

  describe "auto_compaction config validation" do
    test "{:summarize, opts} with max_tokens is accepted" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {:summarize, max_tokens: 100_000, keep_last: 5}
        )

      assert client.auto_compaction == {:summarize, max_tokens: 100_000, keep_last: 5}
    end

    test "{:summarize, opts} without max_tokens raises on first call" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {:summarize, keep_last: 5}
        )

      context = Context.new()

      assert_raise ArgumentError, ~r/requires :max_tokens/, fn ->
        Puck.call(client, "Hello", context)
      end
    end

    test "{:sliding_window, opts} is accepted" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {:sliding_window, window_size: 30}
        )

      assert client.auto_compaction == {:sliding_window, window_size: 30}
    end

    test "{module, map} is accepted" do
      config = %{threshold: 5, keep_last: 2}

      client =
        Client.new({Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, config}
        )

      assert client.auto_compaction == {TestCompactionStrategy, config}
    end
  end

  describe "compaction hooks" do
    defmodule CompactionHooks do
      @behaviour Puck.Hooks

      @impl true
      def on_compaction_start(context, _strategy, _config) do
        send(self(), {:compaction_start, Context.message_count(context)})
        {:cont, context}
      end

      @impl true
      def on_compaction_end(context, _strategy) do
        send(self(), {:compaction_end, Context.message_count(context)})
        {:cont, context}
      end
    end

    test "invokes compaction hooks during auto-compaction" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, %{threshold: 2, keep_last: 1}},
          hooks: CompactionHooks
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, _context} = Puck.call(client, "Q3", context)

      assert_received {:compaction_start, 6}
      assert_received {:compaction_end, 1}
    end

    defmodule HaltingHooks do
      @behaviour Puck.Hooks

      @impl true
      def on_compaction_start(context, _strategy, _config) do
        {:halt, context}
      end
    end

    test "on_compaction_start can halt compaction" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, %{threshold: 2, keep_last: 1}},
          hooks: HaltingHooks
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) == 6
    end

    defmodule ErrorOnEndHooks do
      @behaviour Puck.Hooks

      @impl true
      def on_compaction_end(_context, _strategy) do
        {:error, :hook_error}
      end
    end

    test "on_compaction_end error returns compacted context anyway" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, %{threshold: 2, keep_last: 1}},
          hooks: ErrorOnEndHooks
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) == 1
    end
  end

  describe "compaction telemetry" do
    test "emits telemetry events during compaction" do
      test_ref = make_ref()
      handler_id = "test-handler-#{:erlang.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:puck, :compaction, :start],
          [:puck, :compaction, :stop]
        ],
        fn event, measurements, metadata, config ->
          send(config.test_pid, {:telemetry, config.test_ref, event, measurements, metadata})
        end,
        %{test_pid: self(), test_ref: test_ref}
      )

      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {TestCompactionStrategy, %{threshold: 2, keep_last: 1}}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, _context} = Puck.call(client, "Q3", context)

      assert_receive {:telemetry, ^test_ref, [:puck, :compaction, :start], %{system_time: _},
                      %{strategy: TestCompactionStrategy}}

      assert_receive {:telemetry, ^test_ref, [:puck, :compaction, :stop],
                      %{duration: _, messages_before: 6, messages_after: 1}, _}

      :telemetry.detach(handler_id)
    end

    test "emits error telemetry when compaction fails" do
      test_ref = make_ref()
      handler_id = "test-error-handler-#{:erlang.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:puck, :compaction, :error],
        fn event, measurements, metadata, config ->
          send(config.test_pid, {:telemetry, config.test_ref, event, measurements, metadata})
        end,
        %{test_pid: self(), test_ref: test_ref}
      )

      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {__MODULE__.FailingCompactionStrategy, %{threshold: 2}}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert_receive {:telemetry, ^test_ref, [:puck, :compaction, :error], %{duration: _},
                      %{reason: :test_failure}}

      assert Context.message_count(final_context) == 6

      :telemetry.detach(handler_id)
    end
  end

  describe "token tracking" do
    test "accumulates token usage across calls" do
      client =
        Client.new({Mock, response: "Response", usage: %{input_tokens: 10, output_tokens: 5}})

      context = Context.new()

      {:ok, _response, context} = Puck.call(client, "Q1", context)
      tokens_after_first = Context.total_tokens(context)
      assert tokens_after_first > 0

      {:ok, _response, context} = Puck.call(client, "Q2", context)
      tokens_after_second = Context.total_tokens(context)
      assert tokens_after_second > tokens_after_first
    end
  end

  describe "compaction failure handling" do
    test "returns original context when compaction fails" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {__MODULE__.FailingCompactionStrategy, %{threshold: 2}}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) == 6
    end
  end

  describe "sliding_window at runtime" do
    test "{:sliding_window, opts} compacts when message count exceeds window" do
      client =
        Client.new(
          {Mock, response: "Response"},
          auto_compaction: {:sliding_window, window_size: 2}
        )

      context =
        Context.new()
        |> Context.add_message(:user, "Q1")
        |> Context.add_message(:assistant, "A1")
        |> Context.add_message(:user, "Q2")
        |> Context.add_message(:assistant, "A2")

      {:ok, _response, final_context} = Puck.call(client, "Q3", context)

      assert Context.message_count(final_context) == 2
    end
  end

  defmodule FailingCompactionStrategy do
    @behaviour Puck.Compaction

    @impl true
    def compact(_context, _config) do
      {:error, :test_failure}
    end

    @impl true
    def should_compact?(context, config) do
      threshold = Map.get(config, :threshold, 3)
      Context.message_count(context) > threshold
    end

    @impl true
    def introspect(_config), do: %{strategy: "failing"}
  end

  describe "BAML compaction compatibility" do
    test "{:summarize, opts} auto-detects BAML backend and uses built-in Summarize" do
      client =
        Client.new(
          {Puck.Backends.Baml, function: "ExtractPerson", client_registry: %{primary: "test"}},
          auto_compaction: {:summarize, max_tokens: 100_000}
        )

      assert client.auto_compaction == {:summarize, max_tokens: 100_000}
    end

    test "{:summarize, opts} works for BAML when explicit client provided" do
      summarize_client = Client.new({Mock, response: "Summary"})

      client =
        Client.new(
          {Puck.Backends.Baml, function: "ExtractPerson"},
          auto_compaction: {:summarize, max_tokens: 100_000, client: summarize_client}
        )

      assert client.auto_compaction ==
               {:summarize, max_tokens: 100_000, client: summarize_client}
    end

    test "{:sliding_window, opts} works for BAML backend" do
      client =
        Client.new(
          {Puck.Backends.Baml, function: "ExtractPerson"},
          auto_compaction: {:sliding_window, window_size: 10}
        )

      assert client.auto_compaction == {:sliding_window, window_size: 10}
    end
  end
end
