# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- BAML backend now strips `__baml_class__` and `__baml_enum__` metadata from NIF results before Zoi parsing, fixing struct parsing failures when `output_schema` is used
- BAML `dynamic_classes` TypeBuilder now emits a dedicated enum for type discriminators with descriptions, fixing union variants being collapsed to `{ type: string }` in rendered prompts

## [0.2.15] - 2026-02-14

### Added

- BAML TypeBuilder generates meaningful variant names from tagged unions (e.g., `PluginActionGetSkill` instead of `PluginActionVariant0`)
- BAML TypeBuilder accepts a `descriptions` option to attach human-readable descriptions to union variants

### Fixed

- BAML TypeBuilder now correctly recognizes literal discriminator fields in JSON schema

## [0.2.14] - 2026-02-14

### Added

- BAML backend now auto-builds `TypeBuilder` from `output_schema`, giving BAML's Rust runtime full knowledge of dynamic types for Schema-Aligned Parsing and `ctx.output_format` prompt formatting
- BAML backend accepts `dynamic_classes` option to register `@@dynamic` class fields in TypeBuilder, enabling callers to declare runtime-only fields for BAML parsing

### Fixed

- BAML backend now registers root union types in `TypeBuilder`, fixing top-level union schemas (e.g., plugin actions) where fields beyond `type` were silently dropped
- Replaced deprecated `strict: true` with `unrecognized_keys: :error` for Zoi 0.17 compatibility
- Lua sandbox callbacks now receive maps when Lua passes table arguments (previously returned opaque internal references)

### Changed

- Bumped `zoi` dependency from `~> 0.7` to `~> 0.17`
- Bumped `baml_elixir` dependency to `~> 1.0.0-pre.24.next.2` (`baml_elixir_next`) for TypeBuilder nullable union support

## [0.2.13] - 2026-02-08

### Fixed

- Claude Agent SDK backend no longer returns nil content when the result message lacks `structured_output` and `result` fields

### Changed

- Bumped `claude_agent_sdk` dependency from `~> 0.8` to `~> 0.11`

## [0.2.12] - 2026-02-07

### Added

- `Puck.LiveView` — stream LLM responses into Phoenix LiveView with PubSub, cancellation, and timeout
- `start_stream/2` function variant for multi-turn loops and structured output orchestration
- `Puck.LiveView.Handler` behaviour for pluggable persistence in the stream process
- LiveView telemetry events for stream lifecycle monitoring

### Fixed

- `Puck.Test` no longer causes flaky failures in async tests (NimbleOwnership process is now unlinked from the starting test process)

## [0.2.11] - 2026-02-06

### Fixed

- Claude Agent SDK backend now forwards the `:tools` config option, enabling tool-free chatbots via `tools: []`

## [0.2.10] - 2026-02-05

### Fixed

- Claude Agent SDK backend now resumes sessions on multi-turn calls
- Stream event partial chunks are now emitted during streaming (handles both CLIStream and ClientStream SDK paths)

### Changed

- Updated ex_doc from 0.39 to 0.40

## [0.2.9] - 2026-01-18

### Added

- `Puck.Test` - Deterministic agent testing with queued mock responses

## [0.2.8] - 2026-01-17

### Added

- `Puck.Backends.ClaudeAgentSDK` - Use Claude Code CLI with your existing Pro/Max subscription
- Native JSON schema structured outputs via SDK
- Automatic wrapping for union schemas (anyOf/oneOf/allOf) to work around Anthropic API limitation
- Sandbox mode support for safe execution

## [0.2.7] - 2026-01-10

### Fixed

- Lua eval results are now converted to JSON-encodable format (tables become maps, arrays become lists)

## [0.2.6] - 2026-01-10

### Fixed

- Lua callbacks now accept maps with atom keys (idiomatic Elixir) by automatically converting them to string keys at the sandbox boundary

## [0.2.5] - 2026-01-10

### Fixed

- `Puck.Eval.Collector` now captures telemetry events from child processes (Task.async, spawned GenServers, etc.)

## [0.2.4] - 2026-01-09

### Added

