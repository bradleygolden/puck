defmodule Puck do
  @moduledoc """
  Puck - An AI framework for Elixir.

  ## Quick Start

      # Create a client (requires :req_llm dep)
      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are a helpful assistant."
      )

      # Simple call
      {:ok, response, _ctx} = Puck.call(client, "Hello!")

      # Multi-turn conversation
      context = Puck.Context.new()
      {:ok, response, context} = Puck.call(client, "Hello!", context)
      {:ok, response, context} = Puck.call(client, "Follow-up question", context)

      # Stream responses
      {:ok, stream, _ctx} = Puck.stream(client, "Tell me a story")
      Enum.each(stream, fn chunk -> IO.write(chunk.content) end)

  ## Core Concepts

  - `Puck.Client` - Configuration struct for an LLM client (backend, system prompt, hooks)
  - `Puck.Context` - Conversation history and metadata
  - `Puck.Content` - Multi-modal content (text, images, files, audio, video)
  - `Puck.Message` - Individual message in a conversation
  - `Puck.Backend` - Behaviour for LLM backend implementations
  - `Puck.Hooks` - Behaviour for lifecycle event hooks
  - `Puck.Response` - Normalized response struct with content, finish_reason, usage

  ## Optional Packages

  - `:req_llm` - Multi-provider LLM backend (enables `Puck.Backends.ReqLLM`)
  - `:solid` - Prompt templates with Liquid syntax (enables `Puck.Prompt.Solid`)
  - `:telemetry` - Telemetry integration for observability
  - `:zoi` - Schema validation for structured outputs

  """

  alias Puck.{Client, Context, Runtime}

  @doc """
  Calls an LLM and returns the response.

  ## Returns

  - `{:ok, response, context}` on success
  - `{:error, reason}` on failure

  ## Examples

      # Simple call
      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
      {:ok, response, _ctx} = Puck.call(client, "Hello!")

      # With system prompt
      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are a translator."
      )
      {:ok, response, _ctx} = Puck.call(client, "Translate to Spanish")

      # Multi-turn conversation
      context = Puck.Context.new()
      {:ok, response, context} = Puck.call(client, "Hello!", context)
      {:ok, response, context} = Puck.call(client, "Follow-up question", context)

  """
  def call(%Client{} = client, content) do
    {context, final_content} = build_context_from_content(content)
    Runtime.call(client, final_content, context, [])
  end

  def call(%Client{} = client, content, %Context{} = context, opts \\ []) do
    Runtime.call(client, content, context, opts)
  end

  @doc """
  Streams an LLM response.

  ## Returns

  - `{:ok, stream, context}` where stream is an `Enumerable` of chunks
  - `{:error, reason}` on failure

  ## Examples

      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
      {:ok, stream, _ctx} = Puck.stream(client, "Tell me a story")
      Enum.each(stream, fn chunk -> IO.write(chunk.content) end)

  """
  def stream(%Client{} = client, content) do
    {context, final_content} = build_context_from_content(content)
    Runtime.stream(client, final_content, context, [])
  end

  def stream(%Client{} = client, content, %Context{} = context, opts \\ []) do
    Runtime.stream(client, content, context, opts)
  end

  # Detect messages format (has :role key) and build context from conversation history
  defp build_context_from_content(content, base_context \\ Context.new())

  defp build_context_from_content([%{role: _} | _] = messages, base_context) do
    {history, [last]} = Enum.split(messages, -1)

    context =
      Enum.reduce(history, base_context, fn msg, ctx ->
        Context.add_message(ctx, msg.role, msg.content)
      end)

    {context, last.content}
  end

  defp build_context_from_content(content, base_context) do
    {base_context, content}
  end
end
