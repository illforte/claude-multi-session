# Claude Multi-Session Orchestrator

Spawn and manage parallel [Claude Code](https://claude.ai/claude-code) sessions automatically. Run multiple AI coding tasks simultaneously and aggregate results.

## Features

- **Parallel Execution** - Run up to 4+ Claude sessions simultaneously
- **Live Dashboard** - Monitor progress with real-time status updates
- **Auto Timeout** - Kill runaway sessions after configurable timeout
- **Cost Tracking** - Aggregate costs across all sessions
- **Cross-Platform** - Works on macOS and Linux
- **Graceful Shutdown** - SIGTERM with fallback to SIGKILL

## Requirements

- [Claude Code CLI](https://claude.ai/claude-code) (`claude` command)
- `jq` - JSON processor
- `bc` - Calculator for cost aggregation
- Bash 4.0+

## Installation

### Quick Install

```bash
# Download the script
curl -O https://raw.githubusercontent.com/illforte/claude-multi-session/main/claude-multi-session.sh
chmod +x claude-multi-session.sh

# Optionally move to PATH
sudo mv claude-multi-session.sh /usr/local/bin/claude-multi
```

### From Source

```bash
git clone https://github.com/illforte/claude-multi-session.git
cd claude-multi-session
chmod +x claude-multi-session.sh

# Optional: Add to PATH
ln -s $(pwd)/claude-multi-session.sh /usr/local/bin/claude-multi
```

### Install Dependencies

```bash
# macOS
brew install jq bc

# Ubuntu/Debian
apt install jq bc
```

## Usage

### Run Multiple Tasks in Parallel

```bash
./claude-multi-session.sh run-multi '[
  {"id": "task-1", "prompt": "Fix all TypeScript errors in src/"},
  {"id": "task-2", "prompt": "Add unit tests for the auth module"},
  {"id": "task-3", "prompt": "Update README with API documentation"}
]'
```

With custom settings:

```bash
./claude-multi-session.sh run-multi '<json>' sonnet 10 4
# Arguments: <json> [model] [budget] [max-parallel]
```

### Monitor Progress

```bash
./claude-multi-session.sh status
```

Output:
```
═══════════════════════════════════════════════════════════════
        Claude Multi-Session Status Dashboard
═══════════════════════════════════════════════════════════════

  🔄 task-1              running         45s (running)   (2.5KB)
  ✅ task-2              completed       123s            (4.1KB)
  🔄 task-3              running         30s (running)   (1.2KB)

───────────────────────────────────────────────────────────────
  Total: 3 | Completed: 1 | Running: 2 | Failed: 0
═══════════════════════════════════════════════════════════════
```

### View Results

```bash
./claude-multi-session.sh result task-1
```

### Start a Single Session

```bash
./claude-multi-session.sh start my-task "Refactor the payment module"
```

### Stop Sessions

```bash
# Stop one session
./claude-multi-session.sh stop task-1

# Stop all sessions
./claude-multi-session.sh stop-all
```

### Clean Up

```bash
./claude-multi-session.sh clean
```

## Configuration

Configure via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_SESSIONS_DIR` | `/tmp/claude-sessions` | Where session files are stored |
| `CLAUDE_PROJECT_DIR` | Current directory | Project root for Claude sessions |
| `CLAUDE_SESSION_TIMEOUT` | `600` (10 min) | Max seconds per session |
| `CLAUDE_DEFAULT_MODEL` | `sonnet` | Default Claude model |
| `CLAUDE_DEFAULT_BUDGET` | `5` | Default budget in USD |
| `CLAUDE_MAX_PARALLEL` | `4` | Max parallel sessions |

Example:

```bash
export CLAUDE_SESSION_TIMEOUT=1800  # 30 minutes
export CLAUDE_DEFAULT_MODEL=opus
./claude-multi-session.sh run-multi '[...]'
```

## Security Note

Sessions run with `--permission-mode bypassPermissions` for automation. This means Claude can modify files without confirmation. Only use in trusted environments and reviewed codebases.

## Task JSON Schema

```json
[
  {
    "id": "unique-task-id",
    "prompt": "Task description for Claude"
  }
]
```

- `id` - Unique identifier for the task (used in status/result commands)
- `prompt` - The prompt sent to Claude Code

## Examples

### Fix TypeScript Errors in Parallel

```bash
./claude-multi-session.sh run-multi '[
  {"id": "api-types", "prompt": "Fix TypeScript errors in src/api/"},
  {"id": "ui-types", "prompt": "Fix TypeScript errors in src/components/"},
  {"id": "util-types", "prompt": "Fix TypeScript errors in src/utils/"}
]' haiku 2 3
```

### Run Tests Across Modules

```bash
./claude-multi-session.sh run-multi '[
  {"id": "test-auth", "prompt": "Run tests for auth module and fix failures"},
  {"id": "test-api", "prompt": "Run tests for API module and fix failures"},
  {"id": "test-ui", "prompt": "Run tests for UI components and fix failures"}
]'
```

### Documentation Sprint

```bash
./claude-multi-session.sh run-multi '[
  {"id": "readme", "prompt": "Update README.md with current API"},
  {"id": "api-docs", "prompt": "Generate API documentation from source"},
  {"id": "changelog", "prompt": "Update CHANGELOG with recent commits"}
]' haiku 1 4
```

## Logs

Session logs are written to:
- Session output: `$CLAUDE_SESSIONS_DIR/<task-id>.output`
- Orchestrator log: `$CLAUDE_SESSIONS_DIR/orchestrator.log`

## Troubleshooting

### "Missing required dependencies"

Install the required tools:
```bash
brew install jq bc  # macOS
apt install jq bc   # Linux
```

### Sessions timing out

Increase the timeout:
```bash
export CLAUDE_SESSION_TIMEOUT=1800  # 30 minutes
```

### "Invalid JSON input"

Validate your JSON:
```bash
echo '[{"id":"test","prompt":"test"}]' | jq .
```

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Contributions welcome! Please open an issue or PR.

## Related Projects

- [Claude Code](https://claude.ai/claude-code) - The Claude Code CLI
- [claude-snippets-manager](https://github.com/illforte/claude-snippets-manager) - Manage Claude Code snippets
