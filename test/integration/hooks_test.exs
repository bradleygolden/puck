defmodule Puck.Integration.HooksTest do
  @moduledoc """
  Integration tests for lifecycle hooks.
  """

  use Puck.IntegrationCase

  defmodule TestHooks do
    @moduledoc false
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, content, _context) do
      send(self(), {:hook, :call_start, content})
      {:cont, content}
    end

    @impl true
    def on_call_end(_client, response, _context) do
      send(self(), {:hook, :call_end, response})
      {:cont, response}
    end

    @impl true
    def on_call_error(_client, error, _context) do
      send(self(), {:hook, :call_error, error})
      {:cont, error}
    end

    @impl true
    def on_stream_start(_client, content, _context) do
      send(self(), {:hook, :stream_start, content})
      {:cont, content}
    end

    @impl true
    def on_stream_chunk(_client, chunk, _context) do
      send(self(), {:hook, :stream_chunk, chunk})
      {:cont, chunk}
    end

    @impl true
    def on_stream_end(_client, _context) do
      send(self(), {:hook, :stream_end})
      :cont
    end

    @impl true
    def on_backend_request(_config, messages) do
      send(self(), {:hook, :backend_request, messages})
      {:cont, messages}
    end

    @impl true
    def on_backend_response(_config, response) do
      send(self(), {:hook, :backend_response, response})
      {:cont, response}
    end
  end

  defmodule TransformHooks do
    @moduledoc false
    @behaviour Puck.Hooks

    @impl true
    def on_call_start(_client, content, _context) do
      # Transform content by appending text
      transformed =
        case content do
          text when is_binary(text) -> text <> " Be concise."
          other -> other
        end

      {:cont, transformed}
    end

    @impl true
    def on_call_end(_client, response, _context), do: {:cont, response}
    @impl true
    def on_call_error(_client, error, _context), do: {:cont, error}
    @impl true
    def on_stream_start(_client, content, _context), do: {:cont, content}
    @impl true
    def on_stream_chunk(_client, chunk, _context), do: {:cont, chunk}
    @impl true
    def on_stream_end(_client, _context), do: :cont
    @impl true
    def on_backend_request(_config, messages), do: {:cont, messages}
    @impl true
    def on_backend_response(_config, response), do: {:cont, response}
  end

  describe "BAML hooks" do
    @describetag :baml

    setup :check_ollama_available!

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml, function: "Classify", path: "test/support/baml_src"},
          hooks: [TestHooks]
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "call hooks are invoked", %{client: client} do
      {:ok, _response, _ctx} = Puck.call(client, "This is great!", Puck.Context.new())

      assert_received {:hook, :call_start, _content}
      assert_received {:hook, :call_end, _response}
    end

    @tag timeout: 60_000
    test "stream hooks are invoked", %{client: client} do
      {:ok, stream, _ctx} = Puck.stream(client, "This is awesome!", Puck.Context.new())

      _chunks = Enum.to_list(stream)

      assert_received {:hook, :stream_start, _content}
      assert_received {:hook, :stream_chunk, _chunk}
      assert_received {:hook, :stream_end}
    end
  end

  describe "BAML hook transformation" do
    @describetag :baml

    setup :check_ollama_available!

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.Baml, function: "Classify", path: "test/support/baml_src"},
          hooks: [TransformHooks]
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "hooks can transform content", %{client: client} do
      {:ok, response, _ctx} = Puck.call(client, "I love it!", Puck.Context.new())

      assert is_binary(response.content)
    end
  end

  describe "ReqLLM hooks" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          hooks: [TestHooks],
          system_prompt: "Classify text as positive, negative, or neutral. Reply with one word."
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "call hooks are invoked", %{client: client} do
      {:ok, _response, _ctx} = Puck.call(client, "This is great!", Puck.Context.new())

      assert_received {:hook, :call_start, _content}
      assert_received {:hook, :call_end, _response}
    end

    @tag timeout: 60_000
    test "stream hooks are invoked", %{client: client} do
      {:ok, stream, _ctx} = Puck.stream(client, "This is awesome!", Puck.Context.new())

      _chunks = Enum.to_list(stream)

      assert_received {:hook, :stream_start, _content}
      assert_received {:hook, :stream_chunk, _chunk}
      assert_received {:hook, :stream_end}
    end
  end

  describe "ReqLLM hook transformation" do
    @describetag :req_llm

    setup do
      client =
        Puck.Client.new(
          {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5-20251001"},
          hooks: [TransformHooks],
          system_prompt: "Classify text as positive, negative, or neutral. Reply with one word."
        )

      [client: client]
    end

    @tag timeout: 60_000
    test "hooks can transform content", %{client: client} do
      {:ok, response, _ctx} = Puck.call(client, "I love it!", Puck.Context.new())

      assert is_binary(response.content)
    end
  end
end
