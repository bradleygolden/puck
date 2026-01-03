defmodule Puck.Sandbox.FileOps do
  @moduledoc false

  alias Puck.Sandbox.ExecResult

  @doc """
  Reads a file from a sandbox using base64 encoding.

  Requires an exec function that takes (command, opts) and returns
  `{:ok, %ExecResult{}}` or `{:error, term()}`.
  """
  @spec read_file(
          (String.t(), keyword() -> {:ok, ExecResult.t()} | {:error, term()}),
          String.t(),
          keyword()
        ) ::
          {:ok, binary()} | {:error, term()}
  def read_file(exec_fn, path, opts) do
    case exec_fn.("base64 -w0 '#{escape_path(path)}'", opts) do
      {:ok, %{exit_code: 0, stdout: encoded}} -> decode_base64(encoded)
      {:ok, result} -> extract_error(result)
      error -> error
    end
  end

  defp decode_base64(encoded) do
    case Base.decode64(String.trim(encoded)) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :invalid_base64}
    end
  end

  defp extract_error(result, default \\ :file_not_found)
  defp extract_error(%{stderr: err}, _) when is_binary(err) and err != "", do: {:error, err}
  defp extract_error(%{exit_code: code}, default), do: {:error, default || {:exit_code, code}}

  @doc """
  Writes a file to a sandbox using base64 encoding.

  Requires an exec function that takes (command, opts) and returns
  `{:ok, %ExecResult{}}` or `{:error, term()}`.
  """
  @spec write_file(
          (String.t(), keyword() -> {:ok, ExecResult.t()} | {:error, term()}),
          String.t(),
          binary(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def write_file(exec_fn, path, content, opts) do
    encoded = Base.encode64(content)
    escaped_path = escape_path(path)

    cmd =
      "mkdir -p \"$(dirname '#{escaped_path}')\" && echo '#{encoded}' | base64 -d > '#{escaped_path}'"

    case exec_fn.(cmd, opts) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, result} -> extract_error(result, nil)
      error -> error
    end
  end

  @doc """
  Writes multiple files to a sandbox.

  Writes files sequentially, stopping on first error.
  """
  @spec write_files(
          (String.t(), keyword() -> {:ok, ExecResult.t()} | {:error, term()}),
          [{String.t(), binary()}],
          keyword()
        ) ::
          :ok | {:error, term()}
  def write_files(exec_fn, files, opts) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case write_file(exec_fn, path, content, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Escapes a file path for safe shell usage.
  """
  @spec escape_path(String.t()) :: String.t()
  def escape_path(path) do
    String.replace(path, "'", "'\\''")
  end
end
