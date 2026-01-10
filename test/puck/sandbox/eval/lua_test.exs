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

    test "table return is JSON-encodable map" do
      {:ok, result} = Lua.eval("return {a = 1, b = 2}")
      assert is_map(result)
      assert result == %{"a" => 1, "b" => 2}
      assert {:ok, _} = Jason.encode(result)
    end

    test "nested table return is JSON-encodable" do
      {:ok, result} = Lua.eval("return {user = {name = 'Alice', age = 30}, count = 5}")
      assert is_map(result)
      assert result == %{"user" => %{"name" => "Alice", "age" => 30}, "count" => 5}
      assert {:ok, _} = Jason.encode(result)
    end

    test "array table return is JSON-encodable list" do
      {:ok, result} = Lua.eval("return {10, 20, 30}")
      assert is_list(result)
      assert result == [10, 20, 30]
      assert {:ok, _} = Jason.encode(result)
    end

    test "array of tables return is JSON-encodable" do
      {:ok, result} = Lua.eval("return {{name = 'a'}, {name = 'b'}}")
      assert is_list(result)
      assert result == [%{"name" => "a"}, %{"name" => "b"}]
      assert {:ok, _} = Jason.encode(result)
    end

    test "multiple return values are JSON-encodable" do
      {:ok, result} = Lua.eval("return {x = 1}, {y = 2}")
      assert is_list(result)
      assert result == [%{"x" => 1}, %{"y" => 2}]
      assert {:ok, _} = Jason.encode(result)
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

    test "callback returning map with atom keys" do
      callbacks = %{"get_stats" => fn -> %{total: 100, active: 50} end}
      assert {:ok, 100} = Lua.eval("return get_stats().total", callbacks: callbacks)
    end

    test "callback returning nested map with atom keys" do
      callbacks = %{
        "get_data" => fn -> %{user: %{name: "Alice", age: 30}, count: 5} end
      }

      assert {:ok, "Alice"} = Lua.eval("return get_data().user.name", callbacks: callbacks)
    end

    test "callback returning list of maps with atom keys" do
      callbacks = %{
        "get_items" => fn -> [%{id: 1, name: "foo"}, %{id: 2, name: "bar"}] end
      }

      assert {:ok, "bar"} = Lua.eval("return get_items()[2].name", callbacks: callbacks)
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
