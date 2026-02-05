if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Puck.LiveView.Sweeper do
    @moduledoc false

    use GenServer

    def start_link(opts) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts) do
      interval = Keyword.get(opts, :sweep_interval, 30_000)
      max_age = Keyword.get(opts, :max_age, 300_000)
      table = Keyword.fetch!(opts, :table)
      registry = Keyword.fetch!(opts, :registry)

      schedule_sweep(interval)

      {:ok,
       %{
         interval: interval,
         max_age: max_age,
         table: table,
         registry: registry
       }}
    end

    @impl true
    def handle_info(:sweep, state) do
      sweep(state)
      schedule_sweep(state.interval)
      {:noreply, state}
    end

    defp sweep(state) do
      now = System.monotonic_time(:millisecond)

      :ets.tab2list(state.table)
      |> Enum.each(fn {stream_id, entry} ->
        cond do
          entry.status in [:done, :error, :cancelled] and
              now - entry.updated_at > entry.ttl ->
            :ets.delete(state.table, stream_id)

          entry.status == :streaming and
            now - entry.updated_at > state.max_age and
              not genserver_alive?(state.registry, stream_id) ->
            :ets.delete(state.table, stream_id)

          true ->
            :ok
        end
      end)
    end

    defp genserver_alive?(registry, stream_id) do
      case Registry.lookup(registry, stream_id) do
        [{_pid, _}] -> true
        [] -> false
      end
    end

    defp schedule_sweep(interval) do
      Process.send_after(self(), :sweep, interval)
    end
  end
end