- `Puck.Eval` - Test and measure LLM agent performance
- `Puck.Eval.Trajectory` - Records execution history (steps, tokens, duration)
- `Puck.Eval.Step` - Details of a single LLM call (input, output, tokens, timing)
- `Puck.Eval.Collector` - Captures trajectories from both `call` and `stream` operations via telemetry
- `Puck.Eval.Grader` - Define custom scoring rules for agent outputs
- `Puck.Eval.Graders` - Built-in graders (contains, max_steps, max_tokens, output_produced, and more)
- `Puck.Eval.Result` - Combines grader results into a single pass/fail outcome

## [0.2.3] - 2026-01-09

### Added

- `[:puck, :stream, :exception]` telemetry event for stream initialization failures

### Changed

- Telemetry events are now emitted automatically when the `:telemetry` dependency is installed (no configuration required)

### Removed

- `Puck.Telemetry.Hooks` module (telemetry is now automatic, no hooks configuration needed)

## [0.2.2] - 2026-01-08

### Added

- Built-in BAML conversation summarizer (`PuckSummarize`) - no custom BAML files needed
- Summarize compaction now works automatically with BAML backend
- `Puck.Baml` module for built-in BAML functions
- Client registry documentation in README

### Changed

- Renamed `:instructions` option to `:prompt` in `Puck.Compaction.Summarize` for consistency
- Updated `baml_elixir` dependency to 1.0.0-pre.24
- Added `--warnings-as-errors` to docs in precommit and CI

### Fixed

- Fixed token usage tracking for BAML backend

### Removed

- `baml_elixir_next` override documentation (no longer needed with baml_elixir 1.0.0-pre.24)

## [0.2.1] - 2026-01-08

### Added

- Documentation for `baml_elixir_next` as an optional override for enhanced BAML features (client registry support)
- Acknowledgments section in README recognizing key dependencies

### Fixed

- Compile warnings when optional dependencies (`lua`, `req`) are not installed
- ExDoc module groups now reflect the reorganized sandbox module structure
- CHANGELOG version links for v0.2.0

## [0.2.0] - 2026-01-07

### Added

- `Puck.Compaction` - Behaviour for context compaction strategies
- `Puck.Compaction.Summarize` - LLM-based summarization strategy
- `Puck.Compaction.SlidingWindow` - Sliding window strategy (keeps last N messages)
- `Puck.Context.compact/2` - Manual context compaction
- `Puck.Context.total_tokens/1` - Token count tracking
- Auto-compaction via `Puck.Client.new/2` `:auto_compaction` option
- Compaction lifecycle hooks: `on_compaction_start/3`, `on_compaction_end/2`
- Compaction telemetry events: `[:puck, :compaction, :start]`, `[:puck, :compaction, :stop]`, `[:puck, :compaction, :error]`
- `Puck.Sandbox.Eval` - In-process code evaluation with Lua support
- `Puck.Sandbox.Eval.Lua` - Lua sandbox with timeout, memory limits, and callbacks
- `Puck.Sandbox.Eval.Lua.schema/1` - Schema helper for LLM-generated Lua code execution

### Changed

- Reorganized sandbox modules: `Puck.Sandbox.Runtime` for containers, `Puck.Sandbox.Eval` for interpreters

### Removed

- Native tool calling support (use structured outputs with discriminated unions instead)

## [0.1.0] - 2025-01-04

The first release!

[Unreleased]: https://github.com/bradleygolden/puck/compare/v0.2.15...HEAD
[0.2.15]: https://github.com/bradleygolden/puck/compare/v0.2.14...v0.2.15
[0.2.14]: https://github.com/bradleygolden/puck/compare/v0.2.13...v0.2.14
[0.2.13]: https://github.com/bradleygolden/puck/compare/v0.2.12...v0.2.13
[0.2.12]: https://github.com/bradleygolden/puck/compare/v0.2.11...v0.2.12
[0.2.11]: https://github.com/bradleygolden/puck/compare/v0.2.10...v0.2.11
[0.2.10]: https://github.com/bradleygolden/puck/compare/v0.2.9...v0.2.10
[0.2.9]: https://github.com/bradleygolden/puck/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/bradleygolden/puck/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/bradleygolden/puck/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/bradleygolden/puck/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/bradleygolden/puck/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/bradleygolden/puck/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/bradleygolden/puck/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/bradleygolden/puck/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/bradleygolden/puck/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/bradleygolden/puck/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bradleygolden/puck/releases/tag/v0.1.0
