defmodule Puck.Eval.Collector do
  @moduledoc """
  Captures trajectory from agent execution via telemetry.

  The Collector attaches telemetry handlers during execution to automatically
  capture all `Puck.call/4` and `Puck.stream/4` invocations and build a
  `Puck.Eval.Trajectory`.

  ## Usage

      {output, trajectory} = Puck.Eval.Collector.collect(fn ->
        MyAgent.run("Find John's email")
      end)

      trajectory.total_steps   # => 2
      trajectory.total_tokens  # => 385

  ## How It Works

  1. Attaches handlers to call and stream telemetry events
  2. Runs the provided function
  3. Collects telemetry events from this process and any spawned child processes
  4. Matches start/stop events by emitting process to build Steps
  5. Returns the result and the captured Trajectory

  The Collector uses process isolation - each `collect/1` call has its own
  unique handler ID, so concurrent collections don't interfere with each other.
  Child processes spawned during collection (via `Task.async`, etc.) are
  automatically tracked as long as they inherit the `$ancestors` process
  dictionary key (which OTP processes do by default).

  ## Requirements

  Requires the `:telemetry` dependency to be installed.
  """

  alias Puck.Eval.{Step, Trajectory}

  @call_start [:puck, :call, :start]
  @call_stop [:puck, :call, :stop]
  @stream_start [:puck, :stream, :start]
  @stream_chunk [:puck, :stream, :chunk]
  @stream_stop [:puck, :stream, :stop]

  @doc """
  Collects trajectory from the provided function.

  Wraps the function, capturing all `Puck.call/4` and `Puck.stream/4` invocations
  made during its execution. Returns a tuple of `{result, trajectory}`.

  Streaming calls are captured with `step.metadata[:streamed] == true` and the
  concatenated stream content as `step.output`. Note that streaming steps have
  zero token counts since usage isn't available during streaming.

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
      [@call_start, @call_stop, @stream_start, @stream_chunk, @stream_stop],
      &handle_event/4,
      %{ref: ref, pid: pid}
    )
  end

  defp detach_handlers(handler_id) do
    :telemetry.detach(handler_id)
  end

  defp collecting_process?(pid) do
    self() == pid or pid in (Process.get(:"$ancestors") || [])
  end

  @doc false
  def handle_event(@call_start, measurements, metadata, %{ref: ref, pid: pid}) do
    if collecting_process?(pid) do
      event = %{
        type: :start,
        emitter: self(),
        system_time: measurements[:system_time],
        prompt: metadata[:prompt],
        client: metadata[:client],
        context: metadata[:context]
      }

      send(pid, {:puck_eval_event, ref, event})
    end
  end

  def handle_event(@call_stop, measurements, metadata, %{ref: ref, pid: pid}) do
    if collecting_process?(pid) do
      event = %{
        type: :stop,
        emitter: self(),
        duration: measurements[:duration],
        response: metadata[:response],
        client: metadata[:client],
        context: metadata[:context]
      }

      send(pid, {:puck_eval_event, ref, event})
    end
  end

  def handle_event(@stream_start, measurements, metadata, %{ref: ref, pid: pid}) do
    if collecting_process?(pid) do
      event = %{
        type: :stream_start,
        emitter: self(),
        system_time: measurements[:system_time],
        prompt: metadata[:prompt],
        client: metadata[:client],
        context: metadata[:context]
      }

      send(pid, {:puck_eval_event, ref, event})
    end
  end

  def handle_event(@stream_chunk, _measurements, metadata, %{ref: ref, pid: pid}) do
    if collecting_process?(pid) do
      event = %{
        type: :stream_chunk,
        emitter: self(),
        chunk: metadata[:chunk],
        client: metadata[:client]
      }

      send(pid, {:puck_eval_event, ref, event})
    end
  end

  def handle_event(@stream_stop, measurements, metadata, %{ref: ref, pid: pid}) do
    if collecting_process?(pid) do
      event = %{
        type: :stream_stop,
        emitter: self(),
        duration: measurements[:duration],
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
    |> Enum.group_by(& &1.emitter)
    |> Enum.flat_map(fn {_emitter, emitter_events} -> pair_events(emitter_events) end)
    |> Enum.map(&event_pair_to_step/1)
  end

  defp pair_events(events) do
    do_pair_events(events, [], nil, [])
  end

  defp do_pair_events([], pairs, nil, _chunks), do: Enum.reverse(pairs)

  defp do_pair_events([], pairs, pending_start, chunks) do
    step = %{start: pending_start, stop: nil, chunks: Enum.reverse(chunks)}
    Enum.reverse([step | pairs])
  end

  defp do_pair_events([%{type: :start} = event | rest], pairs, nil, _chunks) do
    do_pair_events(rest, pairs, event, [])
  end

  defp do_pair_events([%{type: :start} = event | rest], pairs, pending_start, chunks) do
    step = %{start: pending_start, stop: nil, chunks: Enum.reverse(chunks)}
    do_pair_events(rest, [step | pairs], event, [])
  end

  defp do_pair_events([%{type: :stop} = event | rest], pairs, pending_start, chunks) do
    step = %{start: pending_start, stop: event, chunks: Enum.reverse(chunks)}
    do_pair_events(rest, [step | pairs], nil, [])
  end

  defp do_pair_events([%{type: :stream_start} = event | rest], pairs, nil, _chunks) do
    do_pair_events(rest, pairs, event, [])
  end

  defp do_pair_events([%{type: :stream_start} = event | rest], pairs, pending_start, chunks) do
    step = %{start: pending_start, stop: nil, chunks: Enum.reverse(chunks)}
    do_pair_events(rest, [step | pairs], event, [])
  end

  defp do_pair_events([%{type: :stream_chunk} = event | rest], pairs, pending_start, chunks) do
    do_pair_events(rest, pairs, pending_start, [event | chunks])
  end

  defp do_pair_events([%{type: :stream_stop} = event | rest], pairs, pending_start, chunks) do
    step = %{start: pending_start, stop: event, chunks: Enum.reverse(chunks)}
    do_pair_events(rest, [step | pairs], nil, [])
  end

  defp event_pair_to_step(%{start: start, stop: stop, chunks: chunks}) do
    input = if start, do: start.prompt, else: nil
    {output, tokens, metadata} = extract_step_data(start, stop, chunks)
    duration_ms = extract_duration(stop)

    Step.new(
      input: input,
      output: output,
      tokens: tokens,
      duration_ms: duration_ms,
      metadata: metadata
    )
  end

  defp event_pair_to_step(%{start: start, stop: stop}) do
    event_pair_to_step(%{start: start, stop: stop, chunks: []})
  end

  defp extract_step_data(start, _stop, chunks)
       when start != nil and start.type == :stream_start and chunks != [] do
    {extract_stream_output(chunks), %{input: 0, output: 0, total: 0}, %{streamed: true}}
  end

  defp extract_step_data(_start, stop, _chunks) when stop != nil and stop.response != nil do
    response = stop.response
    {extract_output(response), extract_tokens(response), extract_metadata(response)}
  end

  defp extract_step_data(_start, _stop, _chunks) do
    {nil, %{input: 0, output: 0, total: 0}, %{}}
  end

  defp extract_duration(nil), do: 0
  defp extract_duration(%{duration: nil}), do: 0

  defp extract_duration(%{duration: duration}) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp extract_output(nil), do: nil
  defp extract_output(response), do: response.content

  defp extract_stream_output(chunks) do
    Enum.map_join(chunks, "", fn %{chunk: chunk} -> chunk[:content] || "" end)
  end

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
