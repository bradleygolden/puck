# Puck

An Elixir framework for building AI agents with support for multiple LLM backends, sandboxed execution, and structured outputs.

## Installation

Add `puck` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:puck, github: "bradleygolden/puck", ref: "main"}
  ]
end
```

## Features

- **Multiple Backends**: Support for Anthropic Claude (via `req_llm`), BAML, and mock backends
- **Agent Abstractions**: Define agents with system prompts, models, and tools
- **Structured Outputs**: BAML integration for type-safe LLM outputs
- **Sandboxed Execution**: Run code in isolated environments with pluggable adapters
- **Lifecycle Hooks**: Customize agent behavior with before/after call hooks
- **Prompt Templating**: Liquid templates via Solid and the `~P` sigil
- **Telemetry Integration**: Built-in observability with `:telemetry` events

## Quick Start

### Basic Agent

```elixir
alias Puck.Agent

agent = Agent.new(
  system: "You are a helpful assistant.",
  model: "claude-sonnet-4-20250514"
)

{:ok, response} = Puck.call(agent, "Hello!")
IO.puts(response.content)
```

### With Tools

```elixir
defmodule MyTools do
  def get_weather(location) do
    # Fetch weather data
    %{temperature: 72, conditions: "sunny"}
  end
end

agent = Agent.new(
  system: "You are a weather assistant.",
  model: "claude-sonnet-4-20250514",
  tools: [
    %{
      name: "get_weather",
      description: "Get current weather for a location",
      input_schema: %{
        type: "object",
        properties: %{location: %{type: "string"}},
        required: ["location"]
      },
      function: &MyTools.get_weather/1
    }
  ]
)
```

### Streaming

```elixir
{:ok, stream} = Puck.stream(agent, "Tell me a story")

stream
|> Stream.each(fn chunk ->
  case chunk do
    {:text, text} -> IO.write(text)
    {:tool_use, tool} -> IO.inspect(tool)
    _ -> :ok
  end
end)
|> Stream.run()
```

### BAML Backend (Structured Outputs)

```elixir
# With BAML for structured outputs
agent = Agent.new(
  backend: {Puck.Backends.BAML, baml_src: "path/to/baml_src"}
)

{:ok, result} = Puck.call(agent, "ExtractPerson", %{
  text: "John is 30 years old"
})
# => %{"name" => "John", "age" => 30}
```

## Backends

### ReqLLM (Default)

Uses the `req_llm` library for Anthropic Claude API access:

```elixir
Agent.new(
  backend: {Puck.Backends.ReqLLM, []},
  model: "claude-sonnet-4-20250514"
)
```

### BAML

For structured outputs with type safety:

```elixir
Agent.new(
  backend: {Puck.Backends.BAML, baml_src: "baml_src/"}
)
```

### Mock

For testing:

```elixir
Agent.new(
  backend: {Puck.Backends.Mock, response: "Test response"}
)
```

## Sandboxes

Execute code in isolated environments:

```elixir
alias Puck.Sandbox
alias Puck.Sandbox.Adapters.Test, as: TestAdapter

{:ok, sandbox} = Sandbox.create({TestAdapter, %{image: "elixir:1.16"}})

{:ok, result} = Sandbox.exec(sandbox, "elixir --version")
IO.puts(result.stdout)

:ok = Sandbox.terminate(sandbox)
```

## Telemetry Events

Puck emits the following telemetry events:

- `[:puck, :call, :start]` - When an agent call begins
- `[:puck, :call, :stop]` - When an agent call completes
- `[:puck, :call, :exception]` - When an agent call raises an exception

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.
