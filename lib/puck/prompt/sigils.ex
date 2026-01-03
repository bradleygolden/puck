if Code.ensure_loaded?(Solid) do
  defmodule Puck.Prompt.Sigils do
    @moduledoc """
    Compile-time validated prompt template sigils.

    Provides the `~P` sigil for defining Liquid-syntax prompts with
    compile-time validation. Invalid templates will raise at compile time,
    catching errors early.

    ## Usage

        import Puck.Prompt.Sigils

        # Compile-time validated template
        template = ~P"Hello {{ name }}!"

        # Render at runtime
        {:ok, result} = Puck.Prompt.Solid.render(template, %{name: "World"})
        # => "Hello World!"

    ## Compile-Time Validation

    Templates are parsed at compile time, so syntax errors are caught early:

        # This will fail at compile time, not runtime!
        template = ~P"Hello {{ unclosed"
        # => ** (CompileError) Invalid template: ...

    ## Multiline Templates

    Use heredoc syntax for multiline prompts:

        template = ~P\"\"\"
        You are a helpful assistant for {{ company_name }}.

        Your role is to {{ role_description }}.

        Please respond in {{ language }}.
        \"\"\"

    """

    @doc """
    Sigil for compile-time validated Solid (Liquid) templates.

    Parses the template at compile time using `Solid.parse/1`.
    If the template is invalid, compilation will fail with a descriptive error.

    ## Examples

        import Puck.Prompt.Sigils

        template = ~P"Hello {{ name }}!"
        Puck.Prompt.Solid.render!(template, %{name: "World"})
        # => "Hello World!"

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
