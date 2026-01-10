defmodule Puck.Eval.CollectorTest do
  use ExUnit.Case, async: false

  alias Puck.Eval.{Collector, Trajectory}

  describe "collect/1" do
    test "captures trajectory from Puck.call" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "Hello!"})

      {result, trajectory} =
        Collector.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "Hi there")
          response.content
        end)

      assert result == "Hello!"
      assert %Trajectory{} = trajectory
      assert trajectory.total_steps == 1
      assert [step] = trajectory.steps
      assert step.output == "Hello!"
    end

    test "captures multiple calls in a loop" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "response"})

      {_result, trajectory} =
        Collector.collect(fn ->
          {:ok, _, ctx} = Puck.call(client, "first", Puck.Context.new())
          {:ok, _, ctx} = Puck.call(client, "second", ctx)
          {:ok, response, _ctx} = Puck.call(client, "third", ctx)
          response.content
        end)

      assert trajectory.total_steps == 3
      assert length(trajectory.steps) == 3
    end

    test "captures tokens and duration" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "test", delay: 50})

      {_result, trajectory} =
        Collector.collect(fn ->
          {:ok, response, _ctx} = Puck.call(client, "test")
          response.content
        end)

      assert trajectory.total_steps == 1
      [step] = trajectory.steps
      # Mock backend estimates tokens
      assert step.tokens.total >= 0
      # Duration should be at least the delay
      assert step.duration_ms >= 50
    end

    test "returns empty trajectory when no calls made" do
      {result, trajectory} =
        Collector.collect(fn ->
          "no LLM calls here"
        end)

      assert result == "no LLM calls here"
      assert trajectory.total_steps == 0
      assert trajectory.steps == []
    end

    test "isolates trajectories between concurrent collections" do
      client =
        Puck.Client.new({Puck.Backends.Mock, response: "test"})

      task1 =
        Task.async(fn ->
          Collector.collect(fn ->
            {:ok, _, _} = Puck.call(client, "task1-call1", Puck.Context.new())
            {:ok, response, _} = Puck.call(client, "task1-call2", Puck.Context.new())
            response.content
          end)
        end)

      task2 =
        Task.async(fn ->
          Collector.collect(fn ->
            {:ok, response, _} = Puck.call(client, "task2-call1", Puck.Context.new())
            response.content
          end)
        end)

      {_result1, trajectory1} = Task.await(task1)
      {_result2, trajectory2} = Task.await(task2)

      # Each task should only see its own calls
      assert trajectory1.total_steps == 2
      assert trajectory2.total_steps == 1
    end

    test "captures trajectory from streaming response" do
      client =
        Puck.Client.new(
          {Puck.Backends.Mock, stream_chunks: ["This ", "is ", "a ", "streamed ", "response"]}
        )

      {output, trajectory} =
        Collector.collect(fn ->
          {:ok, stream, _ctx} = Puck.stream(client, "Tell me something")
          Enum.map_join(stream, "", & &1.content)
        end)

      assert output == "This is a streamed response"
      assert trajectory.total_steps == 1
      assert [step] = trajectory.steps
      assert step.output == "This is a streamed response"
      assert step.metadata[:streamed] == true
    end

    test "captures trajectory from mixed call and stream operations" do
      call_client = Puck.Client.new({Puck.Backends.Mock, response: "call response"})
      stream_client = Puck.Client.new({Puck.Backends.Mock, stream_chunks: ["streamed"]})

      {output, trajectory} =
        Collector.collect(fn ->
          ctx = Puck.Context.new()
          {:ok, _, ctx} = Puck.call(call_client, "first", ctx)
          {:ok, stream, _ctx} = Puck.stream(stream_client, "second", ctx)
          Enum.map_join(stream, "", & &1.content)
        end)

      assert output == "streamed"
      assert trajectory.total_steps == 2

      [call_step, stream_step] = trajectory.steps
      assert call_step.output == "call response"
      assert call_step.metadata[:streamed] == nil
      assert stream_step.output == "streamed"
      assert stream_step.metadata[:streamed] == true
    end

    test "captures calls from child processes (Task.async)" do
      client = Puck.Client.new({Puck.Backends.Mock, response: "from child"})

      {result, trajectory} =
        Collector.collect(fn ->
          task =
            Task.async(fn ->
              {:ok, response, _ctx} = Puck.call(client, "child process call")
              response.content
            end)

          Task.await(task)
        end)

      assert result == "from child"
      assert trajectory.total_steps == 1
      assert [step] = trajectory.steps
      assert step.output == "from child"
    end

    test "captures calls from multiple child processes" do
      client = Puck.Client.new({Puck.Backends.Mock, response: "response"})

      {_result, trajectory} =
        Collector.collect(fn ->
          tasks =
            Enum.map(1..3, fn i ->
              Task.async(fn ->
                {:ok, response, _ctx} = Puck.call(client, "call #{i}")
                response.content
              end)
            end)

          Enum.map(tasks, &Task.await/1)
        end)

      assert trajectory.total_steps == 3
    end

    test "captures calls from mixed parent and child processes" do
      client = Puck.Client.new({Puck.Backends.Mock, response: "response"})

      {_result, trajectory} =
        Collector.collect(fn ->
          {:ok, _, _} = Puck.call(client, "parent call")

          task =
            Task.async(fn ->
              {:ok, response, _ctx} = Puck.call(client, "child call")
              response.content
            end)

          Task.await(task)
        end)

      assert trajectory.total_steps == 2
    end
  end
end
