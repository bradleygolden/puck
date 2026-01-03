if Code.ensure_loaded?(Plug) do
  defmodule Puck.Proxy.Sandbox do
    @moduledoc """
    A sandbox-aware HTTP proxy with domain allowlisting and credential injection.

    This is a simple proxy that validates requests against an allowlist and
    injects credentials before forwarding with Req.

    ## Architecture

    This proxy runs OUTSIDE the sandbox VM. The sandbox VM:
    1. Has network restricted to only reach this proxy (via iptables)
    2. Makes requests to `http://proxy:4000/{target_url}`
    3. Never sees credentials - they're injected here

    ## Usage

        # Start with Bandit
        Bandit.start_link(
          plug: {Puck.Proxy.Sandbox, [
            allowed_domains: ["api.anthropic.com", "api.github.com"],
            credentials: %{
              "api.anthropic.com" => [
                {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
                {"anthropic-version", "2023-06-01"}
              ]
            }
          ]},
          port: 4000
        )

    ## Request Format

    The sandbox sends requests with the target URL in the path:

        POST http://proxy:4000/https://api.anthropic.com/v1/messages
        Content-Type: application/json

        {"model": "claude-3", "messages": [...]}

    The proxy:
    1. Extracts target URL from path
    2. Validates domain against allowlist
    3. Injects credentials for that domain
    4. Forwards request with Req
    5. Streams response back
    """

    @behaviour Plug

    import Plug.Conn

    @default_timeout 600_000

    @impl true
    def init(opts) do
      %{
        allowed_domains: Keyword.fetch!(opts, :allowed_domains),
        credentials: Keyword.get(opts, :credentials, %{}),
        timeout: Keyword.get(opts, :timeout, @default_timeout)
      }
    end

    @impl true
    def call(conn, config) do
      # Extract target URL from path_info (works with Phoenix forward)
      # path_info splits on "/" so "https://example.com" becomes ["https:", "example.com"]
      # We need to reconstruct the "://" after the scheme
      target_url = reconstruct_url(conn.path_info)

      case URI.parse(target_url) do
        %URI{host: host} when is_binary(host) and host != "" ->
          if domain_allowed?(host, config.allowed_domains) do
            forward_request(conn, target_url, host, config)
          else
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(403, "Domain not allowed: #{host}")
          end

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(400, "Invalid target URL: #{target_url}")
      end
    end

    defp reconstruct_url([scheme | rest]) when is_binary(scheme) do
      if String.ends_with?(scheme, ":") do
        scheme <> "//" <> Enum.join(rest, "/")
      else
        Enum.join([scheme | rest], "/")
      end
    end

    defp reconstruct_url([]), do: ""

    defp domain_allowed?(host, allowed_domains) do
      Enum.any?(allowed_domains, fn pattern ->
        if String.starts_with?(pattern, "*.") do
          suffix = String.slice(pattern, 1..-1//1)
          String.ends_with?(host, suffix) or host == String.slice(pattern, 2..-1//1)
        else
          host == pattern
        end
      end)
    end

    defp forward_request(conn, target_url, host, config) do
      {:ok, body, conn} = read_body(conn)

      # Get credentials for this domain
      domain_credentials = Map.get(config.credentials, host, [])

      # Build headers: original headers + credentials (credentials override)
      original_headers =
        conn.req_headers
        |> Enum.reject(fn {name, _} ->
          String.downcase(name) in ["host", "connection", "content-length", "transfer-encoding"]
        end)

      headers = merge_headers(original_headers, domain_credentials)

      if streaming_request?(body) do
        stream_request(conn, target_url, headers, body, config.timeout)
      else
        sync_request(conn, target_url, headers, body, conn.method, config.timeout)
      end
    end

    defp merge_headers(original, credentials) do
      cred_keys =
        credentials
        |> Enum.map(fn {k, _} -> String.downcase(k) end)
        |> MapSet.new()

      filtered =
        Enum.reject(original, fn {name, _} ->
          MapSet.member?(cred_keys, String.downcase(name))
        end)

      filtered ++ credentials
    end

    defp streaming_request?(body) do
      case Jason.decode(body) do
        {:ok, %{"stream" => true}} -> true
        _ -> false
      end
    end

    defp stream_request(conn, url, headers, body, timeout) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      task =
        Task.async(fn ->
          Req.post(url,
            headers: headers,
            body: body,
            into: :self,
            receive_timeout: timeout
          )
        end)

      receive_chunks(conn, task.ref, timeout)
    end

    defp receive_chunks(conn, ref, timeout) do
      receive do
        {^ref, {:data, data}} ->
          case chunk(conn, data) do
            {:ok, new_conn} -> receive_chunks(new_conn, ref, timeout)
            {:error, _} -> conn
          end

        {^ref, %Req.Response{}} ->
          conn

        {:DOWN, ^ref, :process, _pid, _reason} ->
          conn
      after
        timeout -> conn
      end
    end

    defp sync_request(conn, url, headers, body, method, timeout) do
      req_method = method |> to_string() |> String.downcase() |> String.to_atom()

      case Req.request(
             method: req_method,
             url: url,
             headers: headers,
             body: body,
             receive_timeout: timeout,
             decode_body: false
           ) do
        {:ok, response} ->
          conn
          |> put_resp_content_type(get_content_type(response.headers))
          |> send_resp(response.status, response.body)

        {:error, reason} ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(502, "Proxy error: #{inspect(reason)}")
      end
    end

    defp get_content_type(headers) do
      case Map.get(headers, "content-type") do
        [value | _] -> value
        nil -> "application/json"
      end
    end
  end
end
