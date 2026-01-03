defmodule Puck.Sandbox.Adapters.Test do
  @moduledoc """
  In-memory test adapter for Puck.Sandbox.

  ## Usage

      setup do
        start_supervised!(Puck.Sandbox.Adapters.Test)
        :ok
      end

      test "sandbox" do
        {:ok, sandbox} = Puck.Sandbox.create({Puck.Sandbox.Adapters.Test, %{}})
        {:ok, result} = Puck.Sandbox.exec(sandbox, "echo hello")
      end

  """

  @behaviour Puck.Sandbox.Adapter

  use Agent

  alias Puck.Sandbox.ExecResult

  @doc """
  Starts the test adapter agent.

  ## Options

    * `:name` - The name to register the agent under. Defaults to `__MODULE__`.
      Use a unique name per test when running with `async: true`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    ensure_ets_table()
    Agent.start_link(fn -> %{sandboxes: %{}, responses: %{}} end, name: name)
  end

  defp ensure_ets_table do
    if :ets.whereis(__MODULE__) == :undefined do
      :ets.new(__MODULE__, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_agent_name(sandbox_id) do
    case :ets.whereis(__MODULE__) do
      :undefined -> __MODULE__
      _table -> :ets.lookup_element(__MODULE__, sandbox_id, 2, __MODULE__)
    end
  end

  defp register_sandbox(sandbox_id, agent_name) do
    ensure_ets_table()
    :ets.insert(__MODULE__, {sandbox_id, agent_name})
  end

  @doc """
  Sets a mock response for a specific command in a sandbox.
  """
  @spec set_exec_response(
          String.t(),
          String.t(),
          {:ok, ExecResult.t()} | {:error, term()},
          atom()
        ) ::
          :ok
  def set_exec_response(sandbox_id, command, response, name \\ __MODULE__) do
    Agent.update(name, fn state ->
      put_in(state, [:responses, {sandbox_id, command}], response)
    end)
  end

  @doc """
  Gets the command execution history for a sandbox.
  """
  @spec get_exec_history(String.t(), atom()) :: [String.t()]
  def get_exec_history(sandbox_id, name \\ __MODULE__) do
    Agent.get(name, fn state ->
      get_in(state, [:sandboxes, sandbox_id, :history]) || []
    end)
  end

  @doc """
  Gets the config for a sandbox.
  """
  @spec get_config(String.t(), atom()) :: map() | nil
  def get_config(sandbox_id, name \\ __MODULE__) do
    Agent.get(name, fn state ->
      get_in(state, [:sandboxes, sandbox_id, :config])
    end)
  end

  # Adapter callbacks

  @impl true
  def create(config) do
    id = "test-sandbox-#{System.unique_integer([:positive])}"
    agent_name = Map.get(config, :agent_name, __MODULE__)
    register_sandbox(id, agent_name)

    Agent.update(agent_name, fn state ->
      put_in(state, [:sandboxes, id], %{config: config, status: :running, history: []})
    end)

    {:ok, id, %{}}
  end

  @impl true
  def exec(sandbox_id, command, _opts) do
    agent_name = get_agent_name(sandbox_id)

    Agent.get_and_update(agent_name, fn state ->
      state = update_in(state, [:sandboxes, sandbox_id, :history], &[command | &1 || []])

      response =
        get_in(state, [:responses, {sandbox_id, command}]) ||
          {:ok, %ExecResult{stdout: "mock: #{command}", exit_code: 0}}

      {response, state}
    end)
  end

  @impl true
  def terminate(sandbox_id, _opts \\ []) do
    agent_name = get_agent_name(sandbox_id)

    Agent.update(agent_name, fn state ->
      put_in(state, [:sandboxes, sandbox_id, :status], :terminated)
    end)

    :ok
  end

  @impl true
  def status(sandbox_id, _opts \\ []) do
    agent_name = get_agent_name(sandbox_id)

    Agent.get(agent_name, fn state ->
      get_in(state, [:sandboxes, sandbox_id, :status]) || :unknown
    end)
  end

  @impl true
  def get_url(sandbox_id, port) do
    {:ok, "http://#{sandbox_id}:#{port}"}
  end

  @impl true
  def read_file(sandbox_id, path, _opts) do
    agent_name = get_agent_name(sandbox_id)

    Agent.get(agent_name, fn state ->
      case get_in(state, [:sandboxes, sandbox_id, :files, path]) do
        nil -> {:error, :file_not_found}
        content -> {:ok, content}
      end
    end)
  end

  @impl true
  def write_file(sandbox_id, path, content, _opts) do
    agent_name = get_agent_name(sandbox_id)

    Agent.update(agent_name, fn state ->
      update_in(state, [:sandboxes, sandbox_id, :files], fn files ->
        Map.put(files || %{}, path, content)
      end)
    end)
  end

  @impl true
  def write_files(sandbox_id, files, _opts) do
    agent_name = get_agent_name(sandbox_id)

    Agent.update(agent_name, fn state ->
      update_in(state, [:sandboxes, sandbox_id, :files], fn existing ->
        Map.merge(existing || %{}, Map.new(files))
      end)
    end)
  end

  @impl true
  def await_ready(sandbox_id, _metadata, _opts) do
    {:ok,
     %{
       "status" => "ok",
       "sandbox_id" => sandbox_id,
       "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  @impl true
  def stop(sandbox_id, _opts \\ []) do
    agent_name = get_agent_name(sandbox_id)

    case update_sandbox(agent_name, sandbox_id, [:status], :stopped) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def start(sandbox_id, _opts \\ []) do
    agent_name = get_agent_name(sandbox_id)

    case update_sandbox(agent_name, sandbox_id, [:status], :running) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update(sandbox_id, config, _opts \\ []) do
    agent_name = get_agent_name(sandbox_id)

    case update_sandbox(agent_name, sandbox_id, [:config], config) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_sandbox(agent_name, sandbox_id, path, value) do
    case Process.whereis(agent_name) do
      nil ->
        {:error, :agent_not_running}

      _pid ->
        try do
          Agent.update(agent_name, &update_sandbox_state(&1, sandbox_id, path, value))
        catch
          :exit, _ -> {:error, :agent_not_running}
        end
    end
  end

  defp update_sandbox_state(state, sandbox_id, path, value) do
    if get_in(state, [:sandboxes, sandbox_id]) do
      put_in(state, [:sandboxes, sandbox_id | path], value)
    else
      state
    end
  end
end
