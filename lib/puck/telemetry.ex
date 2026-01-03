if Code.ensure_loaded?(:telemetry) do
  defmodule Puck.Telemetry do
    @moduledoc """
    Telemetry integration for observability.

    ## Usage

        client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
          hooks: Puck.Telemetry.Hooks
        )

    ## Events

    - `[:puck, :call, :start | :stop | :error]`
    - `[:puck, :stream, :start | :chunk | :stop]`
    - `[:puck, :backend, :request | :response]`

    ## Attaching Handlers

        :telemetry.attach_many("my-handler", Puck.Telemetry.event_names(), &handler/4, nil)

        # Or use the default logger
        Puck.Telemetry.attach_default_logger()

    """

    @doc """
    Returns all telemetry event names that can be emitted.

    Useful for attaching handlers to all events.

    ## Example

        :telemetry.attach_many("my-handler", Puck.Telemetry.event_names(), &handler/4, nil)

    """
    @spec event_names() :: [[atom()]]
    def event_names do
      [
        [:puck, :call, :start],
        [:puck, :call, :stop],
        [:puck, :call, :error],
        [:puck, :stream, :start],
        [:puck, :stream, :chunk],
        [:puck, :stream, :stop],
        [:puck, :backend, :request],
        [:puck, :backend, :response]
      ]
    end

    @doc """
    Attaches a default logging handler to all Puck telemetry events.

    This is a convenience function for quick debugging. For production use,
    you should implement your own handler with appropriate log levels and formatting.

    ## Options

    - `:level` - Log level to use (default: `:debug`)

    ## Example

        Puck.Telemetry.attach_default_logger()
        Puck.Telemetry.attach_default_logger(level: :info)

    """
    @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
    def attach_default_logger(opts \\ []) do
      level = Keyword.get(opts, :level, :debug)

      :telemetry.attach_many(
        "puck-telemetry-default-logger",
        event_names(),
        &__MODULE__.log_event/4,
        %{level: level}
      )
    end

    @doc """
    Detaches the default logging handler.
    """
    @spec detach_default_logger() :: :ok | {:error, :not_found}
    def detach_default_logger do
      :telemetry.detach("puck-telemetry-default-logger")
    end

    @doc false
    def log_event(event, measurements, metadata, config) do
      require Logger

      level = Map.get(config, :level, :debug)
      event_name = Enum.join(event, ".")

      Logger.log(level, fn ->
        "[#{event_name}] #{inspect(measurements)} #{inspect(metadata, limit: 3)}"
      end)
    end
  end
end
