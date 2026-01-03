defmodule Puck.Sandbox.Template do
  @moduledoc """
  A reusable sandbox configuration template.

  Templates define default configurations that can be instantiated with overrides.
  They are adapter-agnostic and can be stored wherever makes sense for your application
  (module attributes, config files, etc.).

  ## Example

      alias Puck.Sandbox
      alias Puck.Sandbox.Template
      alias Puck.Sandbox.Adapters.Docker

      # Define a template
      @python_template Template.new(
        adapter: Docker,
        config: %{
          image: "python:3.12",
          memory_mb: 512,
          workdir: "/workspace"
        }
      )

      # Or using shorthand tuple syntax
      @node_template Template.new({Docker, %{image: "node:22-slim", memory_mb: 256}})

      # Create sandbox from template
      {:ok, sandbox} = Sandbox.create(@python_template)

      # With overrides
      {:ok, sandbox} = Sandbox.create(@python_template, memory_mb: 1024)
  """

  @type t :: %__MODULE__{
          adapter: module(),
          config: map()
        }

  @enforce_keys [:adapter, :config]
  defstruct [:adapter, :config]

  @doc """
  Creates a new template.

  ## Examples

      # Keyword syntax
      Template.new(adapter: Docker, config: %{image: "python:3.12"})

      # Tuple syntax (same as Sandbox.create/1)
      Template.new({Docker, %{image: "python:3.12", memory_mb: 512}})
      Template.new({Docker, image: "python:3.12", memory_mb: 512})
  """
  @spec new(keyword() | {module(), map() | keyword()}) :: t()
  def new({adapter, config}) when is_atom(adapter) do
    %__MODULE__{
      adapter: adapter,
      config: normalize_config(config)
    }
  end

  def new(attrs) when is_list(attrs) do
    adapter = Keyword.fetch!(attrs, :adapter)
    config = Keyword.get(attrs, :config, %{})

    %__MODULE__{
      adapter: adapter,
      config: normalize_config(config)
    }
  end

  @doc """
  Merges override config into template config.

  Uses deep merge for nested maps, with overrides taking precedence.

  ## Examples

      template = Template.new({Docker, %{image: "python", memory_mb: 256}})
      merged = Template.merge(template, %{memory_mb: 512, cpu: 2})
      # => %{image: "python", memory_mb: 512, cpu: 2}
  """
  @spec merge(t(), map() | keyword()) :: map()
  def merge(%__MODULE__{config: base_config}, overrides) do
    override_map = normalize_config(overrides)
    deep_merge(base_config, override_map)
  end

  @doc """
  Returns the backend tuple for `Sandbox.create/1`.

  ## Examples

      template = Template.new({Docker, %{image: "python"}})
      Template.to_backend(template)
      # => {Docker, %{image: "python"}}

      Template.to_backend(template, %{memory_mb: 512})
      # => {Docker, %{image: "python", memory_mb: 512}}
  """
  @spec to_backend(t(), map() | keyword()) :: {module(), map()}
  def to_backend(%__MODULE__{adapter: adapter} = template, overrides \\ %{}) do
    {adapter, merge(template, overrides)}
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, base_val, override_val when is_map(base_val) and is_map(override_val) ->
        deep_merge(base_val, override_val)

      _key, _base_val, override_val ->
        override_val
    end)
  end
end
