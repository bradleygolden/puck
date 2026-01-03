if Code.ensure_loaded?(Solid) do
  defmodule Puck.Prompt.Sigils do
    @moduledoc """
    Compile-time validated prompt template sigils.

    ## Example

        import Puck.Prompt.Sigils

        template = ~P"Hello {{ name }}!"
        {:ok, result} = Puck.Prompt.Solid.render(template, %{name: "World"})

    Invalid templates raise at compile time.
    """

    @doc """
    Sigil for compile-time validated Solid (Liquid) templates.
    """
    defmacro sigil_P({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
      case Solid.parse(template) do
        {:ok, parsed} ->
          Macro.escape(parsed)

        {:error, error} ->
          raise CompileError,
            description: "Invalid template: #{inspect(error)}",
            file: __CALLER__.file,
            line: __CALLER__.line
      end
    end

    defmacro sigil_P({:<<>>, _, _}, _modifiers) do
      raise CompileError,
        description: "~P sigil does not support interpolation",
        file: __CALLER__.file,
        line: __CALLER__.line
    end
  end
end
