defmodule Puck.LiveView.Store.ETS do
  @moduledoc """
  ETS-backed `Puck.LiveView.Store` implementation.
  """

  @behaviour Puck.LiveView.Store

  @default_session_table Puck.LiveView.Store.ETS.Sessions

  def init(opts) do
    session_table = Keyword.get(opts, :session_table, @default_session_table)
    registry = Keyword.get(opts, :registry, Puck.LiveView.Registry)

    ensure_table(session_table, [:named_table, :public, :set, write_concurrency: true])

    {:ok, %{session_table: session_table, registry: registry}}
  end

  def put_stream(config, stream_id, snapshot) do
    session = snapshot |> Map.new() |> Map.put(:updated_at, now_ms())
    :ets.insert(config.session_table, {stream_id, session})
    :ok
  end

  def get_stream(config, stream_id) do
    case :ets.lookup(config.session_table, stream_id) do
      [{^stream_id, session}] -> {:ok, session}
      [] -> :not_found
    end
  rescue
    exception -> {:error, exception}
  end

  def delete_stream(config, stream_id) do
    :ets.delete(config.session_table, stream_id)
    :ok
  rescue
    exception -> {:error, exception}
  end

  def sweep(config, opts) do
    now = now_ms()
    retention_ms = Keyword.get(opts, :retention_ms, 300_000)

    :ets.tab2list(config.session_table)
    |> Enum.each(fn {stream_id, entry} ->
      if now - entry.updated_at > retention_ms and
           not genserver_alive?(config.registry, stream_id) do
        delete_stream(config, stream_id)
      end
    end)

    :ok
  rescue
    exception -> {:error, exception}
  end

  defp ensure_table(table, opts) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, opts)
    end
  end

  defp genserver_alive?(registry, stream_id) do
    case Registry.lookup(registry, stream_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
