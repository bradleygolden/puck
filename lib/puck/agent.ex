defmodule Puck.Agent do
  @moduledoc """
  Configuration struct for an AI agent.

  An agent encapsulates the configuration needed to interact with an LLM backend.

  ## Backend Specification

  The backend is specified as a tuple: `{backend_module, backend_config}` where:

  - `backend_module` is a module implementing `Puck.Backend` behaviour
  - `backend_config` is backend-specific (model string, keyword list, etc.)

  ## Creating Agents

  There are two equivalent ways to create an agent:

      # Style 1: Tuple as first argument (clean)
      Puck.Agent.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

      Puck.Agent.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are helpful."
      )

      # Style 2: Pure keyword config (explicit)
      Puck.Agent.new(
        backend: {Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are helpful."
      )

  ## Backend Examples

      # ReqLLM backend (requires :req_llm dep)
      Puck.Agent.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
      Puck.Agent.new({Puck.Backends.ReqLLM, "openai:gpt-4"})

      # With BYOK (Bring Your Own Key)
      Puck.Agent.new({Puck.Backends.ReqLLM, model: "anthropic:claude-sonnet-4-5", api_key: user_api_key})

      # Mock backend for testing
      Puck.Agent.new({Puck.Backends.Mock, response: "Hello!"})

      # Custom backend module
      Puck.Agent.new({MyApp.CustomBackend, endpoint: "http://localhost:8000"})

  ## Agent Options

  Options can be passed as the second argument or in keyword style:

  - `:system_prompt` - The system prompt for conversations
  - `:hooks` - Hook module(s) for lifecycle events (see `Puck.Hooks`)

  Backend-specific options (temperature, max_tokens, etc.) belong in the backend tuple:

      Puck.Agent.new({Puck.Backends.ReqLLM, model: "anthropic:claude-sonnet-4-5", temperature: 0.7})

  ## Hooks

  Hooks allow observability and custom processing at each stage of execution:

      agent = Puck.Agent.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        hooks: MyApp.LLMHooks
      )

      # Multiple hooks (all get called in order)
      agent = Puck.Agent.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        hooks: [Puck.Telemetry.Hooks, MyApp.LoggingHooks]
      )

  See `Puck.Hooks` for the full behaviour specification.

  """

  @type backend_module :: module()
  @type backend_config :: map()
  @type backend :: {backend_module(), backend_config()}

  @type hooks :: module() | [module()] | nil

  @type t :: %__MODULE__{
          backend: backend(),
          system_prompt: String.t() | nil,
          hooks: hooks()
        }

  @enforce_keys [:backend]
  defstruct [:backend, :system_prompt, :hooks]

  @doc """
  Creates a new agent.

  Accepts either a backend tuple as the first argument with optional keyword options,
  or a pure keyword list with a `:backend` key.

  ## Examples

      # Mock backend (built-in)
      iex> Puck.Agent.new({Puck.Backends.Mock, response: "Hello!"})
      %Puck.Agent{backend: {Puck.Backends.Mock, %{response: "Hello!"}}, system_prompt: nil, hooks: nil}

      # With options
      iex> Puck.Agent.new({Puck.Backends.Mock, response: "Hi"}, system_prompt: "You are helpful.")
      %Puck.Agent{backend: {Puck.Backends.Mock, %{response: "Hi"}}, system_prompt: "You are helpful.", hooks: nil}

      # Pure keyword style
      iex> Puck.Agent.new(backend: {Puck.Backends.Mock, response: "Test"}, system_prompt: "You are helpful.")
      %Puck.Agent{backend: {Puck.Backends.Mock, %{response: "Test"}}, system_prompt: "You are helpful.", hooks: nil}

  """
  @spec new(backend() | keyword()) :: t()
  @spec new(backend(), keyword()) :: t()
  def new(backend_or_opts, opts \\ [])

  # Style 1: Tuple as first argument
  def new({backend_type, backend_config}, opts) when is_atom(backend_type) do
    build_agent({backend_type, normalize_backend_config(backend_config)}, opts)
  end

  def new({backend_type, model, backend_opts}, opts)
      when is_atom(backend_type) and is_binary(model) and is_list(backend_opts) do
    config = backend_opts |> Map.new() |> Map.put(:model, model)
    build_agent({backend_type, config}, opts)
  end

  # Style 2: Pure keyword config
  def new(opts, []) when is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    rest_opts = Keyword.delete(opts, :backend)
    new(backend, rest_opts)
  end

  defp normalize_backend_config(config) when is_map(config), do: config
  defp normalize_backend_config(config) when is_list(config), do: Map.new(config)
  defp normalize_backend_config(model) when is_binary(model), do: %{model: model}

  defp build_agent(backend, opts) do
    %__MODULE__{
      backend: backend,
      system_prompt: Keyword.get(opts, :system_prompt),
      hooks: Keyword.get(opts, :hooks)
    }
  end

  @doc """
  Returns the backend module for this agent.

  ## Examples

      iex> agent = Puck.Agent.new({Puck.Backends.Mock, response: "Hello"})
      iex> Puck.Agent.backend_module(agent)
      Puck.Backends.Mock

  """
  @spec backend_module(t()) :: module()
  def backend_module(%__MODULE__{backend: {backend_module, _}}) do
    backend_module
  end

  @doc """
  Returns the backend config for this agent.

  ## Examples

      iex> agent = Puck.Agent.new({Puck.Backends.Mock, response: "Hello"})
      iex> Puck.Agent.backend_config(agent)
      %{response: "Hello"}

  """
  @spec backend_config(t()) :: map()
  def backend_config(%__MODULE__{backend: {_, config}}) do
    config
  end
end
