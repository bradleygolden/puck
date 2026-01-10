# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/bradleygolden/puck/compare/v0.2.5...HEAD
[0.2.5]: https://github.com/bradleygolden/puck/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/bradleygolden/puck/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/bradleygolden/puck/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/bradleygolden/puck/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/bradleygolden/puck/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/bradleygolden/puck/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bradleygolden/puck/releases/tag/v0.1.0
