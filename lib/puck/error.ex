defmodule Puck.Error do
  @moduledoc """
  Structured error types for Puck operations.

  Puck uses tagged tuples for errors, following Elixir conventions. This module
  defines the error structure and provides helper functions for introspection.

  ## Error Structure

  All errors follow the pattern `{:error, reason}` where `reason` is a tagged tuple:

      {:error, {:hook, stage, original_reason}}
      {:error, {:backend, backend_module, original_reason}}
      {:error, {:validation, message}}

  ## Examples

      case Puck.call(client, "Hello") do
        {:ok, response, context} ->
          response.content

        {:error, {:hook, :on_call_start, :blocked}} ->
          "Blocked by guardrails"

        {:error, {:backend, Puck.Backends.ReqLLM, :timeout}} ->
          "Request timed out"

        {:error, reason} ->
          "Unknown error: \#{inspect(reason)}"
      end

  ## Helper Functions

      error = {:backend, Puck.Backends.ReqLLM, :rate_limited}

      Puck.Error.stage(error)   # => :backend
      Puck.Error.reason(error)  # => :rate_limited
      Puck.Error.message(error) # => "Backend Puck.Backends.ReqLLM error: rate_limited"

  """

  @typedoc """
  The stage where an error occurred.

  - `:hook` - Error from a hook callback
  - `:backend` - Error from the LLM backend
  - `:validation` - Input validation error
  - `:stream` - Error during streaming
  """
  @type stage :: :hook | :backend | :validation | :stream

  @typedoc """
  Hook callback names that can produce errors.
  """
  @type hook_callback ::
          :on_call_start
          | :on_call_end
          | :on_stream_start
          | :on_backend_request
          | :on_backend_response

  @typedoc """
  Structured error reasons.

  - `{:hook, callback, reason}` - Hook returned an error
  - `{:backend, module, reason}` - Backend call failed
  - `{:validation, message}` - Input validation failed
  - `{:stream, reason}` - Streaming error
  - `term()` - Unstructured legacy error (pass-through)
  """
  @type reason ::
          {:hook, hook_callback(), term()}
          | {:backend, module(), term()}
          | {:validation, String.t()}
          | {:stream, term()}
          | term()

  @doc """
  Returns the stage where the error occurred.

  ## Examples

      iex> Puck.Error.stage({:hook, :on_call_start, :blocked})
      :hook

      iex> Puck.Error.stage({:backend, Puck.Backends.ReqLLM, :timeout})
      :backend

      iex> Puck.Error.stage(:some_legacy_error)
      :unknown

  """
  @spec stage(reason()) :: stage() | :unknown
  def stage({:hook, _callback, _reason}), do: :hook
  def stage({:backend, _module, _reason}), do: :backend
  def stage({:validation, _message}), do: :validation
  def stage({:stream, _reason}), do: :stream
  def stage(_), do: :unknown

  @doc """
  Extracts the underlying reason from a structured error.

  ## Examples

      iex> Puck.Error.reason({:hook, :on_call_start, :blocked})
      :blocked

      iex> Puck.Error.reason({:backend, Puck.Backends.ReqLLM, {:timeout, 5000}})
      {:timeout, 5000}

      iex> Puck.Error.reason(:legacy_error)
      :legacy_error

  """
  @spec reason(reason()) :: term()
  def reason({:hook, _callback, reason}), do: reason
  def reason({:backend, _module, reason}), do: reason
  def reason({:validation, message}), do: message
  def reason({:stream, reason}), do: reason
  def reason(reason), do: reason

  @doc """
  Returns the hook callback name for hook errors.

  ## Examples

      iex> Puck.Error.callback({:hook, :on_call_start, :blocked})
      :on_call_start

      iex> Puck.Error.callback({:backend, Puck.Backends.ReqLLM, :timeout})
      nil

  """
  @spec callback(reason()) :: hook_callback() | nil
  def callback({:hook, callback, _reason}), do: callback
  def callback(_), do: nil

  @doc """
  Returns the backend module for backend errors.

  ## Examples

      iex> Puck.Error.backend({:backend, Puck.Backends.ReqLLM, :timeout})
      Puck.Backends.ReqLLM

      iex> Puck.Error.backend({:hook, :on_call_start, :blocked})
      nil

  """
  @spec backend(reason()) :: module() | nil
  def backend({:backend, module, _reason}), do: module
  def backend(_), do: nil

  @doc """
  Returns a human-readable error message.

  ## Examples

      iex> Puck.Error.message({:hook, :on_call_start, :blocked})
      "Hook on_call_start error: blocked"

      iex> Puck.Error.message({:backend, Puck.Backends.ReqLLM, :timeout})
      "Backend Elixir.Puck.Backends.ReqLLM error: timeout"

      iex> Puck.Error.message({:validation, "content cannot be empty"})
      "Validation error: content cannot be empty"

  """
  @spec message(reason()) :: String.t()
  def message({:hook, callback, reason}) do
    "Hook #{callback} error: #{format_reason(reason)}"
  end

  def message({:backend, module, reason}) do
    "Backend #{module} error: #{format_reason(reason)}"
  end

  def message({:validation, msg}) do
    "Validation error: #{msg}"
  end

  def message({:stream, reason}) do
    "Stream error: #{format_reason(reason)}"
  end

  def message(reason) do
    "Error: #{format_reason(reason)}"
  end

  @doc """
  Checks if an error is structured (has stage information).

  ## Examples

      iex> Puck.Error.structured?({:hook, :on_call_start, :blocked})
      true

      iex> Puck.Error.structured?(:legacy_error)
      false

  """
  @spec structured?(reason()) :: boolean()
  def structured?({:hook, _, _}), do: true
  def structured?({:backend, _, _}), do: true
  def structured?({:validation, _}), do: true
  def structured?({:stream, _}), do: true
  def structured?(_), do: false

  @doc """
  Wraps an error reason with hook context.

  Used internally by `Puck.Runtime` to add context to hook errors.
  """
  @spec wrap_hook(hook_callback(), term()) :: {:hook, hook_callback(), term()}
  def wrap_hook(callback, reason), do: {:hook, callback, reason}

  @doc """
  Wraps an error reason with backend context.

  Used internally by `Puck.Runtime` to add context to backend errors.
  """
  @spec wrap_backend(module(), term()) :: {:backend, module(), term()}
  def wrap_backend(module, reason), do: {:backend, module, reason}

  # Private helpers

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
