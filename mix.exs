defmodule Puck.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bradleygolden/puck"

  def project do
    [
      app: :puck,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      name: "Puck",
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:baml_elixir, "~> 1.0.0-pre.23", optional: true},
      {:plug, "~> 1.15", optional: true},
      {:req, "~> 0.5", optional: true},
      {:req_llm, "~> 1.0", optional: true},
      {:solid, "~> 0.15", optional: true},
      {:telemetry, "~> 1.2", optional: true},
      {:zoi, "~> 0.7", optional: true},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "format --check-formatted",
        "credo --strict"
      ]
    ]
  end

  defp description do
    """
    An AI agent framework for Elixir.
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib LICENSE mix.exs README.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"],
      groups_for_modules: [
        Core: [
          Puck,
          Puck.Client,
          Puck.Context,
          Puck.Message,
          Puck.Response,
          Puck.Content,
          Puck.Content.Part
        ],
        Backends: [
          Puck.Backend,
          Puck.Backends.Baml,
          Puck.Backends.Mock,
          Puck.Backends.ReqLLM
        ],
        Hooks: [
          Puck.Hooks,
          Puck.Telemetry.Hooks
        ],
        "Prompt Templates": [
          Puck.Prompt,
          Puck.Prompt.Solid,
          Puck.Prompt.Sigils
        ],
        Telemetry: [
          Puck.Telemetry
        ],
        Sandbox: [
          Puck.Sandbox,
          Puck.Sandbox.Adapter,
          Puck.Sandbox.Template,
          Puck.Sandbox.Instance,
          Puck.Sandbox.ExecResult,
          Puck.Sandbox.Adapters.Test
        ],
        Proxy: [
          Puck.Proxy.Sandbox
        ]
      ]
    ]
  end
end
