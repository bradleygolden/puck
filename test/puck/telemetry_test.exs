if Code.ensure_loaded?(:telemetry) do
  defmodule Puck.TelemetryTest do
    use ExUnit.Case, async: false

    alias Puck.{Client, Context}

    defmodule EventTracker do
      def start do
        if :ets.whereis(:telemetry_events) != :undefined do
          :ets.delete(:telemetry_events)
        end

        :ets.new(:telemetry_events, [:named_table, :public, :bag])
      end

      def record(event, measurements, metadata) do
        :ets.insert(:telemetry_events, {event, measurements, metadata})
      end

      def events do
        :ets.tab2list(:telemetry_events)
      end

      def has_event?(event_name) do
        events() |> Enum.any?(fn {event, _, _} -> event == event_name end)
      end

      def get_event(event_name) do
        events() |> Enum.find(fn {event, _, _} -> event == event_name end)
      end
    end

    describe "automatic telemetry" do
      setup do
        EventTracker.start()

        handler_id = "test-handler-#{:erlang.unique_integer()}"

        :telemetry.attach_many(
          handler_id,
          Puck.Telemetry.event_names(),
          fn event, measurements, metadata, _config ->
            EventTracker.record(event, measurements, metadata)
          end,
          nil
        )

        on_exit(fn ->
          :telemetry.detach(handler_id)
        end)

        :ok
      end

      test "emits call lifecycle events automatically" do
        client = Client.new({Puck.Backends.Mock, response: "Hello!"})
        context = Context.new()

        {:ok, _response, _context} = Puck.call(client, "Hi!", context)

        assert EventTracker.has_event?([:puck, :call, :start])
        assert EventTracker.has_event?([:puck, :backend, :request])
        assert EventTracker.has_event?([:puck, :backend, :response])
        assert EventTracker.has_event?([:puck, :call, :stop])

        # Check that stop event includes duration measurement
        {_event, measurements, _metadata} = EventTracker.get_event([:puck, :call, :stop])
        assert is_integer(measurements.duration)
        assert measurements.duration >= 0
      end

      test "emits call exception event on failure with metadata" do
        client = Client.new({Puck.Backends.Mock, error: :rate_limited})
        context = Context.new()

        {:error, :rate_limited} = Puck.call(client, "Hi!", context)

        assert EventTracker.has_event?([:puck, :call, :start])
        assert EventTracker.has_event?([:puck, :call, :exception])

        # Check exception event has proper measurements and metadata
        {_event, measurements, metadata} = EventTracker.get_event([:puck, :call, :exception])
        assert is_integer(measurements.duration)
        assert metadata.kind == :error
        assert metadata.reason == :rate_limited
        assert is_list(metadata.stacktrace)
      end

      test "emits stream lifecycle events automatically" do
        client = Client.new({Puck.Backends.Mock, stream_chunks: ["Hello", " ", "world"]})
        context = Context.new()

        {:ok, stream, _context} = Puck.stream(client, "Hi!", context)

        assert EventTracker.has_event?([:puck, :stream, :start])
        assert EventTracker.has_event?([:puck, :backend, :request])

        _chunks = Enum.to_list(stream)

        assert EventTracker.has_event?([:puck, :stream, :chunk])
        assert EventTracker.has_event?([:puck, :stream, :stop])

        # Check that stop event includes duration measurement
        {_event, measurements, _metadata} = EventTracker.get_event([:puck, :stream, :stop])
        assert is_integer(measurements.duration)
        assert measurements.duration >= 0
      end

      test "emits stream exception event on hook failure" do
        defmodule FailingStreamHook do
          @behaviour Puck.Hooks

          def on_stream_start(_client, _content, _context) do
            {:error, :stream_blocked}
          end
        end

        client = Client.new({Puck.Backends.Mock, stream_chunks: ["Hello"]})
        context = Context.new()

        {:error, :stream_blocked} = Puck.stream(client, "Hi!", context, hooks: FailingStreamHook)

        assert EventTracker.has_event?([:puck, :stream, :start])
        assert EventTracker.has_event?([:puck, :stream, :exception])

        {_event, measurements, metadata} = EventTracker.get_event([:puck, :stream, :exception])
        assert is_integer(measurements.duration)
        assert metadata.kind == :error
        assert metadata.reason == :stream_blocked
        assert is_list(metadata.stacktrace)
      end
    end

    describe "live_view stream events" do
      setup do
        EventTracker.start()

        handler_id = "test-lv-handler-#{:erlang.unique_integer()}"

        :telemetry.attach_many(
          handler_id,
          Puck.Telemetry.event_names(),
          fn event, measurements, metadata, _config ->
            EventTracker.record(event, measurements, metadata)
          end,
          nil
        )

        start_supervised!({Phoenix.PubSub, name: Puck.TelemetryTest.PubSub})
        start_supervised!(Puck.LiveView)

        on_exit(fn ->
          :telemetry.detach(handler_id)
        end)

        :ok
      end

      defp start_telemetry_stream(opts \\ []) do
        stream_id = "telemetry-test-#{:erlang.unique_integer([:positive])}"
        pubsub = Puck.TelemetryTest.PubSub

        client =
          Keyword.get(opts, :client, Client.new({Puck.Backends.Mock, stream_chunks: ["hi"]}))

        handler = Keyword.get(opts, :handler)

        Phoenix.PubSub.subscribe(pubsub, "puck:stream:#{stream_id}")

        child_opts =
          [
            stream_id: stream_id,
            pubsub: pubsub,
            task_supervisor: Puck.LiveView.TaskSupervisor,
            registry: Puck.LiveView.Registry,
            client: client,
            prompt: "test",
            context: Context.new()
          ] ++ if(handler, do: [handler: handler], else: [])

        {:ok, _pid} =
          DynamicSupervisor.start_child(
            Puck.LiveView.DynamicSupervisor,
            {Puck.LiveView.Stream, child_opts}
          )

        stream_id
      end

      defp start_telemetry_fun_stream(fun, opts \\ []) do
        stream_id = "telemetry-test-#{:erlang.unique_integer([:positive])}"
        pubsub = Puck.TelemetryTest.PubSub
        handler = Keyword.get(opts, :handler)

        Phoenix.PubSub.subscribe(pubsub, "puck:stream:#{stream_id}")

        child_opts =
          [
            stream_id: stream_id,
            pubsub: pubsub,
            task_supervisor: Puck.LiveView.TaskSupervisor,
            registry: Puck.LiveView.Registry,
            fun: fun
          ] ++ if(handler, do: [handler: handler], else: [])

        {:ok, _pid} =
          DynamicSupervisor.start_child(
            Puck.LiveView.DynamicSupervisor,
            {Puck.LiveView.Stream, child_opts}
          )

        stream_id
      end

      test "start and stop events fire on successful stream" do
        id = start_telemetry_stream()

        assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000

        assert EventTracker.has_event?([:puck, :live_view, :stream, :start])
        assert EventTracker.has_event?([:puck, :live_view, :stream, :stop])

        {_, measurements, metadata} = EventTracker.get_event([:puck, :live_view, :stream, :stop])
        assert is_integer(measurements.duration)
        assert metadata.stream_id == id
      end

      test "error event fires on backend failure" do
        client = Client.new({Puck.Backends.Mock, error: :rate_limited})
        id = start_telemetry_stream(client: client)

        assert_receive {:puck_stream, ^id, {:error, :rate_limited}}, 1000

        assert EventTracker.has_event?([:puck, :live_view, :stream, :error])

        {_, _measurements, metadata} =
          EventTracker.get_event([:puck, :live_view, :stream, :error])

        assert metadata.stream_id == id
        assert metadata.reason == :rate_limited
      end

      test "cancel event fires on cancellation" do
        id =
          start_telemetry_fun_stream(fn parent ->
            send(parent, {:stream_chunk, %{type: :content, content: "partial"}})
            Process.sleep(5000)
          end)

        assert_receive {:puck_stream, ^id, {:content, _}}, 1000

        poll_until = fn fun ->
          deadline = System.monotonic_time(:millisecond) + 500

          Stream.repeatedly(fn ->
            if fun.(), do: :ok, else: Process.sleep(1)
          end)
          |> Enum.reduce_while(nil, fn _, _ ->
            if fun.() do
              {:halt, :ok}
            else
              if System.monotonic_time(:millisecond) > deadline, do: raise("poll timed out")
              {:cont, nil}
            end
          end)
        end

        poll_until.(fn -> Registry.lookup(Puck.LiveView.Registry, id) != [] end)
        Puck.LiveView.Stream.cancel(Puck.LiveView.Registry, id)

        assert_receive {:puck_stream, ^id, {:cancelled, "partial"}}, 1000

        assert EventTracker.has_event?([:puck, :live_view, :stream, :cancel])

        {_, _measurements, metadata} =
          EventTracker.get_event([:puck, :live_view, :stream, :cancel])

        assert metadata.stream_id == id
        assert metadata.content == "partial"
      end

      test "handler_error event fires when handler crashes" do
        defmodule TelemetryCrashingHandler do
          @behaviour Puck.LiveView.Handler

          @impl true
          def on_done(_response, _context, _state), do: raise("handler boom")
        end

        id = start_telemetry_stream(handler: {TelemetryCrashingHandler, %{}})

        assert_receive {:puck_stream, ^id, {:done, _, _}}, 1000
        Process.sleep(50)

        assert EventTracker.has_event?([:puck, :live_view, :stream, :handler_error])

        {_, _measurements, metadata} =
          EventTracker.get_event([:puck, :live_view, :stream, :handler_error])

        assert metadata.stream_id == id
        assert metadata.handler == TelemetryCrashingHandler
        assert metadata.callback == :on_done
        assert %RuntimeError{message: "handler boom"} = metadata.reason
      end
    end

    describe "Puck.Telemetry.event_names/0" do
      test "returns all event names" do
        names = Puck.Telemetry.event_names()

        assert [:puck, :call, :start] in names
        assert [:puck, :call, :stop] in names
        assert [:puck, :call, :exception] in names
        assert [:puck, :stream, :start] in names
        assert [:puck, :stream, :chunk] in names
        assert [:puck, :stream, :stop] in names
        assert [:puck, :backend, :request] in names
        assert [:puck, :backend, :response] in names
      end

      test "includes compaction events" do
        names = Puck.Telemetry.event_names()

        assert [:puck, :compaction, :start] in names
        assert [:puck, :compaction, :stop] in names
        assert [:puck, :compaction, :error] in names
      end

      test "includes live_view events" do
        names = Puck.Telemetry.event_names()

        assert [:puck, :live_view, :stream, :start] in names
        assert [:puck, :live_view, :stream, :stop] in names
        assert [:puck, :live_view, :stream, :error] in names
        assert [:puck, :live_view, :stream, :cancel] in names
        assert [:puck, :live_view, :stream, :handler_error] in names
      end
    end

    describe "attach_default_logger/1" do
      test "attaches and detaches successfully" do
        assert :ok = Puck.Telemetry.attach_default_logger()
        assert {:error, :already_exists} = Puck.Telemetry.attach_default_logger()
        assert :ok = Puck.Telemetry.detach_default_logger()
        assert {:error, :not_found} = Puck.Telemetry.detach_default_logger()
      end
    end
  end
end
