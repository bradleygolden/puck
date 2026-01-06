# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Puck.Sandbox.Eval` - In-process code evaluation with Lua support
- `Puck.Sandbox.Eval.Lua` - Lua sandbox with timeout, memory limits, and callbacks

### Changed

- Reorganized sandbox modules: `Puck.Sandbox.Runtime` for containers, `Puck.Sandbox.Eval` for interpreters

### Removed

- Native tool calling support (use structured outputs with discriminated unions instead)

## [0.1.0] - 2025-01-04

The first release!

[Unreleased]: https://github.com/bradleygolden/puck/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bradleygolden/puck/releases/tag/v0.1.0
