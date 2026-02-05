defmodule Puck.LiveView.Store.ETS do
  @moduledoc """
  ETS-backed `Puck.LiveView.Store` implementation.

  Stores stream session state in one table and append-only chunks in another.
  """

  @behaviour Puck.LiveView.Store

  @default_session_table Puck.LiveView.Store.ETS.Sessions
  @default_chunk_table Puck.LiveView.Store.ETS.Chunks

  def init(opts) do
    session_table = Keyword.get(opts, :session_table, @default_session_table)
    chunk_table = Keyword.get(opts, :chunk_table, @default_chunk_table)
    registry = Keyword.get(opts, :registry, Puck.LiveView.Registry)

    ensure_table(session_table, [:named_table, :public, :set, write_concurrency: true])
    ensure_table(chunk_table, [:named_table, :public, :ordered_set, write_concurrency: true])

    {:ok, %{session_table: session_table, chunk_table: chunk_table, registry: registry}}
  end

  def put_stream(config, stream_id, attrs) do
    session =
      attrs
      |> Map.new()
      |> Map.put_new(:status, :streaming)
      |> Map.put_new(:error, nil)
      |> Map.put(:updated_at, now_ms())

    :ets.insert(config.session_table, {stream_id, session})
    :ok
  end

  def append_chunk(config, stream_id, seq, chunk, snapshot) do
    :ets.insert(config.chunk_table, {{stream_id, seq}, chunk})
    update_session(config, stream_id, snapshot)
  end

  def mark_done(config, stream_id, response, context, snapshot) do
    snapshot =
      snapshot
      |> Map.put(:status, :done)
      |> Map.put(:response, response)
      |> Map.put(:context, context)

    update_session(config, stream_id, snapshot)
  end

  def mark_error(config, stream_id, reason, snapshot) do
    snapshot =
      snapshot
      |> Map.put(:status, :error)
      |> Map.put(:error, reason)

    update_session(config, stream_id, snapshot)
  end

  def mark_cancelled(config, stream_id, snapshot) do
    snapshot = Map.put(snapshot, :status, :cancelled)
    update_session(config, stream_id, snapshot)
  end

  def get_stream(config, stream_id) do
    case :ets.lookup(config.session_table, stream_id) do
      [{^stream_id, session}] -> {:ok, session}
      [] -> :not_found
    end
  rescue
    exception -> {:error, exception}
  end

  def list_chunks(config, stream_id) do
    chunks =
      :ets.match_object(config.chunk_table, {{stream_id, :_}, :_})
      |> Enum.sort_by(fn {{_id, seq}, _chunk} -> seq end)
      |> Enum.map(fn {{_id, seq}, chunk} -> %{seq: seq, chunk: chunk} end)

    {:ok, chunks}
  rescue
    exception -> {:error, exception}
  end

  def delete_stream(config, stream_id) do
    :ets.delete(config.session_table, stream_id)

    :ets.match_delete(config.chunk_table, {{stream_id, :_}, :_})
    :ok
  rescue
    exception -> {:error, exception}
  end

  def sweep(config, opts) do
    now = now_ms()
    max_age = Keyword.get(opts, :max_age, 300_000)

    :ets.tab2list(config.session_table)
    |> Enum.each(fn {stream_id, entry} ->
      cond do
        normalize_status(entry.status) in [:done, :error, :cancelled] and
            now - entry.updated_at > Map.get(entry, :ttl, 60_000) ->
          delete_stream(config, stream_id)

        normalize_status(entry.status) == :streaming and
          now - entry.updated_at > max_age and
            not genserver_alive?(config.registry, stream_id) ->
          delete_stream(config, stream_id)

        true ->
          :ok
      end
    end)

    :ok
  rescue
    exception -> {:error, exception}
  end

  defp update_session(config, stream_id, snapshot) do
    case :ets.lookup(config.session_table, stream_id) do
      [{^stream_id, existing}] ->
        :ets.insert(
          config.session_table,
          {stream_id, existing |> Map.merge(Map.new(snapshot)) |> Map.put(:updated_at, now_ms())}
        )

      [] ->
        :ets.insert(
          config.session_table,
          {stream_id, Map.put(Map.new(snapshot), :updated_at, now_ms())}
        )
    end

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
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    _ -> :unknown
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
