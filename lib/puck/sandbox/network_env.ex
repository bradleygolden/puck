defmodule Puck.Sandbox.NetworkEnv do
  @moduledoc false

  @default_proxy_port 4000

  @doc """
  Builds network environment variables based on proxy config.

  Returns a map of environment variable names to values for network isolation.
  Used by sandbox adapters to configure network access in containers.

  ## Examples

      # No network access (isolation mode)
      NetworkEnv.build(nil)
      #=> %{"PUCK_NETWORK_MODE" => "none"}

      # Proxy-only access
      NetworkEnv.build([ip: "172.17.0.1", port: 4000])
      #=> %{
      #=>   "PUCK_NETWORK_MODE" => "proxy_only",
      #=>   "PUCK_PROXY_IP" => "172.17.0.1",
      #=>   "PUCK_PROXY_PORT" => "4000"
      #=> }

  """
  @spec build(keyword() | nil) :: %{String.t() => String.t()}
  def build(nil) do
    %{"PUCK_NETWORK_MODE" => "none"}
  end

  def build(proxy_opts) when is_list(proxy_opts) do
    ip = Keyword.fetch!(proxy_opts, :ip)
    port = Keyword.get(proxy_opts, :port, @default_proxy_port)

    %{
      "PUCK_NETWORK_MODE" => "proxy_only",
      "PUCK_PROXY_IP" => to_string(ip),
      "PUCK_PROXY_PORT" => to_string(port)
    }
  end
end
