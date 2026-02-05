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
      store = Keyword.fetch!(opts, :store)

      schedule_sweep(interval)

      {:ok,
       %{
         interval: interval,
         max_age: max_age,
         store: store
       }}
    end

    @impl true
    def handle_info(:sweep, state) do
      {store_module, store_config} = state.store
      _ = store_module.sweep(store_config, max_age: state.max_age)
      schedule_sweep(state.interval)
      {:noreply, state}
    end

    defp schedule_sweep(interval) do
      Process.send_after(self(), :sweep, interval)
    end
  end
end
