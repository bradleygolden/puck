defmodule Puck.Runtime do
  @moduledoc false

  alias Puck.{Client, Context, Error, Hooks, Message, Response}

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
  @spec call(Client.t(), term(), Context.t(), keyword()) ::
          {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(%Client{} = client, content, %Context{} = context, opts \\ []) do
    {hooks_opt, opts} = Keyword.pop(opts, :hooks)
    {output_schema, opts} = Keyword.pop(opts, :output_schema)
    {backend_opts, _rest} = Keyword.pop(opts, :backend_opts, [])
    hooks = Hooks.merge(client.hooks, hooks_opt)
    call_opts = [output_schema: output_schema, backend_opts: backend_opts]

    with {:cont, transformed_content} <-
           Hooks.invoke(hooks, :on_call_start, [client, content, context], content)
           |> wrap_hook_error(:on_call_start),
         {:ok, response, updated_context} <-
           do_call(client, transformed_content, context, hooks, call_opts),
         {:cont, final_response} <-
           Hooks.invoke(hooks, :on_call_end, [client, response, updated_context], response)
           |> wrap_hook_error(:on_call_end) do
      {:ok, final_response, updated_context}
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
  @spec stream(Client.t(), term(), Context.t(), keyword()) ::
          {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(%Client{} = client, content, %Context{} = context, opts \\ []) do
    {hooks_opt, opts} = Keyword.pop(opts, :hooks)
    {backend_opts, _rest} = Keyword.pop(opts, :backend_opts, [])
    hooks = Hooks.merge(client.hooks, hooks_opt)
    stream_opts = [backend_opts: backend_opts]

    case Hooks.invoke(hooks, :on_stream_start, [client, content, context], content) do
      {:cont, transformed_content} ->
        do_stream(client, transformed_content, context, hooks, stream_opts)

      {:error, reason} ->
        {:error, Error.wrap_hook(:on_stream_start, reason)}
    end
  end

  # Private implementation

  defp do_call(client, content, context, hooks, opts) do
    backend_module = Client.backend_module(client)
    messages = build_messages(client, content, context)
    config = build_backend_config(client)

    with {:cont, transformed_messages} <-
           Hooks.invoke(hooks, :on_backend_request, [config, messages], messages)
           |> wrap_hook_error(:on_backend_request),
         {:ok, response} <-
           backend_module.call(config, transformed_messages, opts)
           |> wrap_backend_error(backend_module),
         {:cont, transformed_response} <-
           Hooks.invoke(hooks, :on_backend_response, [config, response], response)
           |> wrap_hook_error(:on_backend_response) do
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
           Hooks.invoke(hooks, :on_backend_request, [config, messages], messages)
           |> wrap_hook_error(:on_backend_request),
         {:ok, stream} <-
           backend_module.stream(config, transformed_messages, opts)
           |> wrap_backend_error(backend_module) do
      instrumented_stream = instrument_stream(stream, client, context, hooks)
      updated_context = Context.add_message(context, :user, content)
      {:ok, instrumented_stream, updated_context}
    else
      {:halt, _response} ->
        {:error, {:stream, :halted_by_hook}}

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
  end

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

  # Error wrapping helpers

  defp wrap_hook_error({:error, reason}, callback) do
    {:error, Error.wrap_hook(callback, reason)}
  end

  defp wrap_hook_error(result, _callback), do: result

  defp wrap_backend_error({:error, reason}, backend_module) do
    {:error, Error.wrap_backend(backend_module, reason)}
  end

  defp wrap_backend_error(result, _backend_module), do: result
end
