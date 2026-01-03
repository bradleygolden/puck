defmodule Puck.Sandbox.Adapter do
  @moduledoc """
  Behaviour for sandbox adapters.

  Adapters implement the actual sandbox creation and management for different
  backends (Docker, Fly Machines, etc.).

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
        @behaviour Puck.Sandbox.Adapter

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

  alias Puck.Sandbox.ExecResult

  @type config :: map()
  @type sandbox_id :: String.t()
  @type metadata :: map()
  @type command :: String.t()
  @type opts :: keyword()

  @doc """
  Creates a new sandbox with the given configuration.

  ## Standard Config Fields

  - `:image` - Container image (e.g., `"node:22-slim"`)
  - `:memory_mb` - Memory limit in MB
  - `:env` - Environment variables as `[{name, value}]`
  - `:ports` - Ports to expose
  - `:mounts` - Volume/file mounts
  - `:proxy` - Enable proxy mode for network access

  Returns `{:ok, sandbox_id, metadata}` on success or `{:error, reason}` on failure.
  The metadata map contains adapter-specific information (e.g., `private_ip` for Fly,
  `port_map` for Docker).
  """
  @callback create(config()) :: {:ok, sandbox_id(), metadata()} | {:error, term()}

  @doc """
  Executes a command in the sandbox.

  Options may include:
  - `:timeout` - Command timeout in milliseconds
  - `:workdir` - Working directory for the command

  Returns `{:ok, %ExecResult{}}` on success or `{:error, reason}` on failure.
  """
  @callback exec(sandbox_id(), command(), opts()) :: {:ok, ExecResult.t()} | {:error, term()}

  @doc """
  Terminates and cleans up the sandbox.

  Options may include adapter-specific credentials (e.g., `:api_token` for Fly).

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback terminate(sandbox_id(), opts()) :: :ok | {:error, term()}

  @doc """
  Gets the current status of the sandbox.

  Options may include adapter-specific credentials (e.g., `:api_token` for Fly).
  """
  @callback status(sandbox_id(), opts()) :: :running | :stopped | :terminated | :unknown

  @doc """
  Gets the URL for an exposed port on the sandbox.

  Optional callback - not all adapters support exposed ports.
  """
  @callback get_url(sandbox_id(), port :: integer()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Reads file contents from the sandbox.
  """
  @callback read_file(sandbox_id(), path :: String.t(), opts()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Writes a file to the sandbox.
  """
  @callback write_file(sandbox_id(), path :: String.t(), content :: binary(), opts()) ::
              :ok | {:error, term()}

  @doc """
  Writes multiple files to the sandbox.
  """
  @callback write_files(sandbox_id(), files :: [{String.t(), binary()}], opts()) ::
              :ok | {:error, term()}

  @doc """
  Waits for sandbox to become ready.

  Each adapter can implement its own readiness logic. For example:
  - Fly adapter uses native machine wait API + health poll
  - Docker adapter polls health endpoint
  - Test adapter returns immediately

  The metadata parameter contains adapter-specific information from create/1
  (e.g., private_ip for Fly adapter to enable fast health checks).

  ## Options
    * `:port` - health check port (default: 4001)
    * `:timeout` - max wait time in ms (default: 60_000)
    * `:interval` - poll interval in ms (default: 2_000)
  """
  @callback await_ready(sandbox_id(), metadata(), opts()) :: {:ok, map()} | {:error, term()}

  @doc """
  Updates a sandbox's configuration without destroying it.

  This is useful for updating the image or other config while preserving
  state like volume attachments. Not all adapters support this operation.

  ## Options
    * `:image` - Container image
    * `:memory_mb` - Memory limit in MB
    * `:cpu` - CPU count
    * `:env` - Environment variables
    * `:ports` - Ports to expose
  """
  @callback update(sandbox_id(), config(), opts()) :: {:ok, map()} | {:error, term()}

  @doc """
  Stops a sandbox without destroying it.

  Useful for suspend/resume patterns to save costs. The sandbox can be
  restarted with `start/2`.
  """
  @callback stop(sandbox_id(), opts()) :: {:ok, map()} | {:error, term()}

  @doc """
  Starts a stopped sandbox.
  """
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
