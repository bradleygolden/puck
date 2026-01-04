if Code.ensure_loaded?(:telemetry) do
  defmodule Puck.Telemetry.Hooks do
    @moduledoc """
    Puck.Hooks implementation that emits telemetry events.

    This module implements the `Puck.Hooks` behaviour and emits
    `:telemetry` events at each lifecycle point.

    ## Usage

        # Client-level hooks
        client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
          hooks: Puck.Telemetry.Hooks
        )

        # Per-call hooks
        Puck.call(client, "Hello", context, hooks: Puck.Telemetry.Hooks)

        # Combined with other hooks
        Puck.call(client, "Hello", context,
          hooks: [Puck.Telemetry.Hooks, MyApp.CustomHooks]
        )

    """

    @behaviour Puck.Hooks

    # Process dictionary keys for timing
    @call_start_time :puck_telemetry_call_start_time
    @stream_start_time :puck_telemetry_stream_start_time

    @impl true
    def on_call_start(client, prompt, context) do
      Process.put(@call_start_time, System.monotonic_time())

      :telemetry.execute(
        [:puck, :call, :start],
        %{system_time: System.system_time()},
        %{client: client, prompt: prompt, context: context}
      )

      {:cont, prompt}
    end

    @impl true
    def on_call_end(client, response, context) do
      duration = calculate_duration(@call_start_time)

      :telemetry.execute(
        [:puck, :call, :stop],
        %{duration: duration},
        %{client: client, response: response, context: context}
      )

      {:cont, response}
    end

    @impl true
    def on_call_error(client, error, context) do
      duration = calculate_duration(@call_start_time)
      {kind, reason, stacktrace} = normalize_error(error)

      :telemetry.execute(
        [:puck, :call, :exception],
        %{duration: duration},
        %{
          client: client,
          context: context,
          kind: kind,
          reason: reason,
          stacktrace: stacktrace
        }
      )
    end

    @impl true
    def on_stream_start(client, prompt, context) do
      Process.put(@stream_start_time, System.monotonic_time())

      :telemetry.execute(
        [:puck, :stream, :start],
        %{system_time: System.system_time()},
        %{client: client, prompt: prompt, context: context}
      )

      {:cont, prompt}
    end

    @impl true
    def on_stream_chunk(client, chunk, context) do
      :telemetry.execute(
        [:puck, :stream, :chunk],
        %{},
        %{client: client, chunk: chunk, context: context}
      )
    end

    @impl true
    def on_stream_end(client, context) do
      duration = calculate_duration(@stream_start_time)

      :telemetry.execute(
        [:puck, :stream, :stop],
        %{duration: duration},
        %{client: client, context: context}
      )
    end

    @impl true
    def on_backend_request(config, messages) do
      :telemetry.execute(
        [:puck, :backend, :request],
        %{system_time: System.system_time()},
        %{config: config, messages: messages}
      )

      {:cont, messages}
    end

    @impl true
    def on_backend_response(config, response) do
      :telemetry.execute(
        [:puck, :backend, :response],
        %{system_time: System.system_time()},
        %{config: config, response: response}
      )

      {:cont, response}
    end

    # Private helpers

    defp calculate_duration(key) do
      case Process.get(key) do
        nil ->
          0

        start_time ->
          Process.delete(key)
          System.monotonic_time() - start_time
      end
    end

    defp normalize_error(%{__exception__: true} = exception) do
      {:error, exception, []}
    end

    defp normalize_error({kind, reason, stacktrace})
         when kind in [:error, :exit, :throw] do
      {kind, reason, stacktrace}
    end

    defp normalize_error(reason) do
      {:error, reason, []}
    end
  end
end
