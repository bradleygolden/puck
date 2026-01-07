if Code.ensure_loaded?(:telemetry) do
  defmodule Puck.Telemetry do
    @moduledoc """
    Telemetry integration for observability.

    ## Usage

        client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
          hooks: Puck.Telemetry.Hooks
        )

    ## Events

    ### Call Start

    `[:puck, :call, :start]` - Executed before the LLM call.

    #### Measurements

      * `:system_time` - The system time in native units.

    #### Metadata

      * `:client` - The `Puck.Client` struct.
      * `:prompt` - The prompt content.
      * `:context` - The `Puck.Context` struct.

    ### Call Stop

    `[:puck, :call, :stop]` - Executed after a successful LLM call.

    #### Measurements

      * `:duration` - Time taken in native units.

    #### Metadata

      * `:client` - The `Puck.Client` struct.
      * `:response` - The `Puck.Response` struct.
      * `:context` - The `Puck.Context` struct.

    ### Call Exception

    `[:puck, :call, :exception]` - Executed when the call fails.

    #### Measurements

      * `:duration` - Time taken before failure in native units.

    #### Metadata

      * `:client` - The `Puck.Client` struct.
      * `:context` - The `Puck.Context` struct.
      * `:kind` - The exception type (`:error`, `:exit`, or `:throw`).
      * `:reason` - The error reason.
      * `:stacktrace` - The stacktrace (may be empty).

    ### Stream Start

    `[:puck, :stream, :start]` - Executed before streaming begins.

    #### Measurements

      * `:system_time` - The system time in native units.

    #### Metadata

      * `:client` - The `Puck.Client` struct.
      * `:prompt` - The prompt content.
      * `:context` - The `Puck.Context` struct.

    ### Stream Chunk

    `[:puck, :stream, :chunk]` - Executed for each streamed chunk.

    #### Measurements

    No measurements.

    #### Metadata

      * `:client` - The `Puck.Client` struct.
      * `:chunk` - The chunk data.
      * `:context` - The `Puck.Context` struct.

    ### Stream Stop

    `[:puck, :stream, :stop]` - Executed after streaming completes.

    #### Measurements

      * `:duration` - Time taken in native units.

    #### Metadata

      * `:client` - The `Puck.Client` struct.
      * `:context` - The `Puck.Context` struct.

    ### Backend Request

    `[:puck, :backend, :request]` - Executed before the backend request.

    #### Measurements

      * `:system_time` - The system time in native units.

    #### Metadata

      * `:config` - The backend configuration.
      * `:messages` - The messages being sent.

    ### Backend Response

    `[:puck, :backend, :response]` - Executed after the backend response.

    #### Measurements

      * `:system_time` - The system time in native units.

    #### Metadata

      * `:config` - The backend configuration.
      * `:response` - The backend response.

    ### Compaction Start

    `[:puck, :compaction, :start]` - Executed before context compaction.

    #### Measurements

      * `:system_time` - The system time in native units.

    #### Metadata

      * `:context` - The `Puck.Context` struct before compaction.
      * `:strategy` - The compaction strategy module.
      * `:config` - The compaction configuration.

    ### Compaction Stop

    `[:puck, :compaction, :stop]` - Executed after successful compaction.

    #### Measurements

      * `:duration` - Time taken in native units.
      * `:messages_before` - Message count before compaction.
      * `:messages_after` - Message count after compaction.

    #### Metadata

      * `:context` - The `Puck.Context` struct after compaction.
      * `:strategy` - The compaction strategy module.

    ### Compaction Error

    `[:puck, :compaction, :error]` - Executed when compaction fails.

    #### Measurements

      * `:duration` - Time taken before failure in native units.

    #### Metadata

      * `:context` - The `Puck.Context` struct.
      * `:strategy` - The compaction strategy module.
      * `:reason` - The error reason.

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
    def event_names do
      [
        [:puck, :call, :start],
        [:puck, :call, :stop],
        [:puck, :call, :exception],
        [:puck, :stream, :start],
        [:puck, :stream, :chunk],
        [:puck, :stream, :stop],
        [:puck, :backend, :request],
        [:puck, :backend, :response],
        [:puck, :compaction, :start],
        [:puck, :compaction, :stop],
        [:puck, :compaction, :error]
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
