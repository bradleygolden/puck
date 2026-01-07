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

    describe "Puck.Telemetry.Hooks" do
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

      test "emits call lifecycle events with duration" do
        client =
          Client.new({Puck.Backends.Mock, response: "Hello!"}, hooks: Puck.Telemetry.Hooks)

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
        client =
          Client.new({Puck.Backends.Mock, error: :rate_limited}, hooks: Puck.Telemetry.Hooks)

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

      test "emits stream lifecycle events with duration" do
        client =
          Client.new({Puck.Backends.Mock, stream_chunks: ["Hello", " ", "world"]},
            hooks: Puck.Telemetry.Hooks
          )

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
