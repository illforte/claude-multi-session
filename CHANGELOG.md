# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-01-03

### Added
- `list` command to show all session task IDs
- Signal handling (SIGINT/SIGTERM) for graceful cleanup
- Task field validation (verifies `id` and `prompt` fields exist)
- Argument validation for `result`, `output`, and `stop` commands
- Stale session detection in `clean` command

### Fixed
- Prompt display now only shows `...` if actually truncated
- Integer division rounding for duration display
- Improved output success detection

### Changed
- Version bumped to 1.1.0
- Added changelog to script header comments

## [1.0.0] - 2026-01-02

### Added
- Initial release
- `run-multi` command for parallel task execution
- `start` command for single session
- `status` command with live dashboard
- `result` and `output` commands for viewing results
- `stop` and `stop-all` for session control
- `clean` for cleanup
- Session timeout with configurable duration (default 10 minutes)
- Graceful shutdown (SIGTERM then SIGKILL)
- Cost aggregation across sessions
- Cross-platform date parsing (macOS and Linux)
- JSON validation before processing
- Persistent logging to orchestrator.log
- Dependency checking on startup
- Environment variable configuration
- Comprehensive README with examples

### Security
- Security note about bypassPermissions mode
- No hardcoded paths or sensitive data
- All configuration via environment variables
