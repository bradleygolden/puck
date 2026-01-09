if Code.ensure_loaded?(:telemetry) do
  defmodule Puck.Runtime.Telemetry do
    @moduledoc false

    def start(event, meta) do
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:puck | event] ++ [:start],
        %{system_time: System.system_time()},
        meta
      )

      start_time
    end

    def stop(event, start_time, meta, extra_measurements \\ %{}) do
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:puck | event] ++ [:stop],
        Map.merge(%{duration: duration}, extra_measurements),
        meta
      )
    end

    def exception(event, start_time, error, meta) do
      duration = System.monotonic_time() - start_time
      {kind, reason, stacktrace} = normalize_error(error)

      :telemetry.execute(
        [:puck | event] ++ [:exception],
        %{duration: duration},
        Map.merge(meta, %{kind: kind, reason: reason, stacktrace: stacktrace})
      )
    end

    def event(event, measurements, meta) do
      :telemetry.execute([:puck | event], measurements, meta)
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
else
  defmodule Puck.Runtime.Telemetry do
    @moduledoc false

    def start(_event, _meta), do: nil
    def stop(_event, _start_time, _meta, _extra_measurements \\ %{}), do: :ok
    def exception(_event, _start_time, _error, _meta), do: :ok
    def event(_event, _measurements, _meta), do: :ok
  end
end
