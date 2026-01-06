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

  # Zoi types for Lua callbacks - all with descriptions
  # Use string values for enums since LLM returns JSON strings, not atoms
  @lua_type Zoi.enum(["string", "number", "boolean", "table", nil],
              description: "Lua data type"
            )

  @param_spec Zoi.object(
                %{
                  name: Zoi.string(description: "Parameter name"),
                  type: @lua_type,
                  description: Zoi.string(description: "What this parameter is for")
                },
                strict: true,
                coerce: true
              )

  @func_names Zoi.enum(["double"],
                description: "Function to call. double: Doubles the input number"
              )

  @func_spec Zoi.object(
               %{
                 name: @func_names,
                 description: Zoi.string(description: "What this function does"),
                 params: Zoi.list(@param_spec, description: "Function parameters"),
                 returns: @lua_type
               },
               strict: true,
               coerce: true
             )

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

      callbacks = %{"double" => fn n -> n * 2 end}

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
