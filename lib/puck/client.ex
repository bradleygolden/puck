defmodule Puck.Client do
  @moduledoc """
  Configuration struct for an LLM client.

  ## Creating Clients

      # Basic
      Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

      # With options
      Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are helpful."
      )

      # With backend options
      Puck.Client.new({Puck.Backends.ReqLLM, model: "anthropic:claude-sonnet-4-5", temperature: 0.7})

      # Mock backend for testing
      Puck.Client.new({Puck.Backends.Mock, response: "Hello!"})

  ## Options

  - `:system_prompt` - System prompt for conversations
  - `:hooks` - Hook module(s) for lifecycle events (see `Puck.Hooks`)

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
  Creates a new client.

  Accepts either a backend tuple as the first argument with optional keyword options,
  or a pure keyword list with a `:backend` key.

  ## Examples

      # Mock backend (built-in)
      iex> Puck.Client.new({Puck.Backends.Mock, response: "Hello!"})
      %Puck.Client{backend: {Puck.Backends.Mock, %{response: "Hello!"}}, system_prompt: nil, hooks: nil}

      # With options
      iex> Puck.Client.new({Puck.Backends.Mock, response: "Hi"}, system_prompt: "You are helpful.")
      %Puck.Client{backend: {Puck.Backends.Mock, %{response: "Hi"}}, system_prompt: "You are helpful.", hooks: nil}

      # Pure keyword style
      iex> Puck.Client.new(backend: {Puck.Backends.Mock, response: "Test"}, system_prompt: "You are helpful.")
      %Puck.Client{backend: {Puck.Backends.Mock, %{response: "Test"}}, system_prompt: "You are helpful.", hooks: nil}

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
  Returns the backend module for this client.

  ## Examples

      iex> client = Puck.Client.new({Puck.Backends.Mock, response: "Hello"})
      iex> Puck.Client.backend_module(client)
      Puck.Backends.Mock

  """
  @spec backend_module(t()) :: module()
  def backend_module(%__MODULE__{backend: {backend_module, _}}) do
    backend_module
  end

  @doc """
  Returns the backend config for this client.

  ## Examples

      iex> client = Puck.Client.new({Puck.Backends.Mock, response: "Hello"})
      iex> Puck.Client.backend_config(client)
      %{response: "Hello"}

  """
  @spec backend_config(t()) :: map()
  def backend_config(%__MODULE__{backend: {_, config}}) do
    config
  end
end
