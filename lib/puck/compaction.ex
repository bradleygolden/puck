defmodule Puck.Compaction do
  @moduledoc """
  Behaviour for context compaction strategies.

  Context compaction reduces conversation history size while preserving essential
  information. This helps manage LLM context windows and avoid "context rot" -
  degraded performance as context length increases.

  ## Callbacks

  - `compact/2` - Compacts the context using the strategy's approach
  - `should_compact?/2` - (optional) Returns whether compaction should occur
  - `introspect/1` - (optional) Returns strategy metadata for observability

  ## Example

      defmodule MyApp.Compaction.Custom do
        @behaviour Puck.Compaction

        @impl true
        def compact(context, config) do
          # Custom compaction logic
          {:ok, compacted_context}
        end
      end

  ## Built-in Strategies

  - `Puck.Compaction.Summarize` - LLM-based summarization (preserves semantic meaning)

  ## Usage

      # Manual compaction
      {:ok, compacted} = Puck.Compaction.compact(context, {Puck.Compaction.Summarize, %{
        client: client,
        keep_last: 3
      }})

  """

  alias Puck.Context

  @type config :: map()
  @type result :: {:ok, Context.t()} | {:error, term()}

  @doc """
  Compacts the context to reduce its size.

  ## Parameters

  - `context` - The context to compact
  - `config` - Strategy-specific configuration

  ## Returns

  - `{:ok, compacted_context}` on success
  - `{:error, reason}` on failure

  """
  @callback compact(Context.t(), config()) :: result()

  @doc """
  Returns whether the context should be compacted.

  Implementations can check token counts, message counts, or other criteria.

  ## Parameters

  - `context` - The context to check
  - `config` - Strategy-specific configuration (may include thresholds)

  ## Returns

  - `true` if compaction should occur
  - `false` otherwise

  """
  @callback should_compact?(Context.t(), config()) :: boolean()

  @typedoc """
  Metadata returned by introspect/1 for observability.
  """
  @type introspection :: %{
          :strategy => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Returns metadata about the compaction strategy.

  Used by telemetry/tracing to identify the strategy being used.

  ## Parameters

  - `config` - Strategy configuration

  ## Expected Keys

  - `:strategy` - Strategy name (e.g., "summarize", "sliding_window")

  """
  @callback introspect(config()) :: introspection()

  @optional_callbacks [should_compact?: 2, introspect: 1]

  @doc """
  Compacts a context using the specified strategy.

  This is a convenience function that delegates to the strategy module.

  ## Parameters

  - `context` - The context to compact
  - `strategy_tuple` - A tuple of `{strategy_module, config}`

  ## Examples

      {:ok, compacted} = Puck.Compaction.compact(context, {Puck.Compaction.Summarize, %{
        client: client,
        keep_last: 3
      }})

  """
  def compact(%Context{} = context, {strategy_module, config}) when is_atom(strategy_module) do
    strategy_module.compact(context, config)
  end

  @doc """
  Checks if context should be compacted using the specified strategy.

  Falls back to `true` if the strategy doesn't implement `should_compact?/2`.

  ## Parameters

  - `context` - The context to check
  - `strategy_tuple` - A tuple of `{strategy_module, config}`

  ## Examples

      if Puck.Compaction.should_compact?(context, {Puck.Compaction.Summarize, config}) do
        {:ok, compacted} = Puck.Compaction.compact(context, {Puck.Compaction.Summarize, config})
      end

  """
  def should_compact?(%Context{} = context, {strategy_module, config})
      when is_atom(strategy_module) do
    Code.ensure_loaded(strategy_module)

    if function_exported?(strategy_module, :should_compact?, 2) do
      strategy_module.should_compact?(context, config)
    else
      true
    end
  end
end
