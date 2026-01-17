if Code.ensure_loaded?(Sprites) do
  defmodule Puck.Sandbox.Runtime.Adapters.Sprites do
    @moduledoc """
    Sprites adapter for Puck.Sandbox.Runtime.

    Provides isolated Linux sandboxes via the [Sprites](https://sprites.dev) platform.
    Sprites offers persistent filesystems, command execution via WebSocket, and
    checkpoints for point-in-time snapshots.

    ## Configuration

    The adapter accepts these configuration options:

      * `:token` - Sprites API token (required, or set `SPRITES_TOKEN` env var)
      * `:name` - Unique name for the sprite (required)
      * `:base_url` - API base URL (default: "https://api.sprites.dev")

    ## Usage

        alias Puck.Sandbox.Runtime
        alias Puck.Sandbox.Runtime.Adapters.Sprites

        # Create a sandbox
        {:ok, sandbox} = Runtime.create({Sprites, name: "my-agent-sandbox"})

        # Execute commands
        {:ok, result} = Runtime.exec(sandbox, "python -c 'print(1+1)'")
        IO.puts(result.stdout)  #=> "2"

        # File operations
        :ok = Runtime.write_file(sandbox, "/app/script.py", "print('hello')")
        {:ok, content} = Runtime.read_file(sandbox, "/app/script.py")

        # Cleanup
        :ok = Runtime.terminate(sandbox)

    ## Checkpoints (Extension)

    This adapter provides extended checkpoint functionality for evaluation:

        # Create a checkpoint before testing
        {:ok, checkpoint_id} = Sprites.create_checkpoint(sandbox, "before_test")

        # Run agent tasks...

        # Restore to checkpoint
        :ok = Sprites.restore_checkpoint(sandbox, checkpoint_id)

    ## Environment Variables

      * `SPRITES_TOKEN` - Default API token if not provided in config

    """

    @behaviour Puck.Sandbox.Runtime.Adapter

    alias Puck.Sandbox.Runtime.ExecResult

    @default_base_url "https://api.sprites.dev"

    # ==========================================================================
    # Required Adapter Callbacks
    # ==========================================================================

    @impl true
    def create(config) do
      with {:ok, token} <- get_token(config),
           {:ok, name} <- get_name(config) do
        base_url = Map.get(config, :base_url, @default_base_url)
        client = Sprites.new(token, base_url: base_url)

        case Sprites.create(client, name) do
          {:ok, sprite} ->
            metadata = %{
              client: client,
              sprite: sprite,
              base_url: base_url
            }

            {:ok, name, metadata}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    @impl true
    def exec(sandbox_id, command, opts) do
      with {:ok, sprite} <- get_sprite_from_opts(sandbox_id, opts) do
        {cmd, args} = parse_command(command)

        exec_opts =
          opts
          |> Keyword.take([:dir, :env, :timeout])
          |> Keyword.put(:stderr_to_stdout, Keyword.get(opts, :stderr_to_stdout, false))

        {output, exit_code} = Sprites.cmd(sprite, cmd, args, exec_opts)

        result = %ExecResult{
          stdout: output,
          stderr: "",
          exit_code: exit_code
        }

        {:ok, result}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end

    @impl true
    def terminate(sandbox_id, opts) do
      with {:ok, sprite} <- get_sprite_from_opts(sandbox_id, opts) do
        case Sprites.destroy(sprite) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def status(sandbox_id, opts) do
      case get_sprite_from_opts(sandbox_id, opts) do
        {:ok, sprite} ->
          case Sprites.get_sprite(sprite.client, sprite.name) do
            {:ok, _info} -> :running
            {:error, _} -> :terminated
          end

        {:error, _} ->
          :unknown
      end
    end

    # ==========================================================================
    # Optional Adapter Callbacks
    # ==========================================================================

    @impl true
    def get_url(sandbox_id, port) do
      {:ok, "https://#{sandbox_id}.sprites.dev:#{port}"}
    end

    @impl true
    def read_file(sandbox_id, path, opts) do
      with {:ok, sprite} <- get_sprite_from_opts(sandbox_id, opts) do
        fs = Sprites.filesystem(sprite)
        Sprites.Filesystem.read(fs, path)
      end
    end

    @impl true
    def write_file(sandbox_id, path, content, opts) do
      with {:ok, sprite} <- get_sprite_from_opts(sandbox_id, opts) do
        fs = Sprites.filesystem(sprite)
        Sprites.Filesystem.write(fs, path, content)
      end
    end

    @impl true
    def write_files(sandbox_id, files, opts) do
      with {:ok, sprite} <- get_sprite_from_opts(sandbox_id, opts) do
        fs = Sprites.filesystem(sprite)

        Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
          case Sprites.Filesystem.write(fs, path, content) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end

    @impl true
    def await_ready(_sandbox_id, _metadata, _opts) do
      {:ok, %{status: "ready"}}
    end

    # ==========================================================================
    # Extended Checkpoint API
    # ==========================================================================

    @doc """
    Creates a checkpoint of the current sandbox state.

    Returns the checkpoint ID which can be used to restore later.

    ## Options

      * `:comment` - Optional comment describing the checkpoint

    ## Examples

        {:ok, checkpoint_id} = Sprites.create_checkpoint(sandbox, comment: "before_test")

    """
    def create_checkpoint(%Puck.Sandbox.Runtime.Instance{} = sandbox, opts \\ []) do
      with {:ok, sprite} <- get_sprite_from_instance(sandbox) do
        case Sprites.create_checkpoint(sprite, opts) do
          {:ok, messages} ->
            checkpoint_id =
              messages
              |> Enum.find_value(fn
                %{"type" => "complete", "checkpointId" => id} -> id
                %{"type" => "complete", "checkpoint_id" => id} -> id
                _ -> nil
              end)

            if checkpoint_id do
              {:ok, checkpoint_id}
            else
              {:error, :checkpoint_id_not_found}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    @doc """
    Restores a sandbox to a previous checkpoint state.

    ## Examples

        :ok = Sprites.restore_checkpoint(sandbox, "checkpoint-123")

    """
    def restore_checkpoint(%Puck.Sandbox.Runtime.Instance{} = sandbox, checkpoint_id) do
      with {:ok, sprite} <- get_sprite_from_instance(sandbox) do
        case Sprites.restore_checkpoint(sprite, checkpoint_id) do
          {:ok, _messages} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @doc """
    Lists all checkpoints for a sandbox.

    ## Examples

        {:ok, checkpoints} = Sprites.list_checkpoints(sandbox)

    """
    def list_checkpoints(%Puck.Sandbox.Runtime.Instance{} = sandbox, opts \\ []) do
      with {:ok, sprite} <- get_sprite_from_instance(sandbox) do
        Sprites.list_checkpoints(sprite, opts)
      end
    end

    # ==========================================================================
    # Private Helpers
    # ==========================================================================

    defp get_token(config) do
      case Map.get(config, :token) || System.get_env("SPRITES_TOKEN") do
        nil -> {:error, :missing_token}
        token -> {:ok, token}
      end
    end

    defp get_name(config) do
      case Map.get(config, :name) do
        nil -> {:error, :missing_name}
        name -> {:ok, name}
      end
    end

    defp get_sprite_from_opts(sandbox_id, opts) do
      case Keyword.get(opts, :sprite) do
        %Sprites.Sprite{} = sprite ->
          {:ok, sprite}

        nil ->
          build_sprite_from_opts(sandbox_id, opts)
      end
    end

    defp build_sprite_from_opts(sandbox_id, opts) do
      case {Keyword.get(opts, :client), Keyword.get(opts, :token)} do
        {%Sprites.Client{} = client, _} ->
          {:ok, Sprites.sprite(client, sandbox_id)}

        {nil, token} when is_binary(token) ->
          {:ok, build_sprite_with_token(sandbox_id, token, opts)}

        {nil, nil} ->
          build_sprite_from_env(sandbox_id, opts)
      end
    end

    defp build_sprite_with_token(sandbox_id, token, opts) do
      base_url = Keyword.get(opts, :base_url, @default_base_url)
      client = Sprites.new(token, base_url: base_url)
      Sprites.sprite(client, sandbox_id)
    end

    defp build_sprite_from_env(sandbox_id, opts) do
      case System.get_env("SPRITES_TOKEN") do
        nil -> {:error, :missing_token}
        token -> {:ok, build_sprite_with_token(sandbox_id, token, opts)}
      end
    end

    defp get_sprite_from_instance(%Puck.Sandbox.Runtime.Instance{metadata: metadata, id: id}) do
      case Map.get(metadata, :sprite) do
        %Sprites.Sprite{} = sprite ->
          {:ok, sprite}

        nil ->
          case Map.get(metadata, :client) do
            %Sprites.Client{} = client ->
              {:ok, Sprites.sprite(client, id)}

            nil ->
              {:error, :missing_client}
          end
      end
    end

    defp parse_command(command) when is_binary(command) do
      case String.split(command, " ", parts: 2) do
        [cmd] -> {cmd, []}
        [cmd, rest] -> {cmd, parse_args(rest)}
      end
    end

    defp parse_args(args_string) do
      args_string
      |> String.split(~r/\s+/)
      |> Enum.reject(&(&1 == ""))
    end
  end
end
