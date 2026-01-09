defmodule Puck.Runtime do
  @moduledoc false

  alias Puck.{Client, Compaction, Context, Hooks, Message, Response}
  alias Puck.Runtime.Telemetry, as: T

  @doc """
  Executes a synchronous call to a client.

  ## Parameters

  - `client` - The client configuration
  - `content` - The user's message (string, multi-modal list, or any term)
  - `context` - The conversation context
  - `opts` - Additional options:
    - `:hooks` - Hook module(s) for this call (merged with client hooks)
    - `:output_schema` - Zoi schema to parse the response content
    - `:backend_opts` - Options passed through to the backend

  ## Returns

  - `{:ok, response, updated_context}` on success
  - `{:error, reason}` on failure

  """
  def call(%Client{} = client, content, %Context{} = context, opts \\ []) do
    {hooks_opt, opts} = Keyword.pop(opts, :hooks)
    {output_schema, opts} = Keyword.pop(opts, :output_schema)
    {backend_opts, _rest} = Keyword.pop(opts, :backend_opts, [])
    hooks = Hooks.merge(client.hooks, hooks_opt)
    call_opts = [output_schema: output_schema, backend_opts: backend_opts]

    start_time = T.start([:call], %{client: client, prompt: content, context: context})

    with {:cont, transformed_content} <-
           Hooks.invoke(hooks, :on_call_start, [client, content, context], content),
         {:ok, response, updated_context} <-
           do_call(client, transformed_content, context, hooks, call_opts),
         {:cont, final_response} <-
           Hooks.invoke(hooks, :on_call_end, [client, response, updated_context], response) do
      final_context = maybe_auto_compact(client, updated_context, hooks)

      T.stop([:call], start_time, %{
        client: client,
        response: final_response,
        context: final_context
      })

      {:ok, final_response, final_context}
    else
      {:halt, response} ->
        updated_context = add_exchange_to_context(context, content, response)

        T.stop([:call], start_time, %{
          client: client,
          response: response,
          context: updated_context
        })

        {:ok, response, updated_context}

      {:error, reason} ->
        T.exception([:call], start_time, reason, %{client: client, context: context})
        Hooks.invoke(hooks, :on_call_error, [client, reason, context])
        {:error, reason}
    end
  end

  @doc """
  Executes a streaming call to a client.

  ## Parameters

  - `client` - The client configuration
  - `content` - The user's message (string, multi-modal list, or any term)
  - `context` - The conversation context
  - `opts` - Additional options:
    - `:hooks` - Hook module(s) for this call (merged with client hooks)
    - `:backend_opts` - Options passed through to the backend

  ## Returns

  - `{:ok, stream, context_with_user_message}` on success
  - `{:error, reason}` on failure

  Note: The returned context only includes the user message. The assistant's
  response should be accumulated from the stream and added separately.

  """
  def stream(%Client{} = client, content, %Context{} = context, opts \\ []) do
    {hooks_opt, opts} = Keyword.pop(opts, :hooks)
    {output_schema, opts} = Keyword.pop(opts, :output_schema)
    {backend_opts, _rest} = Keyword.pop(opts, :backend_opts, [])
    hooks = Hooks.merge(client.hooks, hooks_opt)
    stream_opts = [output_schema: output_schema, backend_opts: backend_opts]

    compacted_context = maybe_auto_compact(client, context, hooks)

    start_time =
      T.start([:stream], %{client: client, prompt: content, context: compacted_context})

    case Hooks.invoke(hooks, :on_stream_start, [client, content, compacted_context], content) do
      {:cont, transformed_content} ->
        do_stream(client, transformed_content, compacted_context, hooks, stream_opts, start_time)

      {:error, reason} ->
        T.exception([:stream], start_time, reason, %{client: client, context: compacted_context})
        {:error, reason}
    end
  end

  defp do_call(client, content, context, hooks, opts) do
    backend_module = Client.backend_module(client)
    messages = build_messages(client, content, context)
    config = build_backend_config(client)

    T.event([:backend, :request], %{system_time: System.system_time()}, %{
      config: config,
      messages: messages
    })

    with {:cont, transformed_messages} <-
           Hooks.invoke(hooks, :on_backend_request, [config, messages], messages),
         {:ok, response} <- backend_module.call(config, transformed_messages, opts),
         {:cont, transformed_response} <-
           Hooks.invoke(hooks, :on_backend_response, [config, response], response) do
      T.event([:backend, :response], %{system_time: System.system_time()}, %{
        config: config,
        response: transformed_response
      })

      updated_context = add_exchange_to_context(context, content, transformed_response)
      {:ok, transformed_response, updated_context}
    else
      {:halt, response} ->
        T.event([:backend, :response], %{system_time: System.system_time()}, %{
          config: config,
          response: response
        })

        updated_context = add_exchange_to_context(context, content, response)
        {:ok, response, updated_context}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_stream(client, content, context, hooks, opts, start_time) do
    backend_module = Client.backend_module(client)
    messages = build_messages(client, content, context)
    config = build_backend_config(client)

    T.event([:backend, :request], %{system_time: System.system_time()}, %{
      config: config,
      messages: messages
    })

    with {:cont, transformed_messages} <-
           Hooks.invoke(hooks, :on_backend_request, [config, messages], messages),
         {:ok, stream} <- backend_module.stream(config, transformed_messages, opts) do
      instrumented_stream = instrument_stream(stream, client, context, hooks, start_time)
      updated_context = Context.add_message(context, :user, content)
      {:ok, instrumented_stream, updated_context}
    else
      {:halt, _response} ->
        {:error, :stream_halted_by_hook}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp instrument_stream(stream, client, context, hooks, start_time) do
    stream
    |> Stream.each(fn chunk ->
      T.event([:stream, :chunk], %{}, %{client: client, chunk: chunk, context: context})
      Hooks.invoke(hooks, :on_stream_chunk, [client, chunk, context])
    end)
    |> Stream.transform(
      fn -> :ok end,
      fn chunk, acc -> {[chunk], acc} end,
      fn _acc ->
        T.stop([:stream], start_time, %{client: client, context: context})
        Hooks.invoke(hooks, :on_stream_end, [client, context])
      end
    )
  end

  defp add_exchange_to_context(context, user_content, %Response{} = response) do
    context
    |> Context.add_message(:user, user_content)
    |> Context.add_message(:assistant, response.content, response.metadata)
    |> track_token_usage(response)
  end

  defp track_token_usage(context, %Response{usage: usage}) when map_size(usage) > 0 do
    current_total = Context.get_metadata(context, :total_tokens, 0)
    response_tokens = Response.total_tokens(%Response{usage: usage}) || 0
    Context.put_metadata(context, :total_tokens, current_total + response_tokens)
  end

  defp track_token_usage(context, _response), do: context

  defp build_messages(client, content, context) do
    system_messages =
      case client.system_prompt do
        nil -> []
        prompt -> [Message.new(:system, prompt)]
      end

    context_messages = Context.messages(context)
    user_message = Message.new(:user, content)

    system_messages ++ context_messages ++ [user_message]
  end

  defp build_backend_config(client) do
    {_type, backend_config} = client.backend
    backend_config
  end

  defp maybe_auto_compact(%Client{auto_compaction: auto_config} = client, context, hooks) do
    case normalize_compaction_config(auto_config, client) do
      nil -> context
      {strategy, config} -> do_auto_compact(context, strategy, config, hooks)
    end
  end

  defp do_auto_compact(context, strategy, config, hooks) do
    if Compaction.should_compact?(context, {strategy, config}) do
      run_compaction(context, strategy, config, hooks)
    else
      context
    end
  end

  defp run_compaction(context, strategy, config, hooks) do
    case Hooks.invoke(hooks, :on_compaction_start, [context, strategy, config], context) do
      {:halt, halted_context} ->
        halted_context

      {:cont, transformed_context} ->
        execute_compaction(transformed_context, strategy, config, hooks)

      {:error, _reason} ->
        context
    end
  end

  defp execute_compaction(context, strategy, config, hooks) do
    start_time = System.monotonic_time()
    messages_before = Context.message_count(context)
    emit_compaction_start(context, strategy, config)

    case Compaction.compact(context, {strategy, config}) do
      {:ok, compacted} ->
        emit_compaction_stop(start_time, messages_before, compacted, strategy)
        finalize_compaction(compacted, strategy, hooks)

      {:error, reason} ->
        emit_compaction_error(start_time, context, reason, strategy)
        context
    end
  end

  defp finalize_compaction(compacted, strategy, hooks) do
    case Hooks.invoke(hooks, :on_compaction_end, [compacted, strategy], compacted) do
      {:cont, final} -> final
      {:error, _} -> compacted
    end
  end

  defp normalize_compaction_config(nil, _client), do: nil
  defp normalize_compaction_config(false, _client), do: nil

  defp normalize_compaction_config({:summarize, opts}, client) when is_list(opts) do
    unless Keyword.has_key?(opts, :max_tokens) do
      raise ArgumentError,
            "auto_compaction: {:summarize, opts} requires :max_tokens option"
    end

    base_config = %{
      max_tokens: Keyword.fetch!(opts, :max_tokens),
      keep_last: Keyword.get(opts, :keep_last, 3),
      prompt: Keyword.get(opts, :prompt)
    }

    config =
      case Keyword.get(opts, :client) do
        nil -> add_default_backend_config(base_config, client)
        explicit_client -> Map.put(base_config, :client, explicit_client)
      end

    {Puck.Compaction.Summarize, config}
  end

  defp normalize_compaction_config({:sliding_window, opts}, _client) when is_list(opts) do
    config = opts |> Map.new() |> Map.put_new(:window_size, 20)
    {Puck.Compaction.SlidingWindow, config}
  end

  defp normalize_compaction_config({module, config}, _client)
       when is_atom(module) and is_map(config) do
    {module, config}
  end

  defp normalize_compaction_config({module, opts}, _client)
       when is_atom(module) and is_list(opts) do
    {module, Map.new(opts)}
  end

  defp add_default_backend_config(config, client) do
    case client.backend do
      {Puck.Backends.Baml, baml_config} ->
        Map.put(config, :client_registry, baml_config[:client_registry])

      _other_backend ->
        Map.put(config, :client, Client.new(client.backend))
    end
  end

  defp emit_compaction_start(context, strategy, config) do
    T.event([:compaction, :start], %{system_time: System.system_time()}, %{
      context: context,
      strategy: strategy,
      config: config
    })
  end

  defp emit_compaction_stop(start_time, messages_before, compacted, strategy) do
    duration = System.monotonic_time() - start_time

    T.event(
      [:compaction, :stop],
      %{
        duration: duration,
        messages_before: messages_before,
        messages_after: Context.message_count(compacted)
      },
      %{context: compacted, strategy: strategy}
    )
  end

  defp emit_compaction_error(start_time, context, reason, strategy) do
    duration = System.monotonic_time() - start_time

    T.event([:compaction, :error], %{duration: duration}, %{
      context: context,
      strategy: strategy,
      reason: reason
    })
  end
end
