defmodule Puck.Hooks do
  @moduledoc """
  Behaviour for hooking into Puck lifecycle events with transformation support.

  Hooks can observe and transform data at each stage of agent execution.
  They enable middleware-like patterns for caching, guardrails, logging,
  and response transformation.

  ## Return Types

  Most callbacks can return:
  - `{:cont, value}` - Continue with (possibly transformed) value
  - `{:halt, response}` - Short-circuit, skip remaining hooks and LLM call
  - `{:error, reason}` - Abort with error

  ## Events

  **Call lifecycle (transforming):**
  - `on_call_start/3` - Before an LLM call, can transform content
  - `on_call_end/3` - After a successful LLM call, can transform response
  - `on_call_error/3` - When an LLM call fails (observational only)

  **Stream lifecycle:**
  - `on_stream_start/3` - Before streaming, can transform content
  - `on_stream_chunk/3` - For each chunk (observational only)
  - `on_stream_end/2` - After streaming completes (observational only)

  **Backend lifecycle (transforming):**
  - `on_backend_request/2` - Before backend request, can transform messages
  - `on_backend_response/2` - After backend response, can transform response

  All callbacks are optional. Implement only the ones you need.

  ## Example - Logging (observational)

      defmodule MyApp.LoggingHooks do
        @behaviour Puck.Hooks
        require Logger

        @impl true
        def on_call_start(_agent, content, _context) do
          Logger.info("LLM call started: \#{inspect(content, limit: 50)}")
          {:cont, content}
        end

        @impl true
        def on_call_end(_agent, response, _context) do
          Logger.info("LLM call completed: \#{response.usage.output_tokens} tokens")
          {:cont, response}
        end
      end

  ## Example - Caching (transforming with halt)

  Response caching requires correlating the request messages with the response.
  Use an ETS table or cache server that can look up by message hash:

      defmodule MyApp.CachingHooks do
        @behaviour Puck.Hooks

        @impl true
        def on_backend_request(_config, messages) do
          cache_key = :erlang.phash2(messages)
          case MyApp.Cache.get(cache_key) do
            {:ok, cached} -> {:halt, cached}  # Skip LLM, return cached response
            :miss -> {:cont, messages}
          end
        end
      end

  For write-through caching, use `on_call_end` which has access to the context
  containing the original messages:

      defmodule MyApp.WriteThroughCache do
        @behaviour Puck.Hooks

        @impl true
        def on_call_end(_agent, response, context) do
          cache_key = :erlang.phash2(context.messages)
          MyApp.Cache.put(cache_key, response)
          {:cont, response}
        end
      end

  ## Example - Guardrails (transforming with error)

      defmodule MyApp.GuardrailsHooks do
        @behaviour Puck.Hooks

        @impl true
        def on_call_start(_agent, content, _context) do
          if contains_pii?(content) do
            {:error, :pii_detected}
          else
            {:cont, content}
          end
        end
      end

  ## Execution Order

  When multiple hooks are configured, they execute in order. Each transforming
  hook receives the output of the previous hook, enabling composition:

      # Hooks execute left to right: PrefixHooks first, then SuffixHooks
      hooks: [PrefixHooks, SuffixHooks]
      # "hello" -> "[prefix] hello" -> "[prefix] hello [suffix]"

  When combining agent-level and per-call hooks, agent hooks run first:

      agent = Puck.Agent.new({:mock, response: "Hi"},
        hooks: AgentHooks    # Runs first
      )

      Puck.call(agent, "Hello", context,
        hooks: CallHooks     # Runs second
      )

  ## Usage

      # Per-call hooks
      {:ok, response, ctx} = Puck.call(agent, "Hello", context,
        hooks: MyApp.CachingHooks
      )

      # Multiple hooks (all get called in order)
      {:ok, response, ctx} = Puck.call(agent, "Hello", context,
        hooks: [MyApp.CachingHooks, MyApp.LoggingHooks]
      )

      # Agent-level hooks (used for all calls with this agent)
      agent = Puck.Agent.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        hooks: MyApp.LoggingHooks
      )

  """

  alias Puck.Response

  @type agent :: Puck.Agent.t()
  @type context :: Puck.Context.t()
  @type response :: Response.t()
  @type messages :: [map()]
  @type config :: map()
  @type chunk :: map()

  # Call lifecycle - transforming
  @callback on_call_start(agent, content :: term(), context) ::
              {:cont, term()} | {:halt, response} | {:error, term()}
  @callback on_call_end(agent, response, context) ::
              {:cont, response} | {:error, term()}
  @callback on_call_error(agent, error :: term(), context) :: term()

  # Stream lifecycle
  @callback on_stream_start(agent, content :: term(), context) ::
              {:cont, term()} | {:error, term()}
  @callback on_stream_chunk(agent, chunk, context) :: term()
  @callback on_stream_end(agent, context) :: term()

  # Backend lifecycle - transforming
  @callback on_backend_request(config, messages) ::
              {:cont, messages} | {:halt, response} | {:error, term()}
  @callback on_backend_response(config, response) ::
              {:cont, response} | {:error, term()}

  @optional_callbacks on_call_start: 3,
                      on_call_end: 3,
                      on_call_error: 3,
                      on_stream_start: 3,
                      on_stream_chunk: 3,
                      on_stream_end: 2,
                      on_backend_request: 2,
                      on_backend_response: 2

  @doc """
  Invokes a transforming hook callback on the given hook module(s).

  Returns the transformed value, a halt response, or an error.
  If a callback is not implemented, the initial value is passed through.

  ## Returns

  - `{:cont, value}` - Continue with (possibly transformed) value
  - `{:halt, response}` - Short-circuit with a response
  - `{:error, reason}` - Abort with error
  """
  @spec invoke(module() | [module()] | nil, atom(), [term()], term()) ::
          {:cont, term()} | {:halt, Response.t()} | {:error, term()}
  def invoke(hooks, callback, args, initial_value)

  def invoke(nil, _callback, _args, value), do: {:cont, value}

  def invoke(hooks, callback, args, initial_value) when is_list(hooks) do
    Enum.reduce_while(hooks, {:cont, initial_value}, fn hook, {:cont, current_value} ->
      updated_args = List.replace_at(args, 1, current_value)

      case invoke_one(hook, callback, updated_args, current_value) do
        {:cont, new_value} -> {:cont, {:cont, new_value}}
        {:halt, response} -> {:halt, {:halt, response}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def invoke(hook, callback, args, value) when is_atom(hook) do
    invoke_one(hook, callback, args, value)
  end

  defp invoke_one(hook_module, callback, args, current_value) do
    Code.ensure_loaded(hook_module)

    if function_exported?(hook_module, callback, length(args)) do
      apply(hook_module, callback, args)
    else
      {:cont, current_value}
    end
  end

  @doc """
  Invokes an observational hook callback (return value is ignored).

  Used for callbacks like `on_call_error`, `on_stream_chunk`, `on_stream_end`
  where the return value doesn't affect the pipeline.
  """
  @spec invoke(module() | [module()] | nil, atom(), [term()]) :: :ok
  def invoke(hooks, callback, args)

  def invoke(nil, _callback, _args), do: :ok

  def invoke(hooks, callback, args) when is_list(hooks) do
    Enum.each(hooks, &invoke(&1, callback, args))
  end

  def invoke(hook_module, callback, args) when is_atom(hook_module) do
    Code.ensure_loaded(hook_module)

    if function_exported?(hook_module, callback, length(args)) do
      apply(hook_module, callback, args)
    end

    :ok
  end

  @doc """
  Merges agent-level hooks with per-call hooks.

  Per-call hooks come after agent-level hooks (agent hooks run first).
  """
  @spec merge(module() | [module()] | nil, module() | [module()] | nil) ::
          [module()] | nil
  def merge(nil, nil), do: nil
  def merge(agent_hooks, nil), do: normalize(agent_hooks)
  def merge(nil, call_hooks), do: normalize(call_hooks)

  def merge(agent_hooks, call_hooks) do
    normalize(agent_hooks) ++ normalize(call_hooks)
  end

  defp normalize(nil), do: []
  defp normalize(hooks) when is_list(hooks), do: hooks
  defp normalize(hook) when is_atom(hook), do: [hook]
end
