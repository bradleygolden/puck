defmodule Puck.Sandbox.Runtime.HealthPollerTest do
  use ExUnit.Case, async: true

  alias Puck.Sandbox.Runtime.HealthPoller

  defmodule MockPlug do
    @moduledoc false
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{responses: [], call_count: 0} end, name: __MODULE__)
    end

    def set_responses(responses) when is_list(responses) do
      Agent.update(__MODULE__, fn state -> %{state | responses: responses} end)
    end

    def get_call_count do
      Agent.get(__MODULE__, & &1.call_count)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{responses: [], call_count: 0} end)
    end

    def call(conn, _opts) do
      {status, body} =
        Agent.get_and_update(__MODULE__, fn state ->
          call_count = state.call_count

          response =
            case Enum.at(state.responses, call_count) do
              nil -> {200, %{"status" => "ok"}}
              resp -> resp
            end

          {response, %{state | call_count: call_count + 1}}
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    start_supervised!(MockPlug)
    MockPlug.reset()
    :ok
  end

  describe "poll/2" do
    test "returns success on immediate 200 response" do
      MockPlug.set_responses([{200, %{"status" => "healthy"}}])

      assert {:ok, %{"status" => "healthy"}} =
               HealthPoller.poll("http://mock/health",
                 timeout: 5_000,
                 interval: 100,
                 plug: MockPlug,
                 retry: false
               )

      assert MockPlug.get_call_count() == 1
    end

    test "polls until success after initial failures" do
      MockPlug.set_responses([
        {500, %{"error" => "not ready"}},
        {500, %{"error" => "not ready"}},
        {200, %{"status" => "healthy"}}
      ])

      assert {:ok, %{"status" => "healthy"}} =
               HealthPoller.poll("http://mock/health",
                 timeout: 5_000,
                 interval: 50,
                 plug: MockPlug,
                 retry: false
               )

      assert MockPlug.get_call_count() == 3
    end

    test "returns timeout when health check never succeeds" do
      MockPlug.set_responses([
        {500, %{"error" => "not ready"}},
        {500, %{"error" => "not ready"}},
        {500, %{"error" => "not ready"}},
        {500, %{"error" => "not ready"}},
        {500, %{"error" => "not ready"}}
      ])

      assert {:error, :timeout} =
               HealthPoller.poll("http://mock/health",
                 timeout: 200,
                 interval: 50,
                 plug: MockPlug,
                 retry: false
               )
    end
  end
end
