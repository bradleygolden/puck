if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Baml do
    @moduledoc """
    Built-in BAML functions shipped with Puck.

    This module compiles BAML files from Puck's priv directory, providing
    built-in functions that work without users needing to write `.baml` files.

    Users configure their LLM provider via `client_registry` at runtime,
    overriding the placeholder `PuckClient` defined in the BAML source.

    ## Available Functions

    - `PuckSummarize` - Summarizes conversation text (called via `Puck.Baml.PuckSummarize`)

    ## Example

        registry = %{
          primary: "claude",
          clients: [%{
            name: "claude",
            provider: "anthropic",
            options: %{model: "claude-sonnet-4-5", api_key: System.get_env("ANTHROPIC_API_KEY")}
          }]
        }

        {:ok, summary} = Puck.Baml.PuckSummarize.call(
          %{text: "User: Hello\\nAssistant: Hi there!", instructions: "Summarize this."},
          %{client_registry: registry}
        )

    """

    use BamlElixir.Client, path: {:puck, "priv/baml_src"}
  end
end
