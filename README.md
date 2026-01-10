# Puck

Agent primitives for Elixir.

The best AI agents shipped to production share a secret: they're just LLMs calling tools in a loop. Puck gives you the primitives to build exactly that.

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
{:ok, response, _ctx} = Puck.call(client, "Hello!")
```

One function. Any provider. Build whatever you want on top.

## The Primitives

Seven building blocks. Compose them however you need:

| Primitive | Purpose |
|-----------|---------|
| `Puck.Client` | Configure backend, model, system prompt |
| `Puck.Context` | Multi-turn conversation state |
| `Puck.call/4` | One function to call any LLM |
| `Puck.Hooks` | Observe and transform at every stage |
| `Puck.Compaction` | Handle long conversations |
| `Puck.Eval` | Capture trajectories, grade outputs |
| `Puck.Sandbox` | Execute LLM-generated code safely |

No orchestration. No hidden control flow. You write the loop.

## Why Primitives?

Most LLM libraries are frameworks. They give you abstractions that work until they don't—then you fight the framework.

Puck takes the opposite approach:

- **You control the loop** — Pattern match on struct types. Decide what happens next.
- **Swap anything** — Backends, providers, models. Same interface.
- **See everything** — Hooks and telemetry at every stage.
- **Test everything** — Capture trajectories. Apply graders.

## Quick Start

### Structured Outputs

Define action structs. Create a union schema. Pattern match:

```elixir
defmodule LookupContact do
  defstruct type: "lookup_contact", name: nil
end

defmodule CreateTask do
  defstruct type: "create_task", title: nil, due_date: nil
end

defmodule Done do
  defstruct type: "done", message: nil
end

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

> **Note:** `coerce: true` is required because LLM backends return raw maps. This tells Zoi to convert the map into your struct.

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

## Installation

```elixir
def deps do
  [
    {:puck, "~> 0.2.0"}
  ]
end
```

Most features require optional dependencies. Add only what you need:

```elixir
def deps do
  [
    {:puck, "~> 0.2.0"},

    # LLM backends (pick one or more)
    {:req_llm, "~> 1.0"},       # Multi-provider LLM support
    {:baml_elixir, "~> 1.0"},   # Structured outputs with BAML

    # Optional features
    {:solid, "~> 0.15"},        # Liquid template syntax
    {:telemetry, "~> 1.2"},     # Observability
    {:zoi, "~> 0.7"},           # Schema validation for structured outputs
    {:lua, "~> 0.4.0"}          # Lua sandbox for code execution
  ]
end
```

## Backends

### ReqLLM

Multi-provider LLM support. Model format is `"provider:model"`:

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

# With options
client = Puck.Client.new({Puck.Backends.ReqLLM, model: "anthropic:claude-sonnet-4-5", temperature: 0.7})
```

Supports Anthropic, OpenAI, Google, OpenRouter, AWS Bedrock. See ReqLLM documentation for details.

### BAML

For structured outputs and agentic patterns:

```elixir
client = Puck.Client.new({Puck.Backends.Baml, function: "ExtractPerson"})
{:ok, result, _ctx} = Puck.call(client, "John is 30 years old")
```

#### Runtime Client Registry

Configure LLM providers at runtime without hardcoding credentials:

```elixir
registry = %{
  "clients" => [
    %{
      "name" => "MyClient",
      "provider" => "anthropic",
      "options" => %{"model" => "claude-sonnet-4-5"}
    }
  ],
  "primary" => "MyClient"
}

client = Puck.Client.new(
  {Puck.Backends.Baml, function: "ExtractPerson", client_registry: registry}
)
```

See [BAML Client Registry docs](https://docs.boundaryml.com/guide/baml-advanced/llm-client-registry) for supported providers.

### Mock

For deterministic tests:

```elixir
client = Puck.Client.new({Puck.Backends.Mock, response: "Test response"})
{:ok, response, _ctx} = Puck.call(client, "Hello!")
```

## Context

Multi-turn conversations with automatic state management:

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  system_prompt: "You are a helpful assistant."
)

context = Puck.Context.new()
{:ok, resp1, context} = Puck.call(client, "What is Elixir?", context)
{:ok, resp2, context} = Puck.call(client, "How is it different from Ruby?", context)
```

### Compaction

Long conversations can exceed context limits. Handle this automatically:

```elixir
# Summarize when token threshold exceeded
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  auto_compaction: {:summarize, max_tokens: 100_000, keep_last: 5}
)

# Sliding window (keeps last N messages)
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  auto_compaction: {:sliding_window, window_size: 30}
)
```

