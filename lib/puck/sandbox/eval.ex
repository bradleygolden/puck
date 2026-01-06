defmodule Puck.Sandbox.Eval do
  @moduledoc """
  In-process code evaluation in sandboxed interpreters.

  Puck.Sandbox.Eval provides a unified API for evaluating code snippets in
  sandboxed interpreter environments. Unlike `Puck.Sandbox.Runtime` which
  runs containers, Eval runs code in-process with memory and CPU limits.

  ## Supported Engines

  - `:lua` - Lua 5.3 via Luerl (pure Erlang, requires `{:lua, "~> 0.4.0"}`)

  ## Usage

      # Simple eval
      {:ok, result} = Puck.Sandbox.Eval.eval(:lua, "return 1 + 2")

      # With callbacks to host functions
      {:ok, result} = Puck.Sandbox.Eval.eval(:lua, \"\"\"
        local products = search("laptop")
        local cheap = {}
        for _, p in ipairs(products) do
          if p.price < 1000 then table.insert(cheap, p) end
        end
        return cheap
      \"\"\", callbacks: %{
        "search" => &MyApp.Products.search/1
      })

      # With resource limits
      {:ok, result} = Puck.Sandbox.Eval.eval(:lua, code,
        timeout_ms: 5_000,
        max_heap_words: 1_000_000
      )

  ## Safety

  Code runs in a separate BEAM process with:
  - CPU limits via timeout
  - Memory limits via process heap limits
  - No filesystem or network access (interpreter sandboxed)
  - Crash isolation (pure Erlang, no NIF)

  The only risk is user-provided callbacks.
  """

  alias Puck.Sandbox.Eval.Lua, as: LuaEngine

  @type engine :: :lua
  @type code :: String.t()
  @type eval_opts :: [
          callbacks: %{String.t() => function()},
          timeout_ms: pos_integer(),
          max_heap_words: pos_integer()
        ]

  @doc """
  Evaluates code in the specified sandboxed interpreter.

  ## Engines

  - `:lua` - Lua 5.3 (requires `{:lua, "~> 0.4.0"}`)

  ## Options

  - `:callbacks` - Map of callback names to functions
  - `:timeout_ms` - Execution timeout in ms (default: 5_000)
  - `:max_heap_words` - Memory limit in words (default: 1_000_000, ~8MB)

  ## Examples

      {:ok, 3} = Puck.Sandbox.Eval.eval(:lua, "return 1 + 2")

      {:ok, result} = Puck.Sandbox.Eval.eval(:lua, \"\"\"
        return double(21)
      \"\"\", callbacks: %{"double" => fn x -> x * 2 end})

      {:error, :timeout} = Puck.Sandbox.Eval.eval(:lua, "while true do end", timeout_ms: 100)
  """
  @spec eval(engine(), code(), eval_opts()) :: {:ok, term()} | {:error, term()}
  def eval(engine, code, opts \\ [])

  def eval(:lua, code, opts) do
    LuaEngine.eval(code, opts)
  end

  def eval(engine, _code, _opts) do
    {:error, {:unknown_engine, engine}}
  end

  @doc """
  Like `eval/3` but raises on error.

  ## Examples

      42 = Puck.Sandbox.Eval.eval!(:lua, "return 42")
  """
  @spec eval!(engine(), code(), eval_opts()) :: term()
  def eval!(engine, code, opts \\ [])

  def eval!(:lua, code, opts) do
    LuaEngine.eval!(code, opts)
  end

  def eval!(engine, _code, _opts) do
    raise ArgumentError, "Unknown eval engine: #{inspect(engine)}"
  end

  @doc """
  Returns the list of available eval engines.

  ## Examples

      [:lua] = Puck.Sandbox.Eval.engines()
  """
  @spec engines() :: [engine()]
  def engines do
    [:lua]
  end

  @doc """
  Checks if an engine is available.

  ## Examples

      true = Puck.Sandbox.Eval.engine_available?(:lua)
      false = Puck.Sandbox.Eval.engine_available?(:python)
  """
  @spec engine_available?(engine()) :: boolean()
  def engine_available?(:lua), do: Code.ensure_loaded?(LuaEngine)
  def engine_available?(_), do: false
end
