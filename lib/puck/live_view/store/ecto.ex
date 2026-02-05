if Code.ensure_loaded?(Ecto.Repo) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Puck.LiveView.Store.Ecto do
    @moduledoc """
    Reference Ecto implementation for `Puck.LiveView.Store`.

    Expects two tables:

    - `stream_sessions`: one row per stream, keyed by `stream_id`
    - `stream_chunks`: append-only rows keyed by `stream_id` + `seq`

    Required columns:

    - `stream_sessions`: `stream_id`, `status`, `payload`, `updated_at`, `inserted_at`
    - `stream_chunks`: `stream_id`, `seq`, `chunk`, `inserted_at`
    """

    @behaviour Puck.LiveView.Store

    import Ecto.Query

    def init(opts) do
      repo = Keyword.fetch!(opts, :repo)
      sessions_table = Keyword.get(opts, :sessions_table, "stream_sessions")
      chunks_table = Keyword.get(opts, :chunks_table, "stream_chunks")

      {:ok, %{repo: repo, sessions_table: sessions_table, chunks_table: chunks_table}}
    rescue
      exception -> {:error, exception}
    end

    def put_stream(config, stream_id, attrs) do
      row = %{
        stream_id: stream_id,
        status: "streaming",
        payload: encode_term(attrs),
        inserted_at: now_naive(),
        updated_at: now_naive()
      }

      {_, _} =
        config.repo.insert_all(
          config.sessions_table,
          [row],
          on_conflict: [
            set: [status: row.status, payload: row.payload, updated_at: row.updated_at]
          ],
          conflict_target: [:stream_id]
        )

      :ok
    rescue
      exception -> {:error, exception}
    end

    def append_chunk(config, stream_id, seq, chunk, snapshot) do
      chunk_row = %{
        stream_id: stream_id,
        seq: seq,
        chunk: encode_term(chunk),
        inserted_at: now_naive()
      }

      {_, _} =
        config.repo.insert_all(
          config.chunks_table,
          [chunk_row],
          on_conflict: :nothing,
          conflict_target: [:stream_id, :seq]
        )

      upsert_session(config, stream_id, :streaming, snapshot)
    rescue
      exception -> {:error, exception}
    end

    def mark_done(config, stream_id, response, context, snapshot) do
      payload =
        snapshot
        |> Map.put(:response, response)
        |> Map.put(:context, context)

      upsert_session(config, stream_id, :done, payload)
    end

    def mark_error(config, stream_id, reason, snapshot) do
      payload =
        snapshot
        |> Map.put(:error, reason)

      upsert_session(config, stream_id, :error, payload)
    end

    def mark_cancelled(config, stream_id, snapshot) do
      upsert_session(config, stream_id, :cancelled, snapshot)
    end

    def get_stream(config, stream_id) do
      query =
        from(s in config.sessions_table,
          where: field(s, :stream_id) == ^stream_id,
          select: %{
            stream_id: field(s, :stream_id),
            status: field(s, :status),
            payload: field(s, :payload)
          }
        )

      case config.repo.one(query) do
        nil ->
          :not_found

        row ->
          payload = decode_term(row.payload)
          {:ok, Map.put(Map.new(payload), :status, normalize_status(row.status))}
      end
    rescue
      exception -> {:error, exception}
    end

    def list_chunks(config, stream_id) do
      query =
        from(c in config.chunks_table,
          where: field(c, :stream_id) == ^stream_id,
          order_by: [asc: field(c, :seq)],
          select: %{seq: field(c, :seq), chunk: field(c, :chunk)}
        )

      chunks =
        config.repo.all(query)
        |> Enum.map(fn row ->
          decode_term(row.chunk)
          |> then(fn chunk -> %{seq: row.seq, chunk: chunk} end)
        end)

      {:ok, chunks}
    rescue
      exception -> {:error, exception}
    end

    def delete_stream(config, stream_id) do
      _ =
        from(c in config.chunks_table, where: field(c, :stream_id) == ^stream_id)
        |> config.repo.delete_all()

      _ =
        from(s in config.sessions_table, where: field(s, :stream_id) == ^stream_id)
        |> config.repo.delete_all()

      :ok
    rescue
      exception -> {:error, exception}
    end

    defp upsert_session(config, stream_id, status, payload) do
      row = %{
        stream_id: stream_id,
        status: Atom.to_string(status),
        payload: encode_term(payload),
        inserted_at: now_naive(),
        updated_at: now_naive()
      }

      {_, _} =
        config.repo.insert_all(
          config.sessions_table,
          [row],
          on_conflict: [
            set: [status: row.status, payload: row.payload, updated_at: row.updated_at]
          ],
          conflict_target: [:stream_id]
        )

      :ok
    rescue
      exception -> {:error, exception}
    end

    def sweep(_config, _opts), do: :ok

    defp encode_term(value), do: :erlang.term_to_binary(value)
    defp decode_term(value), do: :erlang.binary_to_term(value)
    defp now_naive, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    defp normalize_status(status) when is_atom(status), do: status

    defp normalize_status(status) when is_binary(status) do
      String.to_existing_atom(status)
    rescue
      _ -> :unknown
    end
  end
end
