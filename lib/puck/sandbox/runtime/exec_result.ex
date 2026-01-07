defmodule Puck.Sandbox.Runtime.ExecResult do
  @moduledoc """
  Struct representing the result of executing a command in a sandbox.

  ## Fields

  - `stdout` - Standard output from the command
  - `stderr` - Standard error from the command
  - `exit_code` - Exit code of the command (0 typically means success)

  ## Examples

      %Puck.Sandbox.Runtime.ExecResult{
        stdout: "hello world",
        stderr: "",
        exit_code: 0
      }

  """

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer()
        }

  defstruct stdout: "", stderr: "", exit_code: 0

  @doc """
  Creates a new ExecResult with the given attributes.

  ## Examples

      iex> Puck.Sandbox.Runtime.ExecResult.new(stdout: "hello", exit_code: 0)
      %Puck.Sandbox.Runtime.ExecResult{stdout: "hello", stderr: "", exit_code: 0}

  """
  def new(attrs \\ []) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Returns true if the command executed successfully (exit code 0).

  ## Examples

      iex> result = Puck.Sandbox.Runtime.ExecResult.new(exit_code: 0)
      iex> Puck.Sandbox.Runtime.ExecResult.success?(result)
      true

      iex> result = Puck.Sandbox.Runtime.ExecResult.new(exit_code: 1)
      iex> Puck.Sandbox.Runtime.ExecResult.success?(result)
      false

  """
  def success?(%__MODULE__{exit_code: 0}), do: true
  def success?(%__MODULE__{}), do: false

  @doc """
  Returns the output (stdout if present, otherwise stderr).

  Useful when you just want the command output regardless of stream.

  ## Examples

      iex> result = Puck.Sandbox.Runtime.ExecResult.new(stdout: "hello", exit_code: 0)
      iex> Puck.Sandbox.Runtime.ExecResult.output(result)
      "hello"

      iex> result = Puck.Sandbox.Runtime.ExecResult.new(stderr: "error message", exit_code: 1)
      iex> Puck.Sandbox.Runtime.ExecResult.output(result)
      "error message"

  """
  def output(%__MODULE__{stdout: stdout}) when stdout != "", do: stdout
  def output(%__MODULE__{stderr: stderr}), do: stderr
end
