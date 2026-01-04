defmodule Puck.IntegrationCase do
  @moduledoc """
  Shared setup and helpers for integration tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import Puck.IntegrationCase

      @moduletag :integration
    end
  end

  @doc """
  Setup callback that checks if Ollama is available.

  Use in your test module:

      setup :check_ollama_available
  """
  def check_ollama_available!(_context \\ %{}) do
    url = "http://localhost:11434/api/tags"

    case :httpc.request(:get, {~c"#{url}", []}, [timeout: 5000], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        raise ExUnit.AssertionError,
          message: "Ollama returned status #{status}. Start Ollama with: ollama serve"

      {:error, reason} ->
        raise ExUnit.AssertionError,
          message: "Ollama is not available: #{inspect(reason)}. Start Ollama with: ollama serve"
    end
  end
end
