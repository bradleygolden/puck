defmodule Puck.Sandbox.Runtime.Adapters.SpritesTest do
  use ExUnit.Case, async: true

  # Only compile tests if sprites dependency is loaded
  if Code.ensure_loaded?(Sprites) do
    alias Puck.Sandbox.Runtime
    alias Puck.Sandbox.Runtime.Adapters.Sprites, as: SpritesAdapter

    describe "create/1" do
      test "returns error when token is missing" do
        original_env = System.get_env("SPRITES_TOKEN")
        System.delete_env("SPRITES_TOKEN")

        try do
          config = %{name: "test-sprite"}
          assert {:error, :missing_token} = SpritesAdapter.create(config)
        after
          if original_env, do: System.put_env("SPRITES_TOKEN", original_env)
        end
      end

      test "returns error when name is missing" do
        config = %{token: "fake-token"}
        assert {:error, :missing_name} = SpritesAdapter.create(config)
      end
    end

    describe "get_url/2" do
      test "returns sprite URL for port" do
        assert {:ok, url} = SpritesAdapter.get_url("my-sandbox", 8080)
        assert url == "https://my-sandbox.sprites.dev:8080"
      end
    end

    # Integration tests require SPRITES_TOKEN environment variable
    # Run with: SPRITES_TOKEN=xxx mix test --include integration
    describe "integration" do
      @moduletag :integration
      @moduletag timeout: 120_000

      setup do
        case System.get_env("SPRITES_TOKEN") do
          nil ->
            :ok

          token ->
            sprite_name = "puck-test-#{System.unique_integer([:positive])}"
            {:ok, token: token, sprite_name: sprite_name}
        end
      end

      test "creates, executes commands, and terminates sandbox", context do
        skip_without_token(context, fn ->
          %{token: token, sprite_name: sprite_name} = context

          {:ok, sandbox} = Runtime.create({SpritesAdapter, name: sprite_name, token: token})

          assert sandbox.id == sprite_name
          assert sandbox.adapter == SpritesAdapter

          {:ok, result} = Runtime.exec(sandbox, "echo hello")
          assert result.exit_code == 0
          assert String.trim(result.stdout) == "hello"

          :ok = Runtime.terminate(sandbox)
        end)
      end

      test "file operations work", context do
        skip_without_token(context, fn ->
          %{token: token, sprite_name: sprite_name} = context

          {:ok, sandbox} = Runtime.create({SpritesAdapter, name: sprite_name, token: token})

          try do
            :ok = Runtime.write_file(sandbox, "/tmp/test.txt", "hello from puck")
            {:ok, content} = Runtime.read_file(sandbox, "/tmp/test.txt")
            assert content == "hello from puck"
          after
            Runtime.terminate(sandbox)
          end
        end)
      end

      @tag :checkpoint
      test "checkpoint operations work", context do
        skip_without_token(context, fn ->
          %{token: token, sprite_name: sprite_name} = context

          {:ok, sandbox} = Runtime.create({SpritesAdapter, name: sprite_name, token: token})

          try do
            :ok = Runtime.write_file(sandbox, "/tmp/state.txt", "initial")

            {:ok, checkpoint_id} = Runtime.create_checkpoint(sandbox, comment: "test checkpoint")
            assert is_binary(checkpoint_id)

            :ok = Runtime.write_file(sandbox, "/tmp/state.txt", "modified")
            {:ok, content} = Runtime.read_file(sandbox, "/tmp/state.txt")
            assert content == "modified"

            :ok = Runtime.restore_checkpoint(sandbox, checkpoint_id)
            {:ok, restored_content} = Runtime.read_file(sandbox, "/tmp/state.txt")
            assert restored_content == "initial"
          after
            Runtime.terminate(sandbox)
          end
        end)
      end

      defp skip_without_token(context, fun) do
        if Map.has_key?(context, :token) do
          fun.()
        else
          IO.puts("\n    Skipped: SPRITES_TOKEN not set")
        end
      end
    end
  else
    @moduletag :skip
    test "sprites dependency not loaded" do
      :ok
    end
  end
end
