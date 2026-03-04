# agent-monitor-hs

A terminal UI dashboard for monitoring Claude Code subagent hierarchy in real-time. Built with Haskell + [brick](https://hackage.haskell.org/package/brick).

![Haskell](https://img.shields.io/badge/Haskell-GHC2021-5e5086)
![License](https://img.shields.io/badge/license-MIT-blue)

## What It Does

When Claude Code spawns background agents via the Task tool, this TUI shows you:

- **Agent tree** with box-drawing connectors, status-colored text (yellow running, green completed, red failed), and inline durations
- **Scrollable detail panel** with compact metadata header and streaming output for the selected agent
- **Status bar** with session name, agent counts, token totals, and elapsed time
- **Live tailing** — polls every 500ms, auto-scrolls on new content
- **Process liveness detection** — scans `/proc` to detect agents whose processes exited without clean shutdown
- **Project & session picker** — browse all Claude Code projects and sessions (`p` for projects, `s` for current project sessions)

## Install

```bash
# Run directly (auto-detects newest session in current project)
nix run github:jhhuh/agent-monitor-hs

# Run with specific session file
nix run github:jhhuh/agent-monitor-hs -- path/to/session.jsonl

# Debug: dump parsed agent state
nix run github:jhhuh/agent-monitor-hs -- --dump-state
```

## Keybindings

| Key | Tree focused | Detail focused | Global |
|-----|-------------|---------------|--------|
| `j` / `↓` | Select down | Scroll down | — |
| `k` / `↑` | Select up | Scroll up | — |
| `l` | Focus detail | — | — |
| `h` | — | Focus tree | — |
| `g` | — | Scroll to top | — |
| `G` | — | Scroll to bottom | — |
| `c` | — | — | Toggle completed agents |
| `r` | — | — | Manual refresh |
| `p` | — | — | Project picker |
| `s` | — | — | Session picker |
| `?` | — | — | Help overlay |
| `q` / `Esc` | — | — | Quit / close overlay |

## Session Auto-Detection

The monitor automatically finds the best session to display:

1. **Running session** — checks `/tmp/claude-$UID/<project>/tasks/` for active subagent symlinks
2. **Newest in current project** — latest `.jsonl` by modification time in `~/.claude/projects/<cwd>/`
3. **Newest across all projects** — falls back to the most recent session globally

## Architecture

```
src/AgentMonitor/
  Types.hs        — Core types (AgentInfo, AppState, AgentStatus)
  Parser.hs       — JSONL event processing, agent tree construction
  ProcChecker.hs  — /proc-based liveness detection (Linux)
  Watcher.hs      — File polling, project/session discovery
  UI.hs           — Brick TUI rendering and event handling
app/Main.hs       — CLI entry point
```

### Agent Identity Model

Events are attributed to agents via `parentToolUseID`:
- `null` → main session
- Otherwise → subagent whose `tool_use` id matches

Subagents spawn from `Task` and `Skill` tool_use blocks. The tree reconstructs hierarchy from `parentToolUseID` linkage and `agent_progress` events.

### Liveness Detection

The monitor scans `/proc/*/cmdline` for Claude processes, walks the process tree via PPID, then checks `/proc/<pid>/fd/` symlinks to see which `.jsonl` files are still held open. Agents whose files are closed get marked as completed — catching crashed or killed agents that never sent an `end_turn` event. PID tree is cached and rescanned every 10 seconds.

## Dependencies

- [brick](https://hackage.haskell.org/package/brick) — Terminal UI framework
- [aeson](https://hackage.haskell.org/package/aeson) — JSON parsing
- [vty](https://hackage.haskell.org/package/vty) + [vty-crossplatform](https://hackage.haskell.org/package/vty-crossplatform) — Terminal backend

## Sister Project

[claude-agent-monitor](https://github.com/jhhuh/claude-agent-monitor) — Python + Textual implementation with identical UI and behavior.

## License

MIT
