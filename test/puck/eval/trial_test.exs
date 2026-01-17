defmodule Puck.Eval.TrialTest do
  use ExUnit.Case, async: true

  alias Puck.Eval.{Graders, Trial}

  setup do
    client = Puck.Client.new({Puck.Backends.Mock, response: "success"})
    {:ok, client: client}
  end

  describe "run_trials/3" do
    test "computes pass@k when at least one trial passes", %{client: client} do
      results =
        Trial.run_trials(
          fn ->
            {:ok, response, _} = Puck.call(client, "test")
            response.content
          end,
          [Graders.contains("success")],
          k: 3
        )

      assert results.k == 3
      assert results.pass_at_k == true
      assert length(results.results) == 3
    end

    test "computes pass^k when all trials pass", %{client: client} do
      results =
        Trial.run_trials(
          fn ->
            {:ok, response, _} = Puck.call(client, "test")
            response.content
          end,
          [Graders.contains("success")],
          k: 3
        )

      assert results.pass_carrot_k == true
    end

    test "computes correct pass_rate", %{client: _client} do
      call_count = :counters.new(1, [])

      results =
        Trial.run_trials(
          fn ->
            count = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)

            output = if rem(count, 2) == 0, do: "success", else: "failure"

            {output, Puck.Eval.empty_trajectory()}
          end,
          [Graders.contains("success")],
          k: 4,
          concurrency: 1
        )

      assert results.pass_rate == 0.5
      assert results.pass_at_k == true
      assert results.pass_carrot_k == false
    end

    test "respects k option" do
      results =
        Trial.run_trials(
          fn -> {"output", Puck.Eval.empty_trajectory()} end,
          [Graders.contains("output")],
          k: 7
        )

      assert results.k == 7
      assert length(results.results) == 7
    end

    test "respects concurrency option" do
      results =
        Trial.run_trials(
          fn -> {"output", Puck.Eval.empty_trajectory()} end,
          [Graders.contains("output")],
          k: 5,
          concurrency: 2
        )

      assert results.k == 5
      assert length(results.results) == 5
    end

    test "isolates state between trials" do
      results =
        Trial.run_trials(
          fn ->
            state = System.unique_integer()
            Process.put(:trial_state, state)
            {Process.get(:trial_state), Puck.Eval.empty_trajectory()}
          end,
          [Graders.satisfies(fn _ -> true end)],
          k: 3
        )

      outputs = Enum.map(results.results, & &1.output)
      assert length(Enum.uniq(outputs)) == 3
    end

    test "all trials fail when graders don't pass" do
      results =
        Trial.run_trials(
          fn -> {"failure", Puck.Eval.empty_trajectory()} end,
          [Graders.contains("success")],
          k: 3
        )

      assert results.pass_at_k == false
      assert results.pass_carrot_k == false
      assert results.pass_rate == 0.0
    end

    test "respects timeout option" do
      assert_raise RuntimeError, ~r/Trial failed:.*timeout/, fn ->
        Trial.run_trials(
          fn ->
            Process.sleep(100)
            {"output", Puck.Eval.empty_trajectory()}
          end,
          [Graders.contains("output")],
          k: 1,
          timeout: 10
        )
      end
    end

    test "returns Summary struct" do
      results =
        Trial.run_trials(
          fn -> {"output", Puck.Eval.empty_trajectory()} end,
          [Graders.contains("output")],
          k: 1
        )

      assert %Trial.Summary{} = results
    end
  end
end
