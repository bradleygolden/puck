if Code.ensure_loaded?(Solid) do
  defmodule Puck.Prompt.Solid do
    @moduledoc """
    Solid (Liquid) template engine for prompts.

    Uses `{{ variable }}` syntax familiar from Liquid/Jinja/Django templates.
    Solid is a safe, sandboxed template engine - templates cannot execute
    arbitrary Elixir code.

    ## Examples

        alias Puck.Prompt.Solid

        # Parse and render separately (for reuse)
        {:ok, template} = Solid.parse("Hello {{ name }}!")
        {:ok, "Hello World!"} = Solid.render(template, %{name: "World"})

        # Parse and render in one step
        {:ok, "Hello World!"} = Solid.evaluate("Hello {{ name }}!", %{name: "World"})

        # With raising variants
        template = Solid.parse!("Hello {{ name }}!")
        "Hello World!" = Solid.render!(template, %{name: "World"})

    ## Template Syntax

    Solid supports Liquid template syntax:

        # Variables
        {{ user.name }}

        # Filters
        {{ name | upcase }}
        {{ price | money }}

        # Conditionals
        {% if user %}Hello {{ user.name }}{% endif %}

        # Loops
        {% for item in items %}{{ item }}{% endfor %}

    See the [Solid documentation](https://hexdocs.pm/solid) for full syntax reference.

    ## Context Keys

    Context keys can be atoms or strings. They are normalized to strings
    internally since Solid requires string keys:

        # Both work the same
        Solid.evaluate("Hello {{ name }}!", %{name: "World"})
        Solid.evaluate("Hello {{ name }}!", %{"name" => "World"})

    """

    @behaviour Puck.Prompt

    @impl true
    def parse(template) when is_binary(template) do
      Solid.parse(template)
    end

    @impl true
    def parse!(template) when is_binary(template) do
      case parse(template) do
        {:ok, parsed} ->
          parsed

        {:error, error} ->
          raise ArgumentError, "Failed to parse template: #{inspect(error)}"
      end
    end

    @impl true
    def render(template, context) when is_struct(template, Solid.Template) do
      string_context = normalize_context(context)

      case Solid.render(template, string_context) do
        {:ok, iodata} ->
          {:ok, IO.iodata_to_binary(iodata)}

        {:error, errors, _partial} ->
          {:error, errors}
      end
    end

    @impl true
    def render!(template, context) when is_struct(template, Solid.Template) do
      case render(template, context) do
        {:ok, rendered} ->
          rendered

        {:error, errors} ->
          raise ArgumentError, "Failed to render template: #{inspect(errors)}"
      end
    end

    @impl true
    def evaluate(template, context) when is_binary(template) do
      with {:ok, parsed} <- parse(template) do
        render(parsed, context)
      end
    end

    @impl true
    def evaluate!(template, context) when is_binary(template) do
      case evaluate(template, context) do
        {:ok, rendered} -> rendered
        {:error, errors} -> raise ArgumentError, "Failed to evaluate template: #{inspect(errors)}"
      end
    end

    defp normalize_context(context) when is_map(context) do
      Map.new(context, fn {k, v} -> {to_string(k), v} end)
    end
  end
end
