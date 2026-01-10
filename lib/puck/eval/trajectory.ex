defmodule Puck.Eval.Step do
  @moduledoc """
  Represents a single LLM call within a trajectory.

  Each step captures the input, output, token usage, timing, and metadata
  from a `Puck.call/4` invocation.

  ## Fields

    * `:input` - The content sent to the LLM
    * `:output` - The parsed struct (if `output_schema` was used) or raw content
    * `:tokens` - Token usage map with `:input`, `:output`, and `:total` keys
    * `:duration_ms` - Time taken for this call in milliseconds
    * `:metadata` - Additional metadata from `Puck.Response.metadata`

  ## Example

      %Step{
        input: "Find John's email",
        output: %LookupContact{name: "John"},
        tokens: %{input: 150, output: 30, total: 180},
        duration_ms: 450,
        metadata: %{model: "claude-sonnet-4-5-20250514"}
      }
  """

  defstruct [
    :input,
    :output,
    :tokens,
    :duration_ms,
    :metadata
  ]

  @type t :: %__MODULE__{
          input: term(),
          output: term(),
          tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
          duration_ms: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Creates a new Step struct.

  ## Options

    * `:input` - The content sent to the LLM (required)
    * `:output` - The response content (required)
    * `:tokens` - Token usage map (default: `%{input: 0, output: 0, total: 0}`)
    * `:duration_ms` - Call duration in milliseconds (default: `0`)
    * `:metadata` - Additional metadata (default: `%{}`)
  """
  def new(opts) when is_list(opts) do
    tokens = Keyword.get(opts, :tokens, %{input: 0, output: 0, total: 0})

    %__MODULE__{
      input: Keyword.fetch!(opts, :input),
      output: Keyword.fetch!(opts, :output),
      tokens: normalize_tokens(tokens),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp normalize_tokens(tokens) when is_map(tokens) do
    input = get_first_present(tokens, [:input, :input_tokens], 0)
    output = get_first_present(tokens, [:output, :output_tokens], 0)
    total = get_first_present(tokens, [:total, :total_tokens], input + output)

    %{input: input, output: output, total: total}
  end

  defp get_first_present(map, keys, default) do
    case Enum.find(keys, &Map.has_key?(map, &1)) do
      nil -> default
      key -> map[key]
    end
  end
end

defmodule Puck.Eval.Trajectory do
  @moduledoc """
  Captures what happened during an agent execution.

  A trajectory is a sequence of `Puck.Eval.Step` structs representing each
  LLM call made during the execution of an agent. Use `Puck.Eval.Collector.collect/1`
  to automatically capture trajectories via telemetry.

  ## Fields

    * `:steps` - List of `Puck.Eval.Step` structs in execution order
    * `:total_steps` - Count of steps
    * `:total_tokens` - Sum of all tokens used
    * `:total_duration_ms` - Total time for all LLM calls

  ## Example

      # Capture trajectory automatically
      {output, trajectory} = Puck.Eval.Collector.collect(fn ->
        MyAgent.run("Find John's email")
      end)

      trajectory.total_steps   # => 2
      trajectory.total_tokens  # => 385

      # Inspect individual steps
      Enum.each(trajectory.steps, fn step ->
        IO.puts("Action: \#{inspect(step.output)}")
      end)
  """

  alias Puck.Eval.Step

  defstruct steps: [],
            total_steps: 0,
            total_tokens: 0,
            total_duration_ms: 0

  @type t :: %__MODULE__{
          steps: [Step.t()],
          total_steps: non_neg_integer(),
          total_tokens: non_neg_integer(),
          total_duration_ms: non_neg_integer()
        }

  @doc """
  Creates a new Trajectory from a list of steps.

  Automatically calculates `total_steps`, `total_tokens`, and `total_duration_ms`
  from the provided steps.

  ## Example

      steps = [
        Step.new(input: "Hello", output: "Hi", tokens: %{total: 10}, duration_ms: 100),
        Step.new(input: "Bye", output: "Goodbye", tokens: %{total: 15}, duration_ms: 80)
      ]

      trajectory = Trajectory.new(steps)
      trajectory.total_steps      # => 2
      trajectory.total_tokens     # => 25
      trajectory.total_duration_ms # => 180
  """
  def new(steps) when is_list(steps) do
    %__MODULE__{
      steps: steps,
      total_steps: length(steps),
      total_tokens: sum_tokens(steps),
      total_duration_ms: sum_duration(steps)
    }
  end

  @doc """
  Returns an empty trajectory.
  """
  def empty do
    %__MODULE__{}
  end

  @doc """
  Adds a step to the trajectory.

  Returns a new trajectory with the step appended and totals recalculated.
  """
  def add_step(%__MODULE__{} = trajectory, %Step{} = step) do
    steps = trajectory.steps ++ [step]
    new(steps)
  end

  @doc """
  Returns the first step in the trajectory, or nil if empty.
  """
  def first_step(%__MODULE__{steps: []}), do: nil
  def first_step(%__MODULE__{steps: [step | _]}), do: step

  @doc """
  Returns the last step in the trajectory, or nil if empty.
  """
  def last_step(%__MODULE__{steps: []}), do: nil
  def last_step(%__MODULE__{steps: steps}), do: List.last(steps)

  @doc """
  Returns all outputs from the trajectory steps.
  """
  def outputs(%__MODULE__{steps: steps}) do
    Enum.map(steps, & &1.output)
  end

  defp sum_tokens(steps) do
    Enum.reduce(steps, 0, fn step, acc ->
      acc + (step.tokens[:total] || 0)
    end)
  end

  defp sum_duration(steps) do
    Enum.reduce(steps, 0, fn step, acc ->
      acc + (step.duration_ms || 0)
    end)
  end
end
