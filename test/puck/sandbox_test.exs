defmodule Puck.SandboxTest do
  use ExUnit.Case, async: true

  alias Puck.Sandbox
  alias Puck.Sandbox.Adapters.Test, as: TestAdapter
  alias Puck.Sandbox.ExecResult
  alias Puck.Sandbox.Instance

  setup do
    start_supervised!(TestAdapter)
    :ok
  end

  describe "create/1" do
    test "creates a sandbox with the test adapter" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{image: "test:latest"}})

      assert %Instance{} = sandbox
      assert sandbox.adapter == TestAdapter
      assert sandbox.config == %{image: "test:latest"}
      assert is_integer(sandbox.created_at)
      assert Sandbox.status(sandbox) == :running
    end

    test "accepts keyword list config" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, image: "test:latest"})

      assert sandbox.config == %{image: "test:latest"}
    end
  end

  describe "from_id/3" do
    test "reconstructs a sandbox from an ID" do
      sandbox = Sandbox.from_id(TestAdapter, "existing-sandbox-123")

      assert %Instance{} = sandbox
      assert sandbox.id == "existing-sandbox-123"
      assert sandbox.adapter == TestAdapter
      assert sandbox.config == %{}
    end
  end

  describe "exec/3" do
    test "executes a command and returns result" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})
      {:ok, result} = Sandbox.exec(sandbox, "echo hello")

      assert %ExecResult{} = result
      assert result.stdout == "mock: echo hello"
      assert result.exit_code == 0
    end

    test "uses mock response when set" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      TestAdapter.set_exec_response(
        sandbox.id,
        "node --version",
        {:ok, %ExecResult{stdout: "v22.0.0\n", exit_code: 0}}
      )

      {:ok, result} = Sandbox.exec(sandbox, "node --version")

      assert result.stdout == "v22.0.0\n"
    end
  end

  describe "terminate/1" do
    test "terminates the sandbox" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      assert :ok = Sandbox.terminate(sandbox)
      assert Sandbox.status(sandbox) == :terminated
    end
  end

  describe "status/1" do
    test "returns running for new sandbox" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      assert Sandbox.status(sandbox) == :running
    end
  end

  describe "get_url/2" do
    test "returns URL for exposed port" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      {:ok, url} = Sandbox.get_url(sandbox, 4000)

      assert url == "http://#{sandbox.id}:4000"
    end
  end
end
