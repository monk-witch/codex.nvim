# Changelog

All notable changes to `codex.nvim` are documented here. The project follows [Semantic Versioning](https://semver.org/); before `1.0.0`, a breaking public-contract change increments the minor version.

## [0.1.0] - 2026-09-11

First supported public release.

### Added

- Local App Server chat selection scoped to NeoVim's current project directory, with persistence across NeoVim restarts.
- `:CodexList`, `:CodexLS`, `:CodexSend`, and `:CodexChat`, plus guarded `:CoLS`, `:CoSe`, and `:CoCh` short aliases.
- Keyboard-only chat picker, native-statusline Braille progress indicator, and compact sent-input confirmation.
- Public Lua API for configuration, listing, sending input, selected-chat state, and statusline integration.
- Native `:checkhealth codex`, committed `:help codex` documentation and tags, a protocol-faithful headless App Server test suite, and GitHub Actions CI against NeoVim `0.12.5`.
- Contributor guidance, issue and pull-request templates, format conventions, and a security reporting policy.

### Compatibility

- NeoVim `0.12.5` and Codex CLI/App Server `0.154.0` are supported minimum versions.
- The documented commands, configuration keys, public Lua API, persistence format, and minimum versions form the `0.1` compatibility contract.

## [0.0.19] - 2026-09-11

Repository-contributor guidance, issue templates, and security policy.

## [0.0.18] - 2026-09-11

Native NeoVim help, generated help tags, documented installation, and public contract.

## [0.0.17] - 2026-09-11

GitHub Actions CI and StyLua formatting checks.

## [0.0.16] - 2026-09-11

Headless local App Server protocol tests.

## [0.0.15] - 2026-09-11

Native NeoVim health check.

## [0.0.14] - 2026-09-11

Idempotent setup lifecycle.
