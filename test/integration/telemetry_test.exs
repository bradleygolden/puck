defmodule Puck.Integration.TelemetryTest do
  @moduledoc """
  Integration tests for telemetry events.
  """

  use Puck.IntegrationCase

  setup :check_ollama_available!

  describe "BAML telemetry" do
    @describetag :baml

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml, function: "Classify", path: "test/support/baml_src"},
          hooks: [Puck.Telemetry.Hooks]
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "emits call start and stop events", %{client: client} do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-call-start-#{inspect(ref)}",
        [:puck, :call, :start],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-call-stop-#{inspect(ref)}",
        [:puck, :call, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _response, _ctx} = Puck.call(client, "This is great!", Puck.Context.new())

      assert_receive {:telemetry, [:puck, :call, :start], %{system_time: _}, _metadata}, 5000
      assert_receive {:telemetry, [:puck, :call, :stop], %{duration: duration}, _metadata}, 5000
      assert is_integer(duration)
      assert duration > 0

      :telemetry.detach("test-call-start-#{inspect(ref)}")
      :telemetry.detach("test-call-stop-#{inspect(ref)}")
    end

    @tag timeout: 60_000
    test "emits stream events", %{client: client} do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-stream-start-#{inspect(ref)}",
        [:puck, :stream, :start],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-stream-chunk-#{inspect(ref)}",
        [:puck, :stream, :chunk],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-stream-stop-#{inspect(ref)}",
        [:puck, :stream, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, stream, _ctx} = Puck.stream(client, "This is awesome!", Puck.Context.new())
      _chunks = Enum.to_list(stream)

      assert_receive {:telemetry, [:puck, :stream, :start], _, _}, 5000
      assert_receive {:telemetry, [:puck, :stream, :chunk], _, _}, 5000
      assert_receive {:telemetry, [:puck, :stream, :stop], %{duration: _}, _}, 5000

      :telemetry.detach("test-stream-start-#{inspect(ref)}")
      :telemetry.detach("test-stream-chunk-#{inspect(ref)}")
      :telemetry.detach("test-stream-stop-#{inspect(ref)}")
    end

    @tag timeout: 60_000
    test "metadata includes client info", %{client: client} do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-metadata-#{inspect(ref)}",
        [:puck, :call, :start],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:metadata, metadata})
        end,
        nil
      )

      {:ok, _response, _ctx} = Puck.call(client, "Testing metadata", Puck.Context.new())

      assert_receive {:metadata, metadata}, 5000
      assert Map.has_key?(metadata, :client)

      :telemetry.detach("test-metadata-#{inspect(ref)}")
    end
  end
end
