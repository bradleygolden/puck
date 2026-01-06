defmodule Puck.Sandbox.Eval.LuaTest do
  use ExUnit.Case, async: true

  alias Puck.Sandbox.Eval.Lua

  describe "eval/2" do
    test "simple expression" do
      assert {:ok, 3} = Lua.eval("return 1 + 2")
    end

    test "string return" do
      assert {:ok, "hello"} = Lua.eval("return 'hello'")
    end

    test "table return" do
      {:ok, result} = Lua.eval("return {a = 1, b = 2}")
      assert is_list(result)
    end

    test "nil return" do
      assert {:ok, nil} = Lua.eval("return nil")
    end

    test "no return" do
      assert {:ok, _} = Lua.eval("local x = 1")
    end

    test "with callback" do
      callbacks = %{"double" => fn x -> x * 2 end}
      assert {:ok, 10} = Lua.eval("return double(5)", callbacks: callbacks)
    end

    test "with callback taking multiple args" do
      callbacks = %{"add" => fn a, b -> a + b end}
      assert {:ok, 7} = Lua.eval("return add(3, 4)", callbacks: callbacks)
    end

    test "timeout on infinite loop" do
      assert {:error, :timeout} =
               Lua.eval(
                 "while true do end",
                 timeout_ms: 100
               )
    end

    test "sandboxed os.execute raises" do
      {:error, error} = Lua.eval("os.execute('ls')")
      assert Exception.message(error) =~ "os"
    end

    test "sandboxed io.open raises" do
      {:error, error} = Lua.eval("io.open('/etc/passwd')")
      assert Exception.message(error) =~ "invalid index"
    end

    test "sandboxed loadfile raises" do
      {:error, error} = Lua.eval("loadfile('/etc/passwd')")
      assert Exception.message(error) =~ "load"
    end
  end

  describe "eval!/2" do
    test "returns result on success" do
      assert 3 = Lua.eval!("return 1 + 2")
    end

    test "raises on timeout" do
      assert_raise Lua.Error, ~r/timeout/, fn ->
        Lua.eval!("while true do end", timeout_ms: 100)
      end
    end

    test "raises on lua error" do
      assert_raise Lua.Error, fn ->
        Lua.eval!("error('boom')")
      end
    end
  end
end
