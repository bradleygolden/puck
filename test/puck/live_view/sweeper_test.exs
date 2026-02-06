defmodule Puck.LiveView.SweeperTest do
  use ExUnit.Case, async: true

  alias Puck.LiveView.Store.ETS, as: ETSStore

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp init_store do
    registry = unique_name("registry")
    start_supervised!({Registry, keys: :unique, name: registry})
    {:ok, config} = ETSStore.init(session_table: unique_name("sessions"), registry: registry)
    config
  end

  test "sweeps expired entries when :sweep message arrives" do
    config = init_store()
    :ok = ETSStore.put_stream(config, "old-stream", %{status: :done, content: "x"})
    Process.sleep(10)

    sweeper =
      start_supervised!(
        {Puck.LiveView.Sweeper,
         name: unique_name("sweeper"),
         store: {ETSStore, config},
         sweep_interval: :timer.minutes(10),
         retention_ms: 1}
      )

    send(sweeper, :sweep)
    Process.sleep(50)

    assert :not_found = ETSStore.get_stream(config, "old-stream")
  end

  test "emits telemetry event when sweep fails" do
    defmodule FailingSweepStore do
      @behaviour Puck.LiveView.Store

      def init(_opts), do: {:ok, %{}}
      def put_stream(_c, _id, _s), do: :ok
      def get_stream(_c, _id), do: :not_found
      def delete_stream(_c, _id), do: :ok
      def sweep(_c, _opts), do: {:error, :kaboom}
    end

    test_pid = self()

    :telemetry.attach(
      "sweeper-test-handler",
      [:puck, :live_view, :sweeper, :error],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    sweeper =
      start_supervised!(
        {Puck.LiveView.Sweeper,
         name: unique_name("sweeper"),
         store: {FailingSweepStore, %{}},
         sweep_interval: :timer.minutes(10),
         retention_ms: 300_000}
      )

    send(sweeper, :sweep)

    assert_receive {:telemetry, [:puck, :live_view, :sweeper, :error], %{}, %{reason: :kaboom}},
                   1000

    :telemetry.detach("sweeper-test-handler")
  end

  test "reschedules sweep after handling" do
    config = init_store()

    sweeper =
      start_supervised!(
        {Puck.LiveView.Sweeper,
         name: unique_name("sweeper"),
         store: {ETSStore, config},
         sweep_interval: 50,
         retention_ms: 300_000}
      )

    ref = Process.monitor(sweeper)
    Process.sleep(120)
    refute_receive {:DOWN, ^ref, :process, _, _}, 0
  end
end
