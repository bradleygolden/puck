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
  Setup callback that checks if the FIREWORKS_API_KEY environment variable is set.

  Use in your test module:

      setup :check_fireworks_available!
  """
  def check_fireworks_available!(_context \\ %{}) do
    case System.get_env("FIREWORKS_API_KEY") do
      nil ->
        raise ExUnit.AssertionError,
          message: "FIREWORKS_API_KEY is not set. Export it to run BAML integration tests."

      "" ->
        raise ExUnit.AssertionError,
          message: "FIREWORKS_API_KEY is empty. Export a valid key to run BAML integration tests."

      _key ->
        :ok
    end
  end
end
