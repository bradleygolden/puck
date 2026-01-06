defmodule Puck.Sandbox do
  @moduledoc """
  Sandbox execution environments for isolated code execution.

  Puck provides two types of sandboxes for different use cases:

  ## Runtime Sandboxes

  `Puck.Sandbox.Runtime` manages container-based isolated environments (Docker, Fly.io).
  Use when you need:
  - Full OS environment with filesystem and networking
  - Long-lived containers with shell command execution
  - Heavy isolation via containers

  ```elixir
  alias Puck.Sandbox.Runtime

  {:ok, sandbox} = Runtime.create({Runtime.Adapters.Test, image: "node:22-slim"})
  {:ok, result} = Runtime.exec(sandbox, "node --version")
  :ok = Runtime.terminate(sandbox)
  ```

  ## Eval Sandboxes

  `Puck.Sandbox.Eval` runs code in in-process interpreters (Lua, JavaScript).
  Use when you need:
  - Fast, lightweight code evaluation
  - Host callbacks for LLM tool use
  - No container overhead

  ```elixir
  alias Puck.Sandbox.Eval

  {:ok, result} = Eval.eval(:lua, "return 1 + 2")
  {:ok, result} = Eval.eval(:lua, \"\"\"
    return search("laptop")
  \"\"\", callbacks: %{"search" => &MyApp.search/1})
  ```

  ## Comparison

  | | Runtime | Eval |
  |---|---|---|
  | Isolation | Container/process | BEAM process |
  | Filesystem | Yes | No |
  | Network | Configurable | No |
  | Languages | Any (shell) | Lua (more coming) |
  | Use case | Run programs | LLM tool calls |
  """
end
