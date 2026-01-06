if Code.ensure_loaded?(Req) do
  defmodule Puck.Sandbox.Runtime.HealthPoller do
    @moduledoc false

    use GenServer

    @default_timeout 60_000
    @default_interval 2_000

    @doc """
    Polls a health endpoint until it returns HTTP 200 or times out.

    ## Options

      * `:timeout` - Maximum time to wait in milliseconds (default: 60_000)
      * `:interval` - Time between poll attempts in milliseconds (default: 2_000)

    ## Returns

      * `{:ok, body}` - Health check succeeded, returns response body
      * `{:error, :timeout}` - Timed out waiting for health check
      * `{:error, {:poller_crashed, reason}}` - Poller process crashed
    """
    @spec poll(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
    def poll(url, opts \\ []) do
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      interval = Keyword.get(opts, :interval, @default_interval)
      req_opts = Keyword.take(opts, [:plug, :retry])

      {:ok, pid} = GenServer.start(__MODULE__, {url, interval, req_opts, self()})
      ref = Process.monitor(pid)

      receive do
        {:health_ready, ^pid, body} ->
          Process.demonitor(ref, [:flush])
          {:ok, body}

        {:health_error, ^pid, reason} ->
          Process.demonitor(ref, [:flush])
          {:error, reason}

        {:DOWN, ^ref, :process, ^pid, reason} ->
          {:error, {:poller_crashed, reason}}
      after
        timeout ->
          GenServer.stop(pid, :normal)
          {:error, :timeout}
      end
    end

    @impl true
    def init({url, interval, req_opts, caller}) do
      send(self(), :poll)
      {:ok, %{url: url, interval: interval, req_opts: req_opts, caller: caller}}
    end

    @impl true
    def handle_info(:poll, state) do
      case Req.get(state.url, state.req_opts) do
        {:ok, %{status: 200, body: body}} ->
          send(state.caller, {:health_ready, self(), body})
          {:stop, :normal, state}

        _ ->
          Process.send_after(self(), :poll, state.interval)
          {:noreply, state}
      end
    end
  end
end
