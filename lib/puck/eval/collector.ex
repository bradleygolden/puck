defmodule Puck.Eval.Collector do
  @moduledoc """
  Captures trajectory from agent execution via telemetry.

  The Collector attaches telemetry handlers during execution to automatically
  capture all `Puck.call/4` invocations and build a `Puck.Eval.Trajectory`.

  ## Usage

      {output, trajectory} = Puck.Eval.Collector.collect(fn ->
        MyAgent.run("Find John's email")
      end)

      trajectory.total_steps   # => 2
      trajectory.total_tokens  # => 385

  ## How It Works

  1. Attaches handlers to `[:puck, :call, :start]` and `[:puck, :call, :stop]`
  2. Runs the provided function
  3. Collects telemetry events sent to this process
  4. Matches start/stop events to build Steps
  5. Returns the result and the captured Trajectory

  The Collector uses process isolation - each `collect/1` call has its own
  unique handler ID, so concurrent collections don't interfere with each other.

  ## Requirements

  Requires the `:telemetry` dependency to be installed.
  """

  alias Puck.Eval.{Step, Trajectory}

  @call_start [:puck, :call, :start]
  @call_stop [:puck, :call, :stop]

  @doc """
  Collects trajectory from the provided function.

  Wraps the function, capturing all `Puck.call/4` invocations made during
  its execution. Returns a tuple of `{result, trajectory}`.

  ## Example

      {output, trajectory} = Collector.collect(fn ->
        client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
        {:ok, response, _ctx} = Puck.call(client, "Hello!")
        response.content
      end)

      IO.puts("Output: \#{output}")
      IO.puts("Steps: \#{trajectory.total_steps}")
      IO.puts("Tokens: \#{trajectory.total_tokens}")

  ## Options

    * `:timeout` - Maximum time to wait for events after function completes (default: 100ms)
  """
  def collect(fun, opts \\ []) when is_function(fun, 0) do
    unless Code.ensure_loaded?(:telemetry) do
      raise "Puck.Eval.Collector requires the :telemetry dependency"
    end

    timeout = Keyword.get(opts, :timeout, 100)
    ref = make_ref()
    pid = self()
    handler_id = "puck-eval-collector-#{inspect(ref)}"

    attach_handlers(handler_id, ref, pid)

    try do
      result = fun.()
      Process.sleep(timeout)
      steps = receive_and_build_steps(ref)
      {result, Trajectory.new(steps)}
    after
      detach_handlers(handler_id)
    end
  end

  defp attach_handlers(handler_id, ref, pid) do
    :telemetry.attach_many(
      handler_id,
      [@call_start, @call_stop],
      &handle_event/4,
      %{ref: ref, pid: pid}
    )
  end

  defp detach_handlers(handler_id) do
    :telemetry.detach(handler_id)
  end

  @doc false
  def handle_event(@call_start, measurements, metadata, %{ref: ref, pid: pid}) do
    if self() == pid do
      event = %{
        type: :start,
        system_time: measurements[:system_time],
        prompt: metadata[:prompt],
        client: metadata[:client],
        context: metadata[:context]
      }

      send(pid, {:puck_eval_event, ref, event})
    end
  end

  def handle_event(@call_stop, measurements, metadata, %{ref: ref, pid: pid}) do
    if self() == pid do
      event = %{
        type: :stop,
        duration: measurements[:duration],
        response: metadata[:response],
        client: metadata[:client],
        context: metadata[:context]
      }

      send(pid, {:puck_eval_event, ref, event})
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp receive_and_build_steps(ref) do
    events = receive_all_events(ref, [])
    build_steps_from_events(events)
  end

  defp receive_all_events(ref, acc) do
    receive do
      {:puck_eval_event, ^ref, event} ->
        receive_all_events(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp build_steps_from_events(events) do
    events
    |> pair_events()
    |> Enum.map(&event_pair_to_step/1)
  end

  defp pair_events(events) do
    do_pair_events(events, [], nil)
  end

  defp do_pair_events([], pairs, nil), do: Enum.reverse(pairs)

  defp do_pair_events([], pairs, pending_start) do
    step = %{start: pending_start, stop: nil}
    Enum.reverse([step | pairs])
  end

  defp do_pair_events([%{type: :start} = event | rest], pairs, nil) do
    do_pair_events(rest, pairs, event)
  end

  defp do_pair_events([%{type: :start} = event | rest], pairs, pending_start) do
    step = %{start: pending_start, stop: nil}
    do_pair_events(rest, [step | pairs], event)
  end

  defp do_pair_events([%{type: :stop} = event | rest], pairs, pending_start) do
    step = %{start: pending_start, stop: event}
    do_pair_events(rest, [step | pairs], nil)
  end

  defp event_pair_to_step(%{start: start, stop: stop}) do
    input = if start, do: start.prompt, else: nil

    {output, tokens, metadata} =
      if stop do
        response = stop.response

        {
          extract_output(response),
          extract_tokens(response),
          extract_metadata(response)
        }
      else
        {nil, %{input: 0, output: 0, total: 0}, %{}}
      end

    duration_ms =
      if stop && stop.duration do
        System.convert_time_unit(stop.duration, :native, :millisecond)
      else
        0
      end

    Step.new(
      input: input,
      output: output,
      tokens: tokens,
      duration_ms: duration_ms,
      metadata: metadata
    )
  end

  defp extract_output(nil), do: nil
  defp extract_output(response), do: response.content

  defp extract_tokens(nil), do: %{input: 0, output: 0, total: 0}

  defp extract_tokens(response) do
    usage = response.usage || %{}

    %{
      input: usage[:input_tokens] || 0,
      output: usage[:output_tokens] || 0,
      total: usage[:total_tokens] || (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
    }
  end

  defp extract_metadata(nil), do: %{}

  defp extract_metadata(response) do
    response.metadata || %{}
  end
end
