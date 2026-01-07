defmodule Puck.Runtime do
  @moduledoc false

  alias Puck.{Client, Compaction, Context, Hooks, Message, Response}

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

    with {:cont, transformed_content} <-
           Hooks.invoke(hooks, :on_call_start, [client, content, context], content),
         {:ok, response, updated_context} <-
           do_call(client, transformed_content, context, hooks, call_opts),
         {:cont, final_response} <-
           Hooks.invoke(hooks, :on_call_end, [client, response, updated_context], response) do
      final_context = maybe_auto_compact(client, updated_context, hooks)
      {:ok, final_response, final_context}
    else
      {:halt, response} ->
        updated_context = add_exchange_to_context(context, content, response)
        {:ok, response, updated_context}

      {:error, reason} ->
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

    case Hooks.invoke(hooks, :on_stream_start, [client, content, compacted_context], content) do
      {:cont, transformed_content} ->
        do_stream(client, transformed_content, compacted_context, hooks, stream_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_call(client, content, context, hooks, opts) do
    backend_module = Client.backend_module(client)
    messages = build_messages(client, content, context)
    config = build_backend_config(client)

    with {:cont, transformed_messages} <-
           Hooks.invoke(hooks, :on_backend_request, [config, messages], messages),
         {:ok, response} <- backend_module.call(config, transformed_messages, opts),
         {:cont, transformed_response} <-
           Hooks.invoke(hooks, :on_backend_response, [config, response], response) do
      updated_context = add_exchange_to_context(context, content, transformed_response)
      {:ok, transformed_response, updated_context}
    else
      {:halt, response} ->
        updated_context = add_exchange_to_context(context, content, response)
        {:ok, response, updated_context}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_stream(client, content, context, hooks, opts) do
    backend_module = Client.backend_module(client)
    messages = build_messages(client, content, context)
    config = build_backend_config(client)

    with {:cont, transformed_messages} <-
           Hooks.invoke(hooks, :on_backend_request, [config, messages], messages),
         {:ok, stream} <- backend_module.stream(config, transformed_messages, opts) do
      instrumented_stream = instrument_stream(stream, client, context, hooks)
      updated_context = Context.add_message(context, :user, content)
      {:ok, instrumented_stream, updated_context}
    else
      {:halt, _response} ->
        {:error, :stream_halted_by_hook}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp instrument_stream(stream, client, context, hooks) do
    stream
    |> Stream.each(fn chunk ->
      Hooks.invoke(hooks, :on_stream_chunk, [client, chunk, context])
    end)
    |> Stream.transform(
      fn -> :ok end,
      fn chunk, acc -> {[chunk], acc} end,
      fn _acc -> Hooks.invoke(hooks, :on_stream_end, [client, context]) end
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

    summarize_client = get_summarize_client(client, opts)

    config =
      opts |> Map.new() |> Map.put(:client, summarize_client) |> Map.put_new(:keep_last, 3)

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

  defp get_summarize_client(client, opts) do
    case Keyword.get(opts, :client) do
      nil -> create_default_summarize_client(client)
      explicit_client -> explicit_client
    end
  end

  defp create_default_summarize_client(client) do
    case client.backend do
      {Puck.Backends.Baml, _config} ->
        raise ArgumentError, """
        auto_compaction: {:summarize, opts} requires explicit :client option when using BAML backend.

        BAML functions are compile-time specific. To use summarization with BAML:

        1. Define a summarization function in your .baml files
        2. Create a client for it and pass via :client option:

            summarize_client = Puck.Client.new({Puck.Backends.Baml, function: "SummarizeConversation"})

            Puck.Client.new({Puck.Backends.Baml, function: "MyFunction"},
              auto_compaction: {:summarize, max_tokens: 100_000, client: summarize_client}
            )

        Or use a ReqLLM client for summarization:

            summarize_client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-haiku"})

            Puck.Client.new({Puck.Backends.Baml, function: "MyFunction"},
              auto_compaction: {:summarize, max_tokens: 100_000, client: summarize_client}
            )

        Alternatively, use :sliding_window which doesn't require LLM calls:

            auto_compaction: {:sliding_window, window_size: 30}
        """

      _other_backend ->
        Client.new(client.backend)
    end
  end

  if Code.ensure_loaded?(:telemetry) do
    defp emit_compaction_start(context, strategy, config) do
      :telemetry.execute(
        [:puck, :compaction, :start],
        %{system_time: System.system_time()},
        %{context: context, strategy: strategy, config: config}
      )
    end

    defp emit_compaction_stop(start_time, messages_before, compacted, strategy) do
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:puck, :compaction, :stop],
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

      :telemetry.execute(
        [:puck, :compaction, :error],
        %{duration: duration},
        %{context: context, strategy: strategy, reason: reason}
      )
    end
  else
    defp emit_compaction_start(_context, _strategy, _config), do: :ok
    defp emit_compaction_stop(_start_time, _messages_before, _compacted, _strategy), do: :ok
    defp emit_compaction_error(_start_time, _context, _reason, _strategy), do: :ok
  end
end
