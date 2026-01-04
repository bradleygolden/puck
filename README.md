# Puck

An Elixir framework for building LLM-powered applications with support for multiple backends, sandboxed execution, and structured outputs.

## Installation

Add `puck` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:puck, github: "bradleygolden/puck"}
  ]
end
```

Most features require optional dependencies. Add only what you need:

```elixir
def deps do
  [
    {:puck, github: "bradleygolden/puck"},

    # LLM backends (pick one or more)
    {:req_llm, "~> 1.0"},       # Multi-provider LLM support
    {:baml_elixir, "~> 1.0"},   # Structured outputs with BAML

    # Optional features
    {:solid, "~> 0.15"},        # Liquid template syntax
    {:telemetry, "~> 1.2"},     # Observability
    {:zoi, "~> 0.7"}            # Schema validation for structured outputs
  ]
end
```

## Features

- **Multiple LLM Providers**: Anthropic, OpenAI, Google, OpenRouter, AWS Bedrock, and more via ReqLLM
- **Multi-modal Content**: Text, images, files, audio, and video support
- **Streaming**: Real-time response streaming
- **Agentic Loop Support**: Build autonomous agents with response-driven control flow
- **Structured Outputs**: Type-safe responses via ReqLLM and BAML
- **Lifecycle Hooks**: Observe and transform at each stage (caching, guardrails, logging)
- **Sandboxed Execution**: Run code in isolated environments (work in progress)
- **Telemetry Integration**: Built-in observability with `:telemetry` events

## Quick Start

### Simple Call

```elixir
# Requires :req_llm dependency
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
{:ok, response, _ctx} = Puck.call(client, "Hello!")
IO.puts(response.content)
```

### With System Prompt

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  system_prompt: "You are a translator. Translate to Spanish."
)
{:ok, response, _ctx} = Puck.call(client, "Translate: Hello, world!")
```

### Multi-turn Conversations

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  system_prompt: "You are a helpful assistant."
)

context = Puck.Context.new()
{:ok, resp1, context} = Puck.call(client, "What is Elixir?", context)
{:ok, resp2, context} = Puck.call(client, "How is it different from Ruby?", context)
```

### Streaming

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
{:ok, stream, _ctx} = Puck.stream(client, "Tell me a story")

Enum.each(stream, fn chunk ->
  IO.write(chunk.content)
end)
```

### Multi-modal Content

```elixir
alias Puck.Content

client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

{:ok, response, _ctx} = Puck.call(client, [
  Content.text("What's in this image?"),
  Content.image_url("https://example.com/photo.png")
])

# Or with binary data
image_bytes = File.read!("photo.png")
{:ok, response, _ctx} = Puck.call(client, [
  Content.text("Describe this image"),
  Content.image(image_bytes, "image/png")
])
```

### Few-shot Prompting

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

{:ok, response, _ctx} = Puck.call(client, [
  %{role: :user, content: "Translate: Hello"},
  %{role: :assistant, content: "Hola"},
  %{role: :user, content: "Translate: Goodbye"}
])
```

## Backends

### ReqLLM

Multi-provider LLM support. Model format is `"provider:model"`:

```elixir
# Create a client
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

# With options
client = Puck.Client.new({Puck.Backends.ReqLLM, model: "anthropic:claude-sonnet-4-5", temperature: 0.7})
```

See ReqLLM documentation for supported providers and configuration options.

### BAML

For structured outputs and agentic patterns. See [BAML documentation](https://docs.boundaryml.com/) for details on building agentic loops.

```elixir
client = Puck.Client.new({Puck.Backends.Baml, function: "ExtractPerson"})
{:ok, result, _ctx} = Puck.call(client, "John is 30 years old")
```

### Mock (Testing)

For deterministic tests:

```elixir
client = Puck.Client.new({Puck.Backends.Mock, response: "Test response"})
{:ok, response, _ctx} = Puck.call(client, "Hello!")
```

## Lifecycle Hooks

Hooks enable middleware patterns for caching, logging, guardrails, and transformation:

```elixir
defmodule MyApp.LoggingHooks do
  @behaviour Puck.Hooks
  require Logger

  @impl true
  def on_call_start(_client, content, _context) do
    Logger.info("LLM call: #{inspect(content, limit: 50)}")
    {:cont, content}
  end

  @impl true
  def on_call_end(_client, response, _context) do
    Logger.info("Response: #{response.usage.output_tokens} tokens")
    {:cont, response}
  end
end

client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  hooks: [Puck.Telemetry.Hooks, MyApp.LoggingHooks]
)
```

Available hooks:
- `on_call_start/3` - Before LLM call (can transform content or halt)
- `on_call_end/3` - After successful call (can transform response)
- `on_call_error/3` - On call failure
- `on_stream_start/3`, `on_stream_chunk/3`, `on_stream_end/2` - Stream lifecycle
- `on_backend_request/2`, `on_backend_response/2` - Backend request/response

## Sandboxes

Execute code in isolated environments:

```elixir
alias Puck.Sandbox
alias Puck.Sandbox.Adapters.Test

{:ok, sandbox} = Sandbox.create({Test, %{image: "elixir:1.16"}})
{:ok, result} = Sandbox.exec(sandbox, "elixir --version")
IO.puts(result.stdout)
:ok = Sandbox.terminate(sandbox)
```

## Telemetry

Enable telemetry hooks for observability:

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  hooks: Puck.Telemetry.Hooks
)

# Or attach a default logger
Puck.Telemetry.attach_default_logger(level: :info)
```

### Events

| Event | Measurements | Description |
|-------|--------------|-------------|
| `[:puck, :call, :start]` | `system_time` | Before LLM call |
| `[:puck, :call, :stop]` | `duration` | After successful call |
| `[:puck, :call, :exception]` | `duration` | On call failure (includes `kind`, `reason`, `stacktrace` in metadata) |
| `[:puck, :stream, :start]` | `system_time` | Before streaming begins |
| `[:puck, :stream, :chunk]` | — | For each streamed chunk |
| `[:puck, :stream, :stop]` | `duration` | After streaming completes |
| `[:puck, :backend, :request]` | `system_time` | Before backend request |
| `[:puck, :backend, :response]` | `system_time` | After backend response |

All events include relevant metadata (client, context, response, etc.). Durations are in native time units.
See `Puck.Telemetry` module docs for full details.

## License

Apache License 2.0
