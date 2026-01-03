if Code.ensure_loaded?(Solid) do
  defmodule Puck.Prompt.SolidTest do
    use ExUnit.Case, async: true

    alias Puck.Prompt.Solid, as: PromptSolid

    describe "parse/1" do
      test "parses valid template" do
        assert {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert is_struct(template, Solid.Template)
      end

      test "returns error for invalid template" do
        assert {:error, _reason} = PromptSolid.parse("Hello {{ unclosed")
      end
    end

    describe "parse!/1" do
      test "parses valid template" do
        template = PromptSolid.parse!("Hello {{ name }}!")
        assert is_struct(template, Solid.Template)
      end

      test "raises for invalid template" do
        assert_raise ArgumentError, ~r/Failed to parse template/, fn ->
          PromptSolid.parse!("Hello {{ unclosed")
        end
      end
    end

    describe "render/2" do
      test "renders template with atom keys" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert {:ok, "Hello World!"} = PromptSolid.render(template, %{name: "World"})
      end

      test "renders template with string keys" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert {:ok, "Hello World!"} = PromptSolid.render(template, %{"name" => "World"})
      end

      test "renders empty string for missing variable" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert {:ok, "Hello !"} = PromptSolid.render(template, %{})
      end
    end

    describe "render!/2" do
      test "renders template successfully" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert "Hello World!" = PromptSolid.render!(template, %{name: "World"})
      end
    end

    describe "evaluate/2" do
      test "parses and renders in one step" do
        assert {:ok, "Hello World!"} = PromptSolid.evaluate("Hello {{ name }}!", %{name: "World"})
      end

      test "returns error for invalid template" do
        assert {:error, _reason} = PromptSolid.evaluate("Hello {{ unclosed", %{})
      end
    end
  end
end
