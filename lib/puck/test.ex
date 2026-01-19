defmodule Puck.Test do
  @moduledoc """
  Test utilities for deterministic agent testing.

  Creates mock clients with queued responses that work across process
  boundaries, with optional verification that all responses were consumed.

  ## Usage

      defmodule MyAgentTest do
        use ExUnit.Case, async: true

        setup :verify_on_exit!

        test "agent completes workflow" do
          client = Puck.Test.mock_client([
            %{action: "search", query: "test"},
            %{action: "done", result: "found"}
          ])

          assert {:ok, result} = MyAgent.run(client: client)
          assert result.action == "done"
        end
      end

  """

  @ownership Puck.Test.Ownership

  @doc false
  def start_link(opts \\ []) do
    NimbleOwnership.start_link(Keyword.put_new(opts, :name, @ownership))
  end

  defp ensure_started do
    case start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Creates a mock client with queued responses.

  Each call to `Puck.call/3` or `Puck.stream/3` pops the next response from
  the queue. Works across process boundaries.

  ## Response Types

  - Any term (struct, map, string) — returned as response content
  - `{:error, reason}` — simulates backend error
  - `fn messages -> response end` — dynamic response based on conversation

  ## Options

  - `:default` - Response when queue exhausts (default: `{:error, :mock_responses_exhausted}`)
  - `:model` - Model name for introspection (default: `"mock"`)

  ## Examples

      client = Puck.Test.mock_client([
        %{action: "search"},
        %{action: "done"}
      ])

      client = Puck.Test.mock_client([
        fn messages -> %{echo: length(messages)} end
      ])

      client = Puck.Test.mock_client([
        {:error, :rate_limited},
        %{action: "retry_succeeded"}
      ])

  """
  def mock_client(responses, opts \\ []) when is_list(responses) do
    default = Keyword.get(opts, :default, {:error, :mock_responses_exhausted})
    model = Keyword.get(opts, :model, "mock")

    {:ok, queue_pid} = Agent.start_link(fn -> responses end)
    track_mock(queue_pid, length(responses))

    Puck.Client.new({Puck.Backends.Mock, queue_pid: queue_pid, default: default, model: model})
  end

  @doc """
  Verifies all mock clients created by this process consumed all responses.

  Raises `ExUnit.AssertionError` if any responses remain unconsumed.
  Stops all tracked Agent processes.

  ## Example

      client = Puck.Test.mock_client([%{action: "done"}])
      Puck.call(client, "test", Puck.Context.new())
      Puck.Test.verify!()

  """
  def verify! do
    do_verify(self())
  end

  @doc """
  ExUnit setup callback for automatic verification on test exit.

      setup :verify_on_exit!

  """
  def verify_on_exit!(_context \\ %{}) do
    pid = self()
    ExUnit.Callbacks.on_exit(fn -> do_verify(pid) end)
    :ok
  end

  defp track_mock(queue_pid, count) do
    ensure_started()
    pid = self()
    key = {:puck_test_mocks, pid}

    update_fn = fn
      nil -> {:ok, [{queue_pid, count}]}
      mocks -> {:ok, [{queue_pid, count} | mocks]}
    end

    case NimbleOwnership.get_and_update(@ownership, pid, key, update_fn) do
      {:ok, _} ->
        :ok

      {:error, %NimbleOwnership.Error{}} ->
        :ok = NimbleOwnership.allow(@ownership, pid, pid, key)
        {:ok, _} = NimbleOwnership.get_and_update(@ownership, pid, key, update_fn)
        :ok
    end
  end

  defp do_verify(pid) do
    ensure_started()
    key = {:puck_test_mocks, pid}

    try do
      case NimbleOwnership.fetch_owner(@ownership, [pid], key) do
        {:ok, ^pid} ->
          {:ok, mocks} =
            NimbleOwnership.get_and_update(@ownership, pid, key, fn m -> {m, nil} end)

          verify_and_stop_mocks(mocks || [])

        _ ->
          :ok
      end
    catch
      :exit, _ -> :ok
    end
  end

  defp verify_and_stop_mocks(mocks) do
    for {queue_pid, expected} <- mocks do
      remaining = Agent.get(queue_pid, &length/1)
      Agent.stop(queue_pid)

      if remaining > 0 do
        raise ExUnit.AssertionError,
          message: "Puck.Test mock had #{remaining} of #{expected} responses unused"
      end
    end

    :ok
  end
end
