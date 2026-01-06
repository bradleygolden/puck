defmodule Puck.SandboxAgentTest do
  @moduledoc """
  Integration tests for agent loops with sandboxed Lua code execution.
  """

  use Puck.IntegrationCase

  alias Puck.Sandbox.Eval
  alias Puck.Sandbox.Eval.Lua

  defmodule Done do
    @moduledoc false
    defstruct type: "done", message: nil
  end

  # Each function is self-contained with its signature in the description.
  # The LLM just selects which functions it's using - actual calls happen in Lua code.
  @double_func Zoi.object(
                 %{name: Zoi.literal("double")},
                 strict: true,
                 coerce: true,
                 description: "double(n: number) -> number: Doubles the input number"
               )

  @add_func Zoi.object(
              %{name: Zoi.literal("add")},
              strict: true,
              coerce: true,
              description: "add(a: number, b: number) -> number: Adds two numbers together"
            )

  @func_spec Zoi.union([@double_func, @add_func])

  defp schema do
    Zoi.union([
      Lua.schema(@func_spec),
      Zoi.struct(
        Done,
        %{
          type: Zoi.literal("done"),
          message: Zoi.string(description: "Final response message")
        },
        coerce: true
      )
    ])
  end

  describe "ReqLLM sandbox agent" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          system_prompt: """
          You are a calculator assistant. Given a user request:
          - If calculation is needed, use execute_lua with Lua code.
          - List the functions you use in the functions field.
          - After getting results, use done with a summary.
          """
        )

      callbacks = %{
        "double" => fn n -> n * 2 end,
        "add" => fn a, b -> a + b end
      }

      [client: client, callbacks: callbacks]
    end

    @tag timeout: 120_000
    test "agent generates and executes Lua code", %{client: client, callbacks: callbacks} do
      loop = fn loop_fn, input, ctx ->
        {:ok, %{content: action}, ctx} =
          Puck.call(client, input, ctx, output_schema: schema())

        case action do
          %Done{message: msg} ->
            {:ok, msg}

          %Lua.ExecuteCode{code: code} ->
            run_code(loop_fn, code, ctx, callbacks)
        end
      end

      {:ok, result} = loop.(loop, "Double the number 21", Puck.Context.new())

      assert is_binary(result)
      assert result =~ ~r/42/
    end

    defp run_code(loop_fn, code, ctx, callbacks) do
      case Eval.eval(:lua, code, callbacks: callbacks) do
        {:ok, result} ->
          loop_fn.(loop_fn, "Code result: #{inspect(result)}", ctx)

        {:error, reason} ->
          loop_fn.(loop_fn, "Code error: #{inspect(reason)}", ctx)
      end
    end
  end
end