Or compact manually:

```elixir
{:ok, compacted} = Puck.Context.compact(context, {Puck.Compaction.SlidingWindow, %{
  window_size: 20
}})
```

## Hooks

Observe and transform at every stage—without touching business logic:

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
  hooks: MyApp.LoggingHooks
)
```

Available hooks:
- `on_call_start/3` — Before LLM call (can transform content or halt)
- `on_call_end/3` — After successful call (can transform response)
- `on_call_error/3` — On call failure
- `on_stream_start/3`, `on_stream_chunk/3`, `on_stream_end/2` — Stream lifecycle
- `on_backend_request/2`, `on_backend_response/2` — Backend request/response
- `on_compaction_start/3`, `on_compaction_end/2` — Compaction lifecycle

## Eval

Primitives for evaluating agents. Capture what happened. Grade the results.

### Capture Trajectory

Every `Puck.call` becomes a step:

```elixir
alias Puck.Eval.{Collector, Graders}

{output, trajectory} = Collector.collect(fn ->
  MyAgent.run("Find John's email")
end)

trajectory.total_steps       # => 2
trajectory.total_tokens      # => 385
trajectory.total_duration_ms # => 1250
```

### Apply Graders

```elixir
result = Puck.Eval.grade(output, trajectory, [
  Graders.contains("john@example.com"),
  Graders.max_steps(5),
  Graders.max_tokens(10_000)
])

result.passed?  # => true
```

### Built-in Graders

```elixir
# Output graders
Graders.contains("substring")
Graders.matches(~r/pattern/)
Graders.equals(expected)
Graders.satisfies(fn x -> ... end)

# Trajectory graders
Graders.max_steps(n)
Graders.max_tokens(n)
Graders.max_duration_ms(n)

# Step output graders
Graders.output_produced(LookupContact)
Graders.output_produced(LookupContact, times: 2)
Graders.output_matches(fn %LookupContact{name: "John"} -> true; _ -> false end)
Graders.output_not_produced(DeleteContact)
Graders.output_sequence([Search, Confirm, Done])
```

### Custom Graders

Graders are just functions:

```elixir
my_grader = fn output, trajectory ->
  if trajectory.total_tokens < 1000 do
    :pass
  else
    {:fail, "Used #{trajectory.total_tokens} tokens, expected < 1000"}
  end
end
```

## Sandbox

Execute LLM-generated code safely with callbacks to your application:

```elixir
alias Puck.Sandbox.Eval

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

Use `Puck.Sandbox.Eval.Lua.schema/1` to let LLMs generate Lua code as a structured output. Requires `{:lua, "~> 0.4.0"}`.

## Telemetry

Events are emitted automatically when `:telemetry` is installed:

```elixir
Puck.Telemetry.attach_default_logger(level: :info)

# Or attach your own handler
:telemetry.attach_many("my-handler", Puck.Telemetry.event_names(), &handler/4, nil)
```

| Event | Description |
|-------|-------------|
| `[:puck, :call, :start]` | Before LLM call |
| `[:puck, :call, :stop]` | After successful call |
| `[:puck, :call, :exception]` | On call failure |
| `[:puck, :stream, :start]` | Before streaming |
| `[:puck, :stream, :chunk]` | Each streamed chunk |
| `[:puck, :stream, :stop]` | After streaming completes |
| `[:puck, :compaction, :start]` | Before compaction |
| `[:puck, :compaction, :stop]` | After compaction |

## More Examples

### Streaming

```elixir
client = Puck.Client.new({Puck.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
{:ok, stream, _ctx} = Puck.stream(client, "Tell me a story")

Enum.each(stream, fn chunk ->
  IO.write(chunk.content)
end)
```

### Multi-modal

```elixir
alias Puck.Content

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
{:ok, response, _ctx} = Puck.call(client, [
  %{role: :user, content: "Translate: Hello"},
  %{role: :assistant, content: "Hola"},
  %{role: :user, content: "Translate: Goodbye"}
])
```

## Acknowledgments

Puck builds on excellent open source projects:

- [Lua](https://github.com/tv-labs/lua) by TV Labs - Ergonomic Elixir interface to Luerl
- [Luerl](https://github.com/rvirding/luerl) by Robert Virding - Lua VM implemented in Erlang
- [ReqLLM](https://github.com/nallwhy/req_llm) - Multi-provider LLM client for Elixir
- [BAML](https://github.com/boundaryml/baml) - Type-safe structured outputs for LLMs

## License

Apache License 2.0
