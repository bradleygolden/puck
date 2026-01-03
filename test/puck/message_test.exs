defmodule Puck.MessageTest do
  use ExUnit.Case, async: true

  alias Puck.{Content, Message}
  alias Puck.Content.Part

  describe "new/3" do
    test "creates a message with string content (wrapped to Content.Part)" do
      message = Message.new(:user, "Hello!")

      assert message.role == :user
      assert message.content == [%Part{type: :text, text: "Hello!"}]
      assert message.metadata == %{}
    end

    test "creates a message with metadata" do
      message = Message.new(:assistant, "Hi!", %{tokens: 5})

      assert message.role == :assistant
      assert message.content == [%Part{type: :text, text: "Hi!"}]
      assert message.metadata == %{tokens: 5}
    end

    test "accepts all valid roles" do
      assert %Message{role: :system} = Message.new(:system, "System prompt")
      assert %Message{role: :user} = Message.new(:user, "User message")
      assert %Message{role: :assistant} = Message.new(:assistant, "Assistant reply")
    end

    test "accepts single Content.Part" do
      part = Content.text("Hello!")
      message = Message.new(:user, part)

      assert message.content == [part]
    end

    test "accepts multi-modal content as list of Content.Part" do
      content = [
        Content.text("What's in this image?"),
        Content.image_url("https://example.com/image.png")
      ]

      message = Message.new(:user, content)

      assert message.role == :user
      assert message.content == content
    end

    test "accepts binary image content" do
      content = [
        Content.text("Describe this image"),
        Content.image(<<1, 2, 3>>, "image/png")
      ]

      message = Message.new(:user, content)

      assert [%Part{type: :text}, %Part{type: :image, data: <<1, 2, 3>>}] = message.content
    end
  end
end
