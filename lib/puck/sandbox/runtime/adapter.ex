defmodule Puck.Sandbox.Runtime.Adapter do
  @moduledoc """
  Behaviour for runtime sandbox adapters.

  Adapters implement sandbox creation and management. Currently only the Test
  adapter is shipped. Custom adapters can be created by implementing this behaviour.

  ## Required Callbacks

  - `create/1` - Create a new sandbox, return its ID and metadata
  - `exec/3` - Execute a command in the sandbox
  - `terminate/2` - Stop and cleanup the sandbox
  - `status/2` - Get the current sandbox status

  ## Optional Callbacks

  - `get_url/2` - Get URL for an exposed port
  - `read_file/3` - Read file contents from sandbox
  - `write_file/4` - Write file to sandbox
  - `write_files/3` - Write multiple files to sandbox
  - `await_ready/3` - Wait for sandbox to become ready
  - `update/3` - Update sandbox config without destroying
  - `stop/2` - Stop sandbox without destroying (pause)
  - `start/2` - Start a stopped sandbox (resume)

  ## Standard Config Fields

  These config fields should work consistently across adapters:

  - `:image` - Container image (e.g., `"node:22-slim"`)
  - `:memory_mb` - Memory limit in MB (e.g., `512`)
  - `:env` - Environment variables as `[{name, value}]`
  - `:ports` - Ports to expose (format varies by adapter)
  - `:mounts` - Volume/file mounts (format varies by adapter)
  - `:proxy` - Enable proxy mode for controlled network access

  Adapters may support additional adapter-specific config fields.

  ## Example

      defmodule MyAdapter do
        @behaviour Puck.Sandbox.Runtime.Adapter

        @impl true
        def create(config) do
          # Create sandbox, return {:ok, sandbox_id, metadata} or {:error, reason}
        end

        @impl true
        def exec(sandbox_id, command, opts) do
          # Execute command, return {:ok, %ExecResult{}} or {:error, reason}
        end

        @impl true
        def terminate(sandbox_id, opts) do
          # Cleanup sandbox, return :ok or {:error, reason}
        end

        @impl true
        def status(sandbox_id, opts) do
          # Return :running | :stopped | :terminated | :unknown
        end
      end
  """

  alias Puck.Sandbox.Runtime.ExecResult

  @type config :: map()
  @type sandbox_id :: String.t()
  @type metadata :: map()
  @type command :: String.t()
  @type opts :: keyword()

  @callback create(config()) :: {:ok, sandbox_id(), metadata()} | {:error, term()}
  @callback exec(sandbox_id(), command(), opts()) :: {:ok, ExecResult.t()} | {:error, term()}
  @callback terminate(sandbox_id(), opts()) :: :ok | {:error, term()}
  @callback status(sandbox_id(), opts()) :: :running | :stopped | :terminated | :unknown
  @callback get_url(sandbox_id(), port :: integer()) :: {:ok, String.t()} | {:error, term()}
  @callback read_file(sandbox_id(), path :: String.t(), opts()) ::
              {:ok, binary()} | {:error, term()}
  @callback write_file(sandbox_id(), path :: String.t(), content :: binary(), opts()) ::
              :ok | {:error, term()}
  @callback write_files(sandbox_id(), files :: [{String.t(), binary()}], opts()) ::
              :ok | {:error, term()}
  @callback await_ready(sandbox_id(), metadata(), opts()) :: {:ok, map()} | {:error, term()}
  @callback update(sandbox_id(), config(), opts()) :: {:ok, map()} | {:error, term()}
  @callback stop(sandbox_id(), opts()) :: {:ok, map()} | {:error, term()}
  @callback start(sandbox_id(), opts()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks [
    get_url: 2,
    read_file: 3,
    write_file: 4,
    write_files: 3,
    await_ready: 3,
    update: 3,
    stop: 2,
    start: 2
  ]
end
