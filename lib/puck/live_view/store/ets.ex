defmodule Puck.LiveView.Store.ETS do
  @moduledoc """
  ETS-backed `Puck.LiveView.Store` implementation.

  Use this default for single-node deployments. Snapshots are local to the
  current node. For multi-node deployments, implement a custom
  `Puck.LiveView.Store`.
  """

  @behaviour Puck.LiveView.Store

  @default_session_table Puck.LiveView.Store.ETS.Sessions

  @doc """
  Initializes the ETS store.

  ## Options

    - `:session_table` - ETS table name (default: `Puck.LiveView.Store.ETS.Sessions`)
    - `:registry` - Registry name for checking live GenServers during sweep
      (default: `Puck.LiveView.Registry`)

  """
  def init(opts) do
    session_table = Keyword.get(opts, :session_table, @default_session_table)
    registry = Keyword.get(opts, :registry, Puck.LiveView.Registry)

    ensure_table(session_table, [:named_table, :public, :set, write_concurrency: true])

    {:ok, %{session_table: session_table, registry: registry}}
  end

  @doc false
  def put_stream(config, stream_id, snapshot) do
    session = Map.put(snapshot, :updated_at, now_ms())
    :ets.insert(config.session_table, {stream_id, session})
    :ok
  end

  @doc false
  def get_stream(config, stream_id) do
    case :ets.lookup(config.session_table, stream_id) do
      [{^stream_id, session}] -> {:ok, session}
      [] -> :not_found
    end
  rescue
    e in ArgumentError -> {:error, e}
  end

  @doc false
  def delete_stream(config, stream_id) do
    :ets.delete(config.session_table, stream_id)
    :ok
  end

  @doc false
  def sweep(config, opts) do
    now = now_ms()
    retention_ms = Keyword.get(opts, :retention_ms, 300_000)

    Enum.each(:ets.tab2list(config.session_table), fn {stream_id, entry} ->
      if now - entry.updated_at > retention_ms and
           not genserver_alive?(config.registry, stream_id) do
        delete_stream(config, stream_id)
      end
    end)

    :ok
  rescue
    e in ArgumentError -> {:error, e}
  end

  defp ensure_table(table, opts) do
    :ets.new(table, opts)
  rescue
    ArgumentError -> :ok
  end

  defp genserver_alive?(registry, stream_id) do
    case Registry.lookup(registry, stream_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  rescue
    ArgumentError -> true
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
