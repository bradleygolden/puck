defmodule Puck do
  @moduledoc """
  Puck - An AI agent framework for Elixir.

  ## Quick Start

      # Simple call (requires :req_llm dep)
      {:ok, response, _ctx} = Puck.call("Hello!", model: "anthropic:claude-sonnet-4-5")

      # Or create an agent explicitly
      agent = Puck.Agent.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are a helpful assistant."
      )

      # Call the agent
      context = Puck.Context.new()
      {:ok, response, context} = Puck.call(agent, "Hello!", context)

      # Stream responses
      {:ok, stream, context} = Puck.stream(agent, "Tell me a story", context)
      Enum.each(stream, fn chunk -> IO.write(chunk.content) end)

  ## Core Concepts

  - `Puck.Agent` - Configuration struct for an agent (backend, system prompt, hooks)
  - `Puck.Context` - Conversation history and metadata
  - `Puck.Content` - Multi-modal content (text, images, files, audio, video)
  - `Puck.Message` - Individual message in a conversation
  - `Puck.Backend` - Behaviour for LLM backend implementations
  - `Puck.Hooks` - Behaviour for lifecycle event hooks
  - `Puck.Response` - Normalized response struct with content, tool_calls, finish_reason

  ## Optional Packages

  - `:req_llm` - Multi-provider LLM backend (enables `Puck.Backends.ReqLLM`)
  - `:solid` - Prompt templates with Liquid syntax (enables `Puck.Prompt.Solid`)
  - `:telemetry` - Telemetry integration for observability
  - `:zoi` - Schema validation for structured outputs

  """

  alias Puck.{Agent, Context, Response, Runtime}

  @agent_opts [:system_prompt, :hooks]
  @call_opts [:output_schema, :hooks, :backend_opts, :context]

  @doc """
  Calls an LLM and returns the response.

  ## Variants

  - `call(content, opts)` - Simple call with just content and options (requires `:model`)
  - `call(agent, content)` - Call with agent, creates fresh context
  - `call(agent, content, context)` - Full call with agent and context
  - `call(agent, content, context, opts)` - Full call with options

  ## Returns

  - `{:ok, response, updated_context}` on success
  - `{:error, reason}` on failure

  ## Examples

      # Simple call (no agent needed)
      {:ok, response, _ctx} = Puck.call("Hello!", model: "anthropic:claude-sonnet-4-5")

      # With system prompt
      {:ok, response, _ctx} = Puck.call("Translate to Spanish",
        model: "anthropic:claude-sonnet-4-5",
        system_prompt: "You are a translator."
      )

      # Multi-modal content (use Puck.Content)
      alias Puck.Content
      {:ok, response, _ctx} = Puck.call([
        Content.text("What's in this image?"),
        Content.image_url("https://example.com/cat.png")
      ], model: "anthropic:claude-sonnet-4-5")

      # Messages/conversation history (few-shot, context)
      {:ok, response, _ctx} = Puck.call([
        %{role: :user, content: "Translate: Hello"},
        %{role: :assistant, content: "Hola"},
        %{role: :user, content: "Translate: Goodbye"}
      ], model: "anthropic:claude-sonnet-4-5")

      # Multi-modal content in messages (role + images)
      alias Puck.Content
      {:ok, response, _ctx} = Puck.call([
        %{role: :user, content: [Content.text("What's this?"), Content.image_url("https://example.com/cat.png")]},
        %{role: :assistant, content: "I see a cat."},
        %{role: :user, content: "What color is it?"}
      ], model: "anthropic:claude-sonnet-4-5")

      # With explicit agent (no context)
      agent = Puck.Agent.new({Puck.Backends.Mock, response: "Hello!"})
      {:ok, response, _ctx} = Puck.call(agent, "Hello!")

      # Full explicit call
      context = Puck.Context.new()
      {:ok, response, context} = Puck.call(agent, "Hello!", context)

  """
  @spec call(Agent.t(), term()) :: {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(%Agent{} = agent, content) do
    {context, final_content} = build_context_from_content(content)
    Runtime.call(agent, final_content, context, [])
  end

  @spec call(term(), keyword()) :: {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(content, opts) when is_list(opts) do
    model =
      Keyword.get(opts, :model) ||
        raise ArgumentError,
              "model option is required, e.g. model: \"anthropic:claude-sonnet-4-5\""

    {agent_opts, rest} = Keyword.split(opts, @agent_opts)
    {call_opts, rest} = Keyword.split(rest, @call_opts)
    {base_context, call_opts} = Keyword.pop(call_opts, :context, Context.new())
    {backend, backend_config} = Keyword.pop(rest, :backend, default_backend())
    backend_config = Keyword.delete(backend_config, :model)

    agent = Agent.new({backend, Map.new([{:model, model} | backend_config])}, agent_opts)
    {context, final_content} = build_context_from_content(content, base_context)

    Runtime.call(agent, final_content, context, call_opts)
  end

  @spec call(Agent.t(), term(), Context.t(), keyword()) ::
          {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(%Agent{} = agent, content, %Context{} = context, opts \\ []) do
    Runtime.call(agent, content, context, opts)
  end

  @doc """
  Streams an LLM response.

  ## Variants

  - `stream(content, opts)` - Simple stream with just content and options (requires `:model`)
  - `stream(agent, content)` - Stream with agent, creates fresh context
  - `stream(agent, content, context)` - Full stream with agent and context
  - `stream(agent, content, context, opts)` - Full stream with options

  ## Returns

  - `{:ok, stream, updated_context}` where stream is an `Enumerable` of chunks
  - `{:error, reason}` on failure

  ## Examples

      # Simple stream (no agent needed)
      {:ok, stream, _ctx} = Puck.stream("Tell me a story", model: "anthropic:claude-sonnet-4-5")
      Enum.each(stream, fn chunk -> IO.write(chunk.content) end)

      # With explicit agent (no context)
      agent = Puck.Agent.new({Puck.Backends.Mock, stream_chunks: ["Hello", " ", "world"]})
      {:ok, stream, _ctx} = Puck.stream(agent, "Tell me a story")

      # Full explicit call
      context = Puck.Context.new()
      {:ok, stream, _context} = Puck.stream(agent, "Tell me a story", context)

  """
  @spec stream(Agent.t(), term()) :: {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(%Agent{} = agent, content) do
    {context, final_content} = build_context_from_content(content)
    Runtime.stream(agent, final_content, context, [])
  end

  @spec stream(term(), keyword()) :: {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(content, opts) when is_list(opts) do
    model =
      Keyword.get(opts, :model) ||
        raise ArgumentError,
              "model option is required, e.g. model: \"anthropic:claude-sonnet-4-5\""

    {agent_opts, rest} = Keyword.split(opts, @agent_opts)
    {call_opts, rest} = Keyword.split(rest, @call_opts)
    {base_context, call_opts} = Keyword.pop(call_opts, :context, Context.new())
    {backend, backend_config} = Keyword.pop(rest, :backend, default_backend())
    backend_config = Keyword.delete(backend_config, :model)

    agent = Agent.new({backend, Map.new([{:model, model} | backend_config])}, agent_opts)
    {context, final_content} = build_context_from_content(content, base_context)

    Runtime.stream(agent, final_content, context, call_opts)
  end

  @spec stream(Agent.t(), term(), Context.t(), keyword()) ::
          {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(%Agent{} = agent, content, %Context{} = context, opts \\ []) do
    Runtime.stream(agent, content, context, opts)
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

  defp default_backend do
    case Application.get_env(:puck, :default_backend) do
      nil ->
        if Code.ensure_loaded?(Puck.Backends.ReqLLM) do
          Puck.Backends.ReqLLM
        else
          raise ArgumentError,
                "No backend available. Add {:req_llm, \"~> 1.0\"} to deps or configure :default_backend."
        end

      backend ->
        backend
    end
  end
end
