# Puck

Build LLM agents in Elixir. No magic. Just loops.

The best AI agents shipped to production share a secret: they're just LLMs calling tools in a loop. Puck gives you the primitives to build exactly that — with any provider, any model, full observability.

## Philosophy

Most LLM frameworks add complexity you don't need. Puck takes a different approach:

- **Agents are loops** — An LLM, tools, and a feedback loop. That's it.
- **No hard-coded orchestration** — You control the flow, not the framework.
- **Swap backends** - ReqLLM, BamlElixir, or implement your own
- **Swap providers** — Anthropic to OpenAI to Bedrock
- **Observe everything** — Lifecycle hooks for caching, guardrails, logging.

## Quick Start

Three lines to your first LLM call:

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
{:ok, response, _ctx} = Puck.call(client, "Hello!")
IO.puts(response.content)
```

### Structured Outputs

Define action structs. Create a union schema. Pattern match on the struct type:

```elixir
# Each action is its own struct with a `type` discriminator
defmodule LookupContact do
  defstruct type: "lookup_contact", name: nil
end

defmodule CreateTask do
  defstruct type: "create_task", title: nil, due_date: nil
end

defmodule Done do
  defstruct type: "done", message: nil
end

# Build a union schema with literal type discriminators
def schema do
  Zoi.union([
    Zoi.struct(LookupContact, %{
      type: Zoi.literal("lookup_contact"),
      name: Zoi.string(description: "Contact name to find")
    }, coerce: true),
    Zoi.struct(CreateTask, %{
      type: Zoi.literal("create_task"),
      title: Zoi.string(description: "Task title"),
      due_date: Zoi.string(description: "Due date")
    }, coerce: true),
    Zoi.struct(Done, %{
      type: Zoi.literal("done"),
      message: Zoi.string(description: "Final response to user")
    }, coerce: true)
  ])
end
```

> **Note:** `coerce: true` is required because LLM backends return raw maps. This option tells Zoi to convert the map into your struct.

### Build an Agent Loop

```elixir
defp loop(client, input, ctx) do
  {:ok, %{content: action}, ctx} = Puck.call(client, input, ctx, output_schema: schema())

  case action do
    %Done{message: msg}        -> {:ok, msg}
    %LookupContact{name: name} -> loop(client, CRM.find(name), ctx)
    %CreateTask{} = task       -> loop(client, CRM.create(task), ctx)
  end
end
```

That's it. Pattern match on struct types. Works with any backend.

## Features

- **Any provider, one interface** — Anthropic, OpenAI, Google, OpenRouter, AWS Bedrock via ReqLLM
- **Real-time streaming** — Stream tokens as they arrive
- **Multi-modal** — Text, images, files, audio, video
- **You build the loop** — Response-driven control flow, not framework magic
- **Types, not strings** — Structured outputs via ReqLLM and BAML
- **Observe everything** — Lifecycle hooks for caching, guardrails, logging
- **Sandboxed execution** — Run LLM-generated Lua code safely with callbacks
- **Telemetry built-in** — Full observability with `:telemetry` events

## Installation

Add `puck` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:puck, "~> 0.1.0"}
  ]
end
```

Most features require optional dependencies. Add only what you need:

```elixir
def deps do
  [
    {:puck, "~> 0.1.0"},

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

## More Examples

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

Hooks let you observe and transform at every stage — without touching business logic:

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
- `on_call_start/3` — Before LLM call (can transform content or halt)
- `on_call_end/3` — After successful call (can transform response)
- `on_call_error/3` — On call failure
- `on_stream_start/3`, `on_stream_chunk/3`, `on_stream_end/2` — Stream lifecycle
- `on_backend_request/2`, `on_backend_response/2` — Backend request/response

## Sandboxes

Execute LLM-generated code safely with callbacks to your application:

```elixir
alias Puck.Sandbox.Eval

# Simple eval
{:ok, result} = Eval.eval(:lua, "return 1 + 2")

# With callbacks to your application
{:ok, result} = Eval.eval(:lua, """
  local products = search("laptop")
  local cheap = {}
  for _, p in ipairs(products) do
    if p.price < 1000 then table.insert(cheap, p) end
  end
  return cheap
""", callbacks: %{
  "search" => &MyApp.Products.search/1
})
```

### LLM-Generated Code

Use `Lua.schema/1` to let LLMs generate and execute Lua code. The schema includes guidance so the LLM produces valid code (e.g., always use `return`).

```elixir
alias Puck.Sandbox.Eval.Lua

defmodule Done do
  defstruct type: "done", message: nil
end

# Define what functions the LLM can call
@func_spec Zoi.object(%{
  name: Zoi.enum(["double"]),
  description: Zoi.string()
}, strict: true, coerce: true)

defp schema do
  Zoi.union([
    Lua.schema(@func_spec),
    Zoi.struct(Done, %{
      type: Zoi.literal("done"),
      message: Zoi.string()
    }, coerce: true)
  ])
end

# Elixir callbacks the LLM can invoke via Lua
@callbacks %{"double" => fn n -> n * 2 end}

defp loop(client, input, ctx) do
  {:ok, %{content: action}, ctx} = Puck.call(client, input, ctx, output_schema: schema())

  case action do
    %Lua.ExecuteCode{code: code} ->
      {:ok, result} = Puck.Sandbox.Eval.eval(:lua, code, callbacks: @callbacks)
      loop(client, "Result: #{inspect(result)}", ctx)

    %Done{message: msg} ->
      {:ok, msg}
  end
end

# Start the agent
client = Puck.Client.new(
  {Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  system_prompt: "You are a calculator. Use execute_lua for calculations, done when finished."
)

{:ok, answer} = loop(client, "Double the number 21", Puck.Context.new())
# => {:ok, "The result is 42."}
```

Requires `{:lua, "~> 0.4.0"}` and `{:zoi, "~> 0.7"}` in your dependencies.

## Telemetry

Enable telemetry hooks for full observability:

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
