defmodule PuckTest do
  use ExUnit.Case, async: true

  alias Puck.{Client, Content, Context}

  describe "call/4 with mock backend" do
    test "returns a response and updated context" do
      client = Client.new({Puck.Backends.Mock, response: "Hello from mock!"})
      context = Context.new()

      assert {:ok, response, updated_context} = Puck.call(client, "Hi!", context)

      assert response.content == "Hello from mock!"
      assert Context.message_count(updated_context) == 2

      messages = Context.messages(updated_context)
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 0).content == [Content.text("Hi!")]
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).content == [Content.text("Hello from mock!")]
    end

    test "includes system prompt in messages" do
      client =
        Client.new({Puck.Backends.Mock, response: "I'm here to help!"},
          system_prompt: "You are a helpful assistant."
        )

      context = Context.new()

      assert {:ok, _response, _context} = Puck.call(client, "Hello!", context)
    end

    test "preserves conversation history" do
      client = Client.new({Puck.Backends.Mock, response: "Reply"})
      context = Context.new()

      {:ok, _response1, context} = Puck.call(client, "First message", context)
      {:ok, _response2, context} = Puck.call(client, "Second message", context)

      assert Context.message_count(context) == 4
    end

    test "returns error from backend" do
      client = Client.new({Puck.Backends.Mock, error: :rate_limited})
      context = Context.new()

      assert {:error, {:backend, Puck.Backends.Mock, :rate_limited}} =
               Puck.call(client, "Hello!", context)
    end

    test "accepts multi-modal content" do
      client = Client.new({Puck.Backends.Mock, response: "I see an image of a cat."})
      context = Context.new()

      multi_modal_content = [
        Content.text("What's in this image?"),
        Content.image_url("https://example.com/cat.png")
      ]

      assert {:ok, response, updated_context} =
               Puck.call(client, multi_modal_content, context)

      assert response.content == "I see an image of a cat."

      messages = Context.messages(updated_context)
      assert Enum.at(messages, 0).content == multi_modal_content
    end
  end

  describe "stream/4 with mock backend" do
    test "returns a stream of chunks" do
      client = Client.new({Puck.Backends.Mock, stream_chunks: ["Hello", " ", "world", "!"]})
      context = Context.new()

      assert {:ok, stream, updated_context} = Puck.stream(client, "Hi!", context)

      chunks = Enum.to_list(stream)
      assert length(chunks) == 4
      assert Enum.map(chunks, & &1.content) == ["Hello", " ", "world", "!"]

      assert Context.message_count(updated_context) == 1
    end

    test "returns error from backend" do
      client = Client.new({Puck.Backends.Mock, error: :connection_failed})
      context = Context.new()

      assert {:error, {:backend, Puck.Backends.Mock, :connection_failed}} =
               Puck.stream(client, "Hello!", context)
    end
  end

  describe "call/2 with client (no context)" do
    test "creates fresh context implicitly" do
      client = Client.new({Puck.Backends.Mock, response: "Hello!"})

      assert {:ok, response, context} = Puck.call(client, "Hi!")

      assert response.content == "Hello!"
      assert Context.message_count(context) == 2
    end
  end

  describe "Client.new/1 API styles" do
    test "tuple as first argument" do
      client = Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

      assert client.backend == {Puck.Backends.ReqLLM, %{model: "anthropic:claude-sonnet-4-5"}}
      assert client.system_prompt == nil
    end

    test "mock backend with keyword config" do
      client = Client.new({Puck.Backends.Mock, response: "Hello!", delay: 100})

      assert client.backend == {Puck.Backends.Mock, %{response: "Hello!", delay: 100}}
    end
  end
end
