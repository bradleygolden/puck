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

    @impl true
    def on_call_start(agent, prompt, context) do
      :telemetry.execute(
        [:puck, :call, :start],
        %{system_time: System.system_time()},
        %{agent: agent, prompt: prompt, context: context}
      )

      {:cont, prompt}
    end

    @impl true
    def on_call_end(agent, response, context) do
      :telemetry.execute(
        [:puck, :call, :stop],
        %{system_time: System.system_time()},
        %{agent: agent, response: response, context: context}
      )

      {:cont, response}
    end

    @impl true
    def on_call_error(agent, error, context) do
      :telemetry.execute(
        [:puck, :call, :error],
        %{system_time: System.system_time()},
        %{agent: agent, error: error, context: context}
      )
    end

    @impl true
    def on_stream_start(agent, prompt, context) do
      :telemetry.execute(
        [:puck, :stream, :start],
        %{system_time: System.system_time()},
        %{agent: agent, prompt: prompt, context: context}
      )

      {:cont, prompt}
    end

    @impl true
    def on_stream_chunk(agent, chunk, context) do
      :telemetry.execute(
        [:puck, :stream, :chunk],
        %{},
        %{agent: agent, chunk: chunk, context: context}
      )
    end

    @impl true
    def on_stream_end(agent, context) do
      :telemetry.execute(
        [:puck, :stream, :stop],
        %{system_time: System.system_time()},
        %{agent: agent, context: context}
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
  end
end
