defmodule Puck.ErrorTest do
  use ExUnit.Case, async: true

  alias Puck.Error

  describe "stage/1" do
    test "returns :hook for hook errors" do
      assert Error.stage({:hook, :on_call_start, :blocked}) == :hook
    end

    test "returns :backend for backend errors" do
      assert Error.stage({:backend, Puck.Backends.ReqLLM, :timeout}) == :backend
    end

    test "returns :validation for validation errors" do
      assert Error.stage({:validation, "content cannot be empty"}) == :validation
    end

    test "returns :stream for stream errors" do
      assert Error.stage({:stream, :halted_by_hook}) == :stream
    end

    test "returns :unknown for unstructured errors" do
      assert Error.stage(:some_error) == :unknown
      assert Error.stage("string error") == :unknown
      assert Error.stage({:unexpected, :format}) == :unknown
    end
  end

  describe "reason/1" do
    test "extracts reason from hook errors" do
      assert Error.reason({:hook, :on_call_start, :blocked}) == :blocked
    end

    test "extracts reason from backend errors" do
      assert Error.reason({:backend, Puck.Backends.ReqLLM, {:timeout, 5000}}) == {:timeout, 5000}
    end

    test "extracts message from validation errors" do
      assert Error.reason({:validation, "bad input"}) == "bad input"
    end

    test "extracts reason from stream errors" do
      assert Error.reason({:stream, :halted_by_hook}) == :halted_by_hook
    end

    test "returns unstructured errors as-is" do
      assert Error.reason(:legacy_error) == :legacy_error
      assert Error.reason("string error") == "string error"
    end
  end

  describe "callback/1" do
    test "returns callback name for hook errors" do
      assert Error.callback({:hook, :on_call_start, :blocked}) == :on_call_start
      assert Error.callback({:hook, :on_backend_request, :failed}) == :on_backend_request
    end

    test "returns nil for non-hook errors" do
      assert Error.callback({:backend, Puck.Backends.Mock, :error}) == nil
      assert Error.callback(:legacy_error) == nil
    end
  end

  describe "backend/1" do
    test "returns module for backend errors" do
      assert Error.backend({:backend, Puck.Backends.ReqLLM, :timeout}) == Puck.Backends.ReqLLM
      assert Error.backend({:backend, Puck.Backends.Mock, :error}) == Puck.Backends.Mock
    end

    test "returns nil for non-backend errors" do
      assert Error.backend({:hook, :on_call_start, :blocked}) == nil
      assert Error.backend(:legacy_error) == nil
    end
  end

  describe "message/1" do
    test "formats hook errors" do
      assert Error.message({:hook, :on_call_start, :blocked}) ==
               "Hook on_call_start error: blocked"
    end

    test "formats backend errors" do
      msg = Error.message({:backend, Puck.Backends.ReqLLM, :timeout})
      assert msg =~ "Backend"
      assert msg =~ "ReqLLM"
      assert msg =~ "timeout"
    end

    test "formats validation errors" do
      assert Error.message({:validation, "content cannot be empty"}) ==
               "Validation error: content cannot be empty"
    end

    test "formats stream errors" do
      assert Error.message({:stream, :halted_by_hook}) ==
               "Stream error: halted_by_hook"
    end

    test "formats unstructured errors" do
      assert Error.message(:some_error) == "Error: some_error"
    end
  end

  describe "structured?/1" do
    test "returns true for structured errors" do
      assert Error.structured?({:hook, :on_call_start, :blocked})
      assert Error.structured?({:backend, Puck.Backends.Mock, :error})
      assert Error.structured?({:validation, "message"})
      assert Error.structured?({:stream, :halted})
    end

    test "returns false for unstructured errors" do
      refute Error.structured?(:legacy_error)
      refute Error.structured?("string error")
      refute Error.structured?({:unexpected, :format})
    end
  end

  describe "wrap_hook/2" do
    test "wraps reason with hook context" do
      assert Error.wrap_hook(:on_call_start, :blocked) ==
               {:hook, :on_call_start, :blocked}
    end
  end

  describe "wrap_backend/2" do
    test "wraps reason with backend context" do
      assert Error.wrap_backend(Puck.Backends.Mock, :timeout) ==
               {:backend, Puck.Backends.Mock, :timeout}
    end
  end
end
