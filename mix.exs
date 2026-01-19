defmodule Puck.MixProject do
  use Mix.Project

  @version "0.2.9"
  @source_url "https://github.com/bradleygolden/puck"

  def project do
    [
      app: :puck,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      dialyzer: dialyzer(),
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

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:baml_elixir, "~> 1.0.0-pre.24", optional: true},
      {:claude_agent_sdk, "~> 0.8", optional: true},
      {:plug, "~> 1.15", optional: true},
      {:req, "~> 0.5", optional: true},
      {:req_llm, "~> 1.0", optional: true},
      {:solid, "~> 0.15", optional: true},
      {:telemetry, "~> 1.2", optional: true},
      {:zoi, "~> 0.7", optional: true},
      {:lua, "~> 0.4.0", optional: true},
      {:nimble_ownership, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "docs --warnings-as-errors",
        "deps.unlock --check-unused",
        "deps.audit",
        "sobelow --config"
      ]
    ]
  end

  defp description do
    "AI Agent primitives for Elixir."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib priv LICENSE mix.exs README.md CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
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
          Puck.Baml,
          Puck.Backends.Baml,
          Puck.Backends.ClaudeAgentSDK,
          Puck.Backends.Mock,
          Puck.Backends.ReqLLM
        ],
        Hooks: [
          Puck.Hooks
        ],
        "Prompt Templates": [
          Puck.Prompt,
          Puck.Prompt.Solid,
          Puck.Prompt.Sigils
        ],
        Telemetry: [
          Puck.Telemetry
        ],
        Compaction: [
          Puck.Compaction,
          Puck.Compaction.Summarize,
          Puck.Compaction.SlidingWindow
        ],
        "Sandbox (Eval)": [
          Puck.Sandbox.Eval,
          Puck.Sandbox.Eval.Lua
        ],
        "Sandbox (Runtime)": [
          Puck.Sandbox.Runtime,
          Puck.Sandbox.Runtime.Adapter,
          Puck.Sandbox.Runtime.Template,
          Puck.Sandbox.Runtime.Instance,
          Puck.Sandbox.Runtime.ExecResult,
          Puck.Sandbox.Runtime.Adapters.Test
        ],
        Proxy: [
          Puck.Proxy.Sandbox
        ],
        Eval: [
          Puck.Eval,
          Puck.Eval.Trajectory,
          Puck.Eval.Step,
          Puck.Eval.Collector,
          Puck.Eval.Grader,
          Puck.Eval.Graders,
          Puck.Eval.Graders.LLM,
          Puck.Eval.Result,
          Puck.Eval.Trial,
          Puck.Eval.Inspector
        ],
        Testing: [
          Puck.Test
        ]
      ]
    ]
  end
end
