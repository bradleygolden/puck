defmodule Puck.Sandbox.Eval.Lua do
  @moduledoc """
  Execute Lua code in a sandboxed environment.

  Uses tv-labs/lua (Luerl), a pure Erlang Lua implementation. Provides:
  - CPU limits via timeout
  - Memory limits via process heap limits
  - Host callbacks for safe interaction with your application
  - Complete crash isolation (pure Erlang, no NIF)

  ## Usage

      # Simple eval
      {:ok, result} = Puck.Sandbox.Eval.Lua.eval("return 1 + 2")
      # => {:ok, 3}

      # With callbacks
      {:ok, result} = Puck.Sandbox.Eval.Lua.eval(\"\"\"
        local products = search_products("laptop")
        local cheap = {}
        for _, p in ipairs(products) do
          if p.price < 1000 then table.insert(cheap, p) end
        end
        return cheap
      \"\"\", callbacks: %{
        "search_products" => &MyApp.Products.search/1
      })

      # With resource limits
      {:ok, result} = Puck.Sandbox.Eval.Lua.eval(code,
        callbacks: %{...},
        timeout_ms: 5_000,
        max_heap_words: 1_000_000
      )

  ## Requirements

  Requires the `lua` package: `{:lua, "~> 0.4.0"}`

  ## Options

  - `:callbacks` - Map of callback names to functions (e.g., `%{"name" => &Mod.fun/1}`)
  - `:timeout_ms` - Execution timeout in ms (default: 5_000)
  - `:max_heap_words` - Memory limit in words (default: 1_000_000, ~8MB on 64-bit)

  ## Safety

  Luerl sandboxes by default, blocking:
  - `io` module (file I/O)
  - `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`
  - `load`, `loadfile`, `loadstring`, `dofile`, `require`
  - `package` module

  The only risk is user-provided callbacks.
  """

  @default_timeout 5_000
  @default_max_heap 1_000_000

  defmodule Error do
    @moduledoc "Exception raised by `Puck.Sandbox.Eval.Lua.eval!/2`."
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: "Lua sandbox error: #{inspect(reason)}"
  end

  defmodule ExecuteCode do
    @moduledoc """
    Struct for LLM-generated Lua code execution actions.

    Used with `Puck.Sandbox.Eval.Lua.schema/1` to create Zoi schemas
    that guide LLMs in generating valid Lua code.
    """
    defstruct type: "execute_lua", code: nil, functions: []
  end

  @doc """
  Returns a Zoi schema for the `ExecuteCode` struct.

  The schema includes guidance in the `code` field description to help LLMs
  generate valid Lua code (e.g., always use `return` to return values).

  ## Arguments

  - `func_spec` - A Zoi schema describing the available callback functions.
    The LLM will see this schema and understand what functions it can call.

  ## Example

      @func_spec Zoi.object(%{
        name: Zoi.enum(["double", "search"]),
        description: Zoi.string()
      }, strict: true, coerce: true)

      schema = Zoi.union([
        Puck.Sandbox.Eval.Lua.schema(@func_spec),
        Zoi.struct(Done, %{type: Zoi.literal("done"), message: Zoi.string()}, coerce: true)
      ])

      # Pattern match on the struct:
      case action do
        %Puck.Sandbox.Eval.Lua.ExecuteCode{code: code} ->
          Puck.Sandbox.Eval.eval(:lua, code, callbacks: callbacks)
        %Done{message: msg} ->
          {:ok, msg}
      end
  """
  def schema(func_spec) do
    ensure_zoi_available!()

    Zoi.struct(
      __MODULE__.ExecuteCode,
      %{
        type: Zoi.literal("execute_lua"),
        code: Zoi.string(description: "Lua code. Always use 'return' to return values."),
        functions:
          Zoi.list(func_spec, description: "Functions available to use in the code")
          |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Evaluates Lua code in a sandboxed environment.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.

  ## Examples

      {:ok, 3} = Puck.Sandbox.Eval.Lua.eval("return 1 + 2")

      {:ok, result} = Puck.Sandbox.Eval.Lua.eval(\"\"\"
        local x = 0
        for i = 1, 100 do x = x + i end
        return x
      \"\"\")
      # => {:ok, 5050}

      {:error, :timeout} = Puck.Sandbox.Eval.Lua.eval("while true do end", timeout_ms: 100)
  """
  def eval(code, opts \\ []) do
    ensure_lua_available!()

    callbacks = Keyword.get(opts, :callbacks, %{})
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    max_heap = Keyword.get(opts, :max_heap_words, @default_max_heap)

    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{size: max_heap, kill: true, error_logger: false})
        run_lua(code, callbacks)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `eval/2` but raises `Puck.Sandbox.Eval.Lua.Error` on failure.

  ## Examples

      3 = Puck.Sandbox.Eval.Lua.eval!("return 1 + 2")
  """
  def eval!(code, opts \\ []) do
    case eval(code, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise Error, reason: reason
    end
  end

  defp run_lua(code, callbacks) do
    lua = Lua.new()

    lua =
      Enum.reduce(callbacks, lua, fn {name, func}, acc ->
        Lua.set!(acc, [String.to_atom(name)], wrap_callback(func))
      end)

    {results, _lua} = Lua.eval!(lua, code)
    {:ok, unwrap_result(results)}
  rescue
    e -> {:error, e}
  end

  defp wrap_callback(func) do
    fn args ->
      result = apply(func, args)
      [result]
    end
  end

  defp unwrap_result([single]), do: single
  defp unwrap_result([]), do: nil
  defp unwrap_result(multiple), do: multiple

  defp ensure_lua_available! do
    unless Code.ensure_loaded?(Lua) do
      raise Error,
        reason: "Lua module not available. Add {:lua, \"~> 0.4.0\"} to your dependencies."
    end
  end

  defp ensure_zoi_available! do
    unless Code.ensure_loaded?(Zoi) do
      raise Error,
        reason: "Zoi module not available. Add {:zoi, \"~> 0.7\"} to your dependencies."
    end
  end
end
