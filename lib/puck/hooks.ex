defmodule Puck.Hooks do
  @moduledoc """
  Behaviour for lifecycle hooks.

  Hooks observe and transform data at each stage of client execution.
  All callbacks are optional.

  ## Return Types

  - `{:cont, value}` - Continue with value
  - `{:halt, response}` - Short-circuit with response
  - `{:error, reason}` - Abort with error

  ## Callbacks

  - `on_call_start/3` - Before LLM call
  - `on_call_end/3` - After successful call
  - `on_call_error/3` - On call failure
  - `on_stream_start/3`, `on_stream_chunk/3`, `on_stream_end/2` - Stream lifecycle
  - `on_backend_request/2`, `on_backend_response/2` - Backend lifecycle
  - `on_compaction_start/3`, `on_compaction_end/2` - Compaction lifecycle

  ## Example

      defmodule MyApp.LoggingHooks do
        @behaviour Puck.Hooks
        require Logger

        @impl true
        def on_call_start(_client, content, _context) do
          Logger.info("Call started")
          {:cont, content}
        end

        @impl true
        def on_call_end(_client, response, _context) do
          Logger.info("Call completed")
          {:cont, response}
        end
      end

  ## Usage

      client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        hooks: MyApp.LoggingHooks
      )

      # Multiple hooks execute in order
      Puck.call(client, "Hello", context,
        hooks: [Puck.Telemetry.Hooks, MyApp.LoggingHooks]
      )

  """

  alias Puck.Response

  @type client :: Puck.Client.t()
  @type context :: Puck.Context.t()
  @type response :: Response.t()
  @type messages :: [map()]
  @type config :: map()
  @type chunk :: map()

  @callback on_call_start(client, content :: term(), context) ::
              {:cont, term()} | {:halt, response} | {:error, term()}
  @callback on_call_end(client, response, context) ::
              {:cont, response} | {:error, term()}
  @callback on_call_error(client, error :: term(), context) :: term()

  @callback on_stream_start(client, content :: term(), context) ::
              {:cont, term()} | {:error, term()}
  @callback on_stream_chunk(client, chunk, context) :: term()
  @callback on_stream_end(client, context) :: term()

  @callback on_backend_request(config, messages) ::
              {:cont, messages} | {:halt, response} | {:error, term()}
  @callback on_backend_response(config, response) ::
              {:cont, response} | {:error, term()}

  @callback on_compaction_start(context, strategy :: module(), config :: map()) ::
              {:cont, context} | {:halt, context} | {:error, term()}
  @callback on_compaction_end(context, strategy :: module()) ::
              {:cont, context} | {:error, term()}

  @optional_callbacks on_call_start: 3,
                      on_call_end: 3,
                      on_call_error: 3,
                      on_stream_start: 3,
                      on_stream_chunk: 3,
                      on_stream_end: 2,
                      on_backend_request: 2,
                      on_backend_response: 2,
                      on_compaction_start: 3,
                      on_compaction_end: 2

  @doc """
  Invokes a transforming hook callback on the given hook module(s).

  Returns the transformed value, a halt response, or an error.
  If a callback is not implemented, the initial value is passed through.

  ## Returns

  - `{:cont, value}` - Continue with (possibly transformed) value
  - `{:halt, response}` - Short-circuit with a response
  - `{:error, reason}` - Abort with error
  """
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
  Merges client-level hooks with per-call hooks.

  Per-call hooks come after client-level hooks (client hooks run first).
  """
  def merge(nil, nil), do: nil
  def merge(client_hooks, nil), do: normalize(client_hooks)
  def merge(nil, call_hooks), do: normalize(call_hooks)

  def merge(client_hooks, call_hooks) do
    normalize(client_hooks) ++ normalize(call_hooks)
  end

  defp normalize(nil), do: []
  defp normalize(hooks) when is_list(hooks), do: hooks
  defp normalize(hook) when is_atom(hook), do: [hook]
end
