defmodule Puck.Prompt do
  @moduledoc """
  Behaviour for prompt template engines.

  ## Example

  Using Solid (requires `{:solid, "~> 0.15"}`):

      alias Puck.Prompt.Solid

      {:ok, template} = Solid.parse("Hello {{ name }}!")
      {:ok, result} = Solid.render(template, %{name: "World"})

      # Or in one step
      {:ok, result} = Solid.evaluate("Hello {{ name }}!", %{name: "World"})

  ## Callbacks

  - `parse/1`, `parse!/1` - Parse a template string
  - `render/2`, `render!/2` - Render a parsed template
  - `evaluate/2`, `evaluate!/2` - Parse and render in one step

  """

  @typedoc "A parsed template (implementation-specific)"
  @type t :: term()

  @typedoc "Context variables for template rendering"
  @type context :: %{optional(atom() | String.t()) => term()}

  @typedoc "Parse or render errors"
  @type error :: term()

  @doc """
  Parses a template string into an implementation-specific format.

  Returns `{:ok, parsed_template}` on success, `{:error, reason}` on failure.

  ## Examples

      {:ok, template} = MyEngine.parse("Hello {{ name }}!")
      {:error, reason} = MyEngine.parse("Hello {{ unclosed")

  """
  @callback parse(template :: String.t()) :: {:ok, t()} | {:error, error()}

  @doc """
  Parses a template string, raising on error.

  ## Examples

      template = MyEngine.parse!("Hello {{ name }}!")
      # Raises on invalid template

  """
  @callback parse!(template :: String.t()) :: t()

  @doc """
  Renders a parsed template with context variables.

  Returns `{:ok, rendered_string}` on success, `{:error, reason}` on failure.

  ## Examples

      {:ok, template} = MyEngine.parse("Hello {{ name }}!")
      {:ok, "Hello World!"} = MyEngine.render(template, %{name: "World"})

  """
  @callback render(template :: t(), context :: context()) ::
              {:ok, String.t()} | {:error, error()}

  @doc """
  Renders a parsed template, raising on error.

  ## Examples

      {:ok, template} = MyEngine.parse("Hello {{ name }}!")
      "Hello World!" = MyEngine.render!(template, %{name: "World"})

  """
  @callback render!(template :: t(), context :: context()) :: String.t()

  @doc """
  Parses and renders a template in one step.

  Convenience function that combines `parse/1` and `render/2`.

  ## Examples

      {:ok, "Hello World!"} = MyEngine.evaluate("Hello {{ name }}!", %{name: "World"})

  """
  @callback evaluate(template :: String.t(), context :: context()) ::
              {:ok, String.t()} | {:error, error()}

  @doc """
  Parses and renders a template in one step, raising on error.

  ## Examples

      "Hello World!" = MyEngine.evaluate!("Hello {{ name }}!", %{name: "World"})
      # Raises on invalid template or render error

  """
  @callback evaluate!(template :: String.t(), context :: context()) :: String.t()
end
