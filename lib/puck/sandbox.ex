defmodule Puck.Sandbox do
  @moduledoc """
  Sandbox management for isolated code execution.

  Puck.Sandbox provides a struct-based API for creating and managing
  sandboxed execution environments. Inspired by E2B's simplicity and Modal's
  `from_id` pattern.

  Note: Sandbox functionality is a work in progress. Currently only the Test
  adapter is shipped. Docker and Fly adapters are planned but not yet implemented.

  ## Usage

      alias Puck.Sandbox
      alias Puck.Sandbox.Adapters.Test

      # Create a sandbox
      {:ok, sandbox} = Sandbox.create({Test, image: "node:22-slim"})

      # Execute commands
      {:ok, result} = Sandbox.exec(sandbox, "node --version")
      IO.puts(result.stdout)

      # Cleanup
      :ok = Sandbox.terminate(sandbox)

  ## Adapters

  Puck.Sandbox uses an adapter pattern for different backends:

  - `Puck.Sandbox.Adapters.Test` - In-memory testing adapter (shipped)
  - Docker adapter - Planned
  - Fly.io Machines adapter - Planned

  Custom adapters can be created by implementing the `Puck.Sandbox.Adapter` behaviour.
  """

  alias Puck.Sandbox.HealthPoller
  alias Puck.Sandbox.Instance
  alias Puck.Sandbox.NDJSON
  alias Puck.Sandbox.Template

  @type backend :: {module(), map() | keyword()}
  @type text_block :: %{type: :text, text: String.t()}
  @type file_block ::
          %{type: :file, media_type: String.t(), data: String.t()}
          | %{type: :file, media_type: String.t(), text: String.t()}
  @type prompt_content :: String.t() | [text_block() | file_block()]

  @doc """
  Creates a new sandbox using the specified adapter and configuration.

  ## Examples

      {:ok, sandbox} = Puck.Sandbox.create({Docker, image: "node:22-slim"})

      {:ok, sandbox} = Puck.Sandbox.create({Docker, %{
        image: "node:22-slim",
        workdir: "/workspace",
        memory_mb: 2048
      }})
  """
  @spec create(backend()) :: {:ok, Instance.t()} | {:error, term()}
  def create({adapter_module, config}) when is_atom(adapter_module) do
    config_map = normalize_config(config)

    with {:ok, sandbox_id, metadata} <- adapter_module.create(config_map) do
      sandbox =
        Instance.new(
          id: sandbox_id,
          adapter: adapter_module,
          config: config_map,
          metadata: metadata
        )

      {:ok, sandbox}
    end
  end

  @doc """
  Creates a new sandbox from a template with optional config overrides.

  ## Examples

      template = Template.new({Docker, %{image: "python:3.12", memory_mb: 512}})

      # Create from template
      {:ok, sandbox} = Puck.Sandbox.create(template)

      # With overrides
      {:ok, sandbox} = Puck.Sandbox.create(template, memory_mb: 1024)
  """
  @spec create(Template.t(), map() | keyword()) :: {:ok, Instance.t()} | {:error, term()}
  def create(%Template{} = template, overrides \\ %{}) do
    backend = Template.to_backend(template, overrides)
    create(backend)
  end

  @doc """
  Reconstructs a sandbox struct from an existing sandbox ID.

  Useful for resuming work with a container that was created elsewhere
  or persisted across sessions. Inspired by Modal's `Sandbox.from_id()`.

  ## Examples

      sandbox = Puck.Sandbox.from_id(Docker, "puck-sandbox-abc123")
      {:ok, result} = Puck.Sandbox.exec(sandbox, "echo 'still here'")
  """
  @spec from_id(module(), String.t(), map(), map()) :: Instance.t()
  def from_id(adapter_module, sandbox_id, config \\ %{}, metadata \\ %{}) do
    Instance.new(
      id: sandbox_id,
      adapter: adapter_module,
      config: config,
      metadata: metadata
    )
  end

  @doc """
  Executes a command in the sandbox.

  ## Options

  - `:timeout` - Command timeout in milliseconds (default: 30_000)
  - `:workdir` - Working directory for the command

  ## Examples

      {:ok, result} = Puck.Sandbox.exec(sandbox, "node --version")
      IO.puts(result.stdout)

      # With timeout
      {:ok, result} = Puck.Sandbox.exec(sandbox, "npm install", timeout: 120_000)

      # File operations via exec
      {:ok, _} = Puck.Sandbox.exec(sandbox, "echo 'hello' > file.txt")
      {:ok, result} = Puck.Sandbox.exec(sandbox, "cat file.txt")
  """
  @spec exec(Instance.t(), String.t(), keyword()) ::
          {:ok, Puck.Sandbox.ExecResult.t()} | {:error, term()}
  def exec(%Instance{} = sandbox, command, opts \\ []) do
    sandbox.adapter.exec(sandbox.id, command, merge_opts(sandbox.config, opts))
  end

  @doc """
  Terminates and cleans up the sandbox.

  ## Examples

      :ok = Puck.Sandbox.terminate(sandbox)
  """
  @spec terminate(Instance.t()) :: :ok | {:error, term()}
  def terminate(%Instance{} = sandbox) do
    sandbox.adapter.terminate(sandbox.id, merge_opts(sandbox.config, []))
  end

  @doc """
  Gets the current status of the sandbox.

  ## Examples

      :running = Puck.Sandbox.status(sandbox)
  """
  @spec status(Instance.t()) :: :running | :stopped | :terminated | :unknown
  def status(%Instance{} = sandbox) do
    sandbox.adapter.status(sandbox.id, merge_opts(sandbox.config, []))
  end

  @doc """
  Gets the URL for an exposed port on the sandbox.

  Useful for sandboxes running servers. This is an optional adapter callback -
  returns `{:error, :not_implemented}` if the adapter doesn't support it.

  ## Examples

      {:ok, url} = Puck.Sandbox.get_url(sandbox, 4000)
      # => "http://puck-sandbox-abc123:4000"
  """
  @spec get_url(Instance.t(), integer()) :: {:ok, String.t()} | {:error, term()}
  def get_url(%Instance{metadata: metadata, adapter: adapter, id: id}, port) do
    resolved_port = get_in(metadata, [:port_map, port]) || port
    call_optional(adapter, :get_url, [id, resolved_port])
  end

  @doc """
  Reads a file from the sandbox.

  ## Examples

      {:ok, content} = Puck.Sandbox.read_file(sandbox, "/app/code.py")
  """
  @spec read_file(Instance.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(%Instance{adapter: adapter, id: id, config: config}, path, opts \\ []) do
    call_optional(adapter, :read_file, [id, path, merge_opts(config, opts)])
  end

  @doc """
  Writes a file to the sandbox.

  ## Examples

      :ok = Puck.Sandbox.write_file(sandbox, "/app/code.py", "print('hello')")
  """
  @spec write_file(Instance.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(%Instance{adapter: adapter, id: id, config: config}, path, content, opts \\ []) do
    call_optional(adapter, :write_file, [id, path, content, merge_opts(config, opts)])
  end

  @doc """
  Writes multiple files to the sandbox.

  ## Examples

      :ok = Puck.Sandbox.write_files(sandbox, [
        {"/app/main.py", "import lib"},
        {"/app/lib.py", "def foo(): pass"}
      ])
  """
  @spec write_files(Instance.t(), [{String.t(), binary()}], keyword()) :: :ok | {:error, term()}
  def write_files(
        %Instance{adapter: adapter, id: id, config: config} = sandbox,
        files,
        opts \\ []
      ) do
    merged_opts = merge_opts(config, opts)

    call_optional(adapter, :write_files, [id, files, merged_opts], fn ->
      write_files_sequentially(sandbox, files, merged_opts)
    end)
  end

  defp write_files_sequentially(sandbox, files, opts) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case write_file(sandbox, path, content, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Waits for sandbox to become ready.

  Delegates to the adapter's `await_ready/3` if implemented.
  Falls back to polling the health endpoint if not.

  ## Options

  - `:port` - health check port (default: 4001)
  - `:timeout` - max wait time in ms (default: 60_000)
  - `:interval` - poll interval in ms (default: 2_000)

  ## Examples

      {:ok, metadata} = Puck.Sandbox.await_ready(sandbox)
      {:ok, metadata} = Puck.Sandbox.await_ready(sandbox, timeout: 30_000)
  """
  @spec await_ready(Instance.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_ready(
        %Instance{adapter: adapter, id: id, config: config, metadata: metadata} = sandbox,
        opts \\ []
      ) do
    merged_opts = merge_opts(config, opts)

    call_optional(adapter, :await_ready, [id, metadata, merged_opts], fn ->
      poll_health_endpoint(sandbox, merged_opts)
    end)
  end

  @doc """
  Stops a sandbox without destroying it.

  Useful for suspend/resume patterns. The sandbox can be restarted with `start/1`.
  Returns `{:error, :not_implemented}` if the adapter doesn't support it.

  ## Examples

      {:ok, _} = Puck.Sandbox.stop(sandbox)
  """
  @spec stop(Instance.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stop(%Instance{adapter: adapter, id: id, config: config}, opts \\ []) do
    call_optional(adapter, :stop, [id, merge_opts(config, opts)])
  end

  @doc """
  Starts a stopped sandbox.

  Returns `{:error, :not_implemented}` if the adapter doesn't support it.

  ## Examples

      {:ok, _} = Puck.Sandbox.start(sandbox)
  """
  @spec start(Instance.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(%Instance{adapter: adapter, id: id, config: config}, opts \\ []) do
    call_optional(adapter, :start, [id, merge_opts(config, opts)])
  end

  @doc """
  Updates a sandbox's configuration without destroying it.

  This preserves state like volume attachments. Returns `{:error, :not_implemented}`
  if the adapter doesn't support it.

  ## Examples

      {:ok, _} = Puck.Sandbox.update(sandbox, %{image: "node:23-slim"})
  """
  @spec update(Instance.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(%Instance{adapter: adapter, id: id, config: sandbox_config}, config, opts \\ []) do
    call_optional(adapter, :update, [id, config, merge_opts(sandbox_config, opts)])
  end

  defp poll_health_endpoint(sandbox, opts) do
    port = Keyword.get(opts, :port, 4001)

    case get_url(sandbox, port) do
      {:ok, url} -> HealthPoller.poll("#{url}/health", opts)
      {:error, _} = error -> error
    end
  end

  if Code.ensure_loaded?(Req) do
    @doc """
    Sends a prompt to the sandbox server and returns a stream of events.

    The sandbox must be running a puck-sandbox compatible server that
    accepts POST requests to `/prompt` and returns NDJSON events.

    ## Options

    - `:port` - The port the sandbox server is listening on (default: 4001)
    - `:timeout` - Request timeout in milliseconds (default: 60_000)
    - `:options` - Custom options passed to the sandbox server (default: %{})

    ## Event Format

    The stream yields maps with a `"type"` key indicating the event type:

        %{"type" => "text", "text" => "Hello!"}
        %{"type" => "tool_call", "name" => "run_code", "arguments" => %{...}}
        %{"type" => "tool_result", "content" => "..."}
        %{"type" => "error", "message" => "..."}

    ## Examples

        {:ok, stream} = Puck.Sandbox.prompt(sandbox, "Hello")
        Enum.each(stream, fn event ->
          case event do
            %{"type" => "text", "text" => text} -> IO.write(text)
            %{"type" => "error", "message" => msg} -> IO.puts("Error: \#{msg}")
            _ -> :ok
          end
        end)

        # With content blocks for images/files
        {:ok, stream} = Puck.Sandbox.prompt(sandbox, [
          %{type: "text", text: "What's in this image?"},
          %{type: "file", media_type: "image/png", data: Base.encode64(bytes)}
        ])

        # Accumulate full response
        {:ok, stream} = Puck.Sandbox.prompt(sandbox, "Write a poem")
        text = stream
          |> Enum.filter(&match?(%{"type" => "text"}, &1))
          |> Enum.map_join(&Map.get(&1, "text"))
    """
    @spec prompt(Instance.t(), prompt_content(), keyword()) ::
            {:ok, Enumerable.t()} | {:error, term()}
    def prompt(%Instance{} = sandbox, content, opts \\ []) do
      port = Keyword.get(opts, :port, 4001)
      timeout = Keyword.get(opts, :timeout, 60_000)

      with {:ok, base_url} <- get_base_url(sandbox, port) do
        url = "#{base_url}/prompt"
        custom_opts = Keyword.get(opts, :options, %{})
        body = Jason.encode!(%{prompt: content, options: custom_opts})

        case Req.post(url,
               body: body,
               headers: [{"content-type", "application/json"}],
               into: :self,
               receive_timeout: timeout
             ) do
          {:ok, %{status: status, body: async_body}} when status in 200..299 ->
            stream = async_body |> NDJSON.stream()
            {:ok, stream}

          {:ok, %{status: status, body: body}} ->
            {:error, {:http_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    defp get_base_url(%Instance{metadata: %{private_ip: private_ip}}, port)
         when is_binary(private_ip) do
      {:ok, "http://[#{private_ip}]:#{port}"}
    end

    defp get_base_url(sandbox, port), do: get_url(sandbox, port)
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)

  defp config_to_opts(config) when is_map(config), do: Keyword.new(config)
  defp config_to_opts(config) when is_list(config), do: config

  defp merge_opts(config, opts) do
    Keyword.merge(config_to_opts(config), opts)
  end

  defp call_optional(adapter, callback, args, fallback \\ fn -> {:error, :not_implemented} end) do
    if function_exported?(adapter, callback, length(args)) do
      apply(adapter, callback, args)
    else
      fallback.()
    end
  end
end
