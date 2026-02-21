# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.23] - 2026-02-21

### Fixed

- BAML streaming `sanitize_partial_strings/1` no longer crashes with `Protocol.UndefinedError` when the output schema parses into a struct (e.g., `PuckCoder.Actions.Shell`). Structs match the `is_map` guard but don't implement `Enumerable`, so `Map.new/2` would raise. Added a struct-specific clause that passes through unchanged.

## [0.2.22] - 2026-02-21

### Added

- Added `on_stream_done/3` hook callback, invoked once after stream completion with the assembled `Puck.Response` and final assistant-appended context

### Fixed

- BAML streaming now populates usage (token counts) in the final chunk, making `on_stream_done` and `Puck.Response` usage symmetric with non-streaming calls
- BAML streaming no longer emits partial chunks containing broken escape sequences or duplicate content

## [0.2.21] - 2026-02-21

### Fixed

- BAML backend streaming no longer aborts immediately when stream callbacks are delivered asynchronously from the BAML client

## [0.2.20] - 2026-02-20

### Fixed

- BAML backend now enriches collector usage with provider response usage/body/header fields, including cache metrics such as `cache_read_input_tokens` when available
- Fixed `map_get/2` dropping legitimate falsy values like `0` from usage maps

## [0.2.19] - 2026-02-20

### Fixed

- BAML backend now preserves provider-specific usage fields (e.g., `cache_creation_input_tokens`, `cache_read_input_tokens`) returned by the LLM provider alongside the default `input_tokens` and `output_tokens`

## [0.2.18] - 2026-02-17

### Added

- `[:puck, :backend, :baml, :error]` telemetry event emitted when the BAML backend returns an error, with the raw LLM response included in metadata for debugging

## [0.2.17] - 2026-02-14

### Fixed

- BAML `dynamic_classes` TypeBuilder no longer renders `// nil` comments on dynamic fields in prompts

## [0.2.16] - 2026-02-14

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

[Unreleased]: https://github.com/bradleygolden/puck/compare/v0.2.23...HEAD
[0.2.23]: https://github.com/bradleygolden/puck/compare/v0.2.22...v0.2.23
[0.2.22]: https://github.com/bradleygolden/puck/compare/v0.2.21...v0.2.22
[0.2.21]: https://github.com/bradleygolden/puck/compare/v0.2.20...v0.2.21
[0.2.20]: https://github.com/bradleygolden/puck/compare/v0.2.19...v0.2.20
[0.2.19]: https://github.com/bradleygolden/puck/compare/v0.2.18...v0.2.19
[0.2.18]: https://github.com/bradleygolden/puck/compare/v0.2.17...v0.2.18
[0.2.17]: https://github.com/bradleygolden/puck/compare/v0.2.16...v0.2.17
[0.2.16]: https://github.com/bradleygolden/puck/compare/v0.2.15...v0.2.16
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
