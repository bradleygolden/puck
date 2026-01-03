if Code.ensure_loaded?(Solid) do
  defmodule Puck.Prompt.SigilsTest do
    use ExUnit.Case, async: true

    import Puck.Prompt.Sigils
    alias Puck.Prompt.Solid, as: PromptSolid

    describe "~P sigil" do
      test "creates a parsed template" do
        template = ~P"Hello {{ name }}!"
        assert is_struct(template, Solid.Template)
      end

      test "template can be rendered" do
        template = ~P"Hello {{ name }}!"
        assert {:ok, "Hello World!"} = PromptSolid.render(template, %{name: "World"})
      end

      test "works with multiline heredoc" do
        template = ~P"""
        Hello {{ name }}!
        Welcome to {{ place }}.
        """

        assert {:ok, result} = PromptSolid.render(template, %{name: "Alice", place: "Wonderland"})
        assert result =~ "Hello Alice!"
        assert result =~ "Welcome to Wonderland."
      end
    end

    describe "compile-time validation" do
      test "invalid template raises at compile time" do
        assert_raise CompileError, ~r/Invalid template/, fn ->
          Code.compile_string("""
          import Puck.Prompt.Sigils
          ~P"Hello {{ unclosed"
          """)
        end
      end
    end
  end
end
