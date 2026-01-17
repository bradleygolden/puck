# Puck

AI Agent primitives for Elixir.

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
    {:req_llm, "~> 1.0"},         # Multi-provider LLM support
    {:baml_elixir, "~> 1.0"},     # Structured outputs with BAML
    {:claude_agent_sdk, "~> 0.8"}, # Claude Code with subscription auth

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

### Claude Agent SDK

Use Claude Code with your existing subscription (Pro/Max). Requires the Claude Code CLI:

```bash
# Install CLI
npm install -g @anthropic-ai/claude-code

# Login with your subscription
claude login
```

Then add the dependency and use the backend:

```elixir
# In mix.exs
{:claude_agent_sdk, "~> 0.8"}

# In your code
client = Puck.Client.new(
  {Puck.Backends.ClaudeAgentSDK, %{
    allowed_tools: ["Read", "Glob", "Grep"],
    permission_mode: :bypass_permissions
  }}
)

{:ok, response, _ctx} = Puck.call(client, "What files are in this directory?")
```

This backend is agentic—Claude Code may make multiple tool calls before returning. Configuration options:

| Option | Description |
|--------|-------------|
| `:allowed_tools` | List of tools Claude can use (e.g., `["Read", "Edit", "Bash"]`) |
| `:disallowed_tools` | Tools to disable |
| `:permission_mode` | `:default`, `:accept_edits`, `:bypass_permissions` |
| `:max_turns` | Maximum conversation turns |
| `:cwd` | Working directory for file operations |
| `:model` | Model to use (`"sonnet"`, `"opus"`) |

See [claude_agent_sdk](https://hexdocs.pm/claude_agent_sdk) for more details.

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

Every `Puck.call` and `Puck.stream` becomes a step:

```elixir
alias Puck.Eval.{Collector, Graders}

{output, trajectory} = Collector.collect(fn ->
  MyAgent.run("Find John's email")
end)

trajectory.total_steps       # => 2
trajectory.total_tokens      # => 385
trajectory.total_duration_ms # => 1250
```

Streaming responses are also captured, with `step.metadata[:streamed] == true`.

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

### Multi-Trial Evaluation

Run agent multiple times to measure reliability (pass@k) and consistency (pass^k):

```elixir
alias Puck.Eval.Trial

results = Trial.run_trials(
  fn -> MyAgent.run("Find contact") end,
  [Graders.contains("john@example.com")],
  k: 5
)

results.pass_at_k      # => true (≥1 success)
results.pass_carrot_k  # => false (not all succeeded)
results.pass_rate      # => 0.6 (60% success rate)
```

Use `pass@k` for reliability testing (does it work at all?) and `pass^k` for consistency testing (does it always work?).

### LLM-as-Judge Graders

For subjective criteria like tone, empathy, or quality:

```elixir
alias Puck.Eval.Graders.LLM

judge_client = Puck.Client.new(
  {Puck.Backends.ReqLLM, "anthropic:claude-haiku-4-5"}
)

result = Puck.Eval.grade(output, trajectory, [
  LLM.rubric(judge_client, """
  - Response is polite
  - Response is helpful
  - Response is concise
  """)
])
```

LLM judges are non-deterministic. Use multi-trial evaluation to measure reliability.

### Debugging Tools

When evals fail, inspect what happened:

```elixir
alias Puck.Eval.Inspector

# Print human-readable trajectory
Inspector.print_trajectory(trajectory)

# Format grader failures
unless result.passed? do
  IO.puts(Inspector.format_failures(result))
end
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

### Evaluation Best Practices

Based on [Anthropic's eval methodology](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents):

#### 1. Grade Outcomes, Not Paths

```elixir
# ❌ Brittle - rejects valid solutions
Graders.output_sequence([SearchDB, LookupContact, FetchEmail, Done])

# ✅ Flexible - accepts any path that works
Graders.output_produced(Done)
Graders.contains("john@example.com")
```

Agents discover valid approaches designers miss. Grade what matters, not how it's done.

#### 2. Test Both Triggers and Constraints

```elixir
# Positive trigger
test "deletes test user" do
  assert_produced(DeleteUser)
end

# Negative constraint
test "refuses admin deletion" do
  assert_not_produced(DeleteUser)
  assert_contains("cannot delete admin")
end
```

Testing only triggers leads to agents that over-apply actions. Balanced problem sets prevent one-sided optimization.

#### 3. Read Transcripts When Failing

```elixir
# 0% pass rate across trials?
Inspector.print_trajectory(trajectory)

# Usually reveals:
# - Ambiguous task specs
# - Brittle graders
# - Missing reference solutions
```

If everything fails, the eval is broken. Fix the eval before blaming the agent.

#### 4. Start Small, Graduate to Regression

```elixir
# Capability eval - challenging task
@tag :eval_capability
test "handles complex scenario" do
  # Goal: ~70-90% pass rate
end

# Regression eval - should always pass
@tag :eval_regression
test "basic functionality works" do
  # Goal: ~100% pass rate
end
```

Start with 20-50 real-world failures. Once agents reach ~100% on capability evals, graduate them to regression tests. Run capability evals less frequently, regression tests on every commit.

#### 5. Use Multi-Trial for Reliability

```elixir
test "agent reliably finds contacts" do
  results = Trial.run_trials(
    fn -> ContactAgent.find("John") end,
    [Graders.contains("@")],
    k: 10
  )

  # Require 90% reliability
  assert results.pass_rate >= 0.9
end
```

Single runs can be misleading. Multi-trial evaluation reveals true reliability.

#### 6. Isolate State Between Trials

ExUnit's `async: true` and BEAM process isolation provide clean state automatically:

```elixir
defmodule ContactAgentTest do
  use ExUnit.Case, async: true

  test "finds contact" do
    # Each test runs in isolated process
    # Clean database via Ecto sandbox
    # Clean filesystem via tmp directories
  end
end
```

No Docker containers needed - BEAM provides isolation.

### In ExUnit

```elixir
defmodule ContactAgentTest do
  use ExUnit.Case, async: true

  alias Puck.Eval.{Collector, Graders, Inspector, Trial}

  test "finds existing contact" do
    {output, trajectory} = Collector.collect(fn ->
      ContactAgent.run("Find John's email")
    end)

    result = Puck.Eval.grade(output, trajectory, [
      Graders.contains("john@example.com"),
      Graders.output_sequence([Search, Confirm, Done]),
      Graders.max_steps(5)
    ])

    assert result.passed?, Inspector.format_failures(result)
  end

  test "refuses non-existent contact" do
    {output, trajectory} = Collector.collect(fn ->
      ContactAgent.run("Find NonExistent")
    end)

    result = Puck.Eval.grade(output, trajectory, [
      Graders.output_not_produced(LookupContact),
      Graders.contains("not found")
    ])

    assert result.passed?
  end

  test "reliably finds contacts" do
    results = Trial.run_trials(
      fn -> ContactAgent.run("Find John's email") end,
      [Graders.contains("john@example.com")],
      k: 10
    )

    assert results.pass_rate >= 0.9, "Agent not reliable enough"
  end
end
```

### Production Monitoring

```elixir
def monitor_agent_call(input) do
  {output, trajectory} = Puck.Eval.collect(fn ->
    MyAgent.run(input)
  end)

  :telemetry.execute(
    [:my_app, :agent, :call],
    %{
      steps: trajectory.total_steps,
      tokens: trajectory.total_tokens,
      duration_ms: trajectory.total_duration_ms
    },
    %{input: input}
  )

  output
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
