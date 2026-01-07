# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/bradleygolden/puck/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bradleygolden/puck/releases/tag/v0.1.0
