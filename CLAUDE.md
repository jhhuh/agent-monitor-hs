# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Run (auto-detects newest session)
nix run

# Run with specific file
nix run -- path/to/session.jsonl

# Debug: dump parsed state
nix run .# -- --dump-state
```

No test suite exists yet.

## Architecture

TUI dashboard for monitoring Claude Code subagent hierarchy in real-time. Built with Haskell + brick.

### Module Map

- **`app/Main.hs`** — CLI entry point. Parses args or auto-detects newest `.jsonl` via `Watcher.findNewestJsonl`, builds initial state, launches brick app.
- **`src/AgentMonitor/Types.hs`** — Core types: `AgentInfo`, `AppState`, `AgentStatus`, `PickerMode`, brick event/resource types.
- **`src/AgentMonitor/Parser.hs`** — JSONL event processing. Core parsing logic, agent tree construction, `extractTokens` helper, `boundedAppend` for output capping.
- **`src/AgentMonitor/ProcChecker.hs`** — `/proc`-based liveness detection. Scans `/proc/*/cmdline` for Claude processes, walks process tree via PPID, checks `/proc/<pid>/fd/` symlinks. Caches PID set for 10s.
- **`src/AgentMonitor/Watcher.hs`** — File tailing via polling (500ms). Uses `IORef Int` for main file and `IORef (Map FilePath Int)` for subagent files. Sends `Tick` every 2s for liveness checks. Provides `discoverProjects`/`discoverSessions` for pickers.
- **`src/AgentMonitor/UI.hs`** — Brick TUI: tree view (40% left), detail panel (60% right), status bar, `?` help overlay, two-level `p` project picker, `s` session picker, `h`/`l` focus switching, `g`/`G` scroll jumps, `c` completed toggle.

### Data Flow

```
Main JSONL + subagent files → parseJsonlLines + processSubagentFile → AppState
                                                                         ↓
Watcher polls main + subagent files (500ms) → readNewLines/readNewSubagentLines
                                                → new events → processEvent → updated AppState
                                                                                    ↓
Liveness checker (2s Tick) → checkOpenFiles via /proc → mark dead agents Completed
                                                                                    ↓
                                                                          brick redraws UI
```

### Session Detection

Auto-detection priority:
1. Running session: checks `/tmp/claude-$UID/<project>/tasks/` for active subagent symlinks, extracts session UUID from symlink targets
2. Newest `.jsonl` by mtime in current project directory
3. Newest `.jsonl` by mtime across all projects

### Agent Identity Model

Events are attributed to agents via `parentToolUseID`:
- `Nothing` → belongs to `"main"` session
- `Just id` → belongs to the subagent whose `tool_use` id matches

New subagents are spawned when `processAssistant` finds `Task` or `Skill` tool_use blocks in message content. The `tool_use` id becomes the agent's identity key in the `Map AgentId AgentInfo`.

Sub-subagents (nested Task calls within `agent_progress` events) are also tracked — `processAgentProgress` extracts inner assistant messages and spawns children.

### Liveness Detection

`ProcChecker.hs` detects dead agents by checking if their `.jsonl` files are still held open:
1. `findClaudeTree` scans `/proc/*/cmdline` for "claude", reads `/proc/<pid>/stat` for PPID, walks descendants
2. `checkOpenFiles` checks `/proc/<pid>/fd/` symlinks for cached Claude PIDs (10s cache TTL)
3. `handleLivenessCheck` in UI.hs runs every 2s via `Tick`, marks Running agents as Completed when their file closes
4. Agent→file mapping stored in `asAgentFiles :: Map AgentId FilePath`

## Conventions

- GHC2021 language standard
- `-Wall` with zero warnings policy
- Brick for TUI, aeson for JSON, vty-crossplatform for terminal backend
- No `OverloadedStrings` at cabal level — enabled per-file via pragma where needed
- `pathToProjectDir` for cwd→project dir name encoding (single source of truth)
- `extractTokens` for token counting (input + cache_read + cache_creation, output)
- `boundedAppend 500` caps output parts per agent

## Keybindings

| Key | Tree focused | Detail focused | Global |
|-----|-------------|---------------|--------|
| `j`/`↓` | Select down | Scroll down | — |
| `k`/`↑` | Select up | Scroll up | — |
| `l` | Focus detail | — | — |
| `h` | — | Focus tree | — |
| `g` | — | Scroll to top | — |
| `G` | — | Scroll to bottom | — |
| `c` | — | — | Toggle completed agents |
| `r` | — | — | Manual refresh |
| `p` | — | — | Project picker (two-level) |
| `s` | — | — | Session picker (current project) |
| `?` | — | — | Toggle help |
| `q`/`Esc` | — | — | Quit / close overlay |

## Gotchas

- **Flat tree appearance**: Claude Code stores subagent session files at the same directory level regardless of nesting depth. The tree reconstructs hierarchy from `parentToolUseID` linkage and subagent file parsing, but if a `progress` event arrives before its parent `Task` tool_use was parsed, the agent gets parented to `"main"` (see `updateAgent` fallback in Parser.hs).
- **Completed agent filtering**: Completed agents are hidden by default (`c` to toggle). A completed parent with running descendants stays visible to avoid hiding active agents.
- **No streaming parse**: Initial load reads the entire file into memory. Large session files may cause a pause on startup.
- **IORef tailing**: File watching uses `IORef Int` for main file byte offset and `IORef (Map FilePath Int)` for subagent files. The watcher only signals "file grew"; the actual read happens in `handleFileUpdate` on the brick event thread.
- **Liveness is Linux-only**: The `/proc` filesystem check only works on Linux. On other platforms, liveness detection is a no-op (agents stay Running until JSONL events mark them complete).

## Sister Project

[claude-agent-monitor](https://github.com/jhhuh/claude-agent-monitor) — Python + Textual implementation with identical UI spec. See `CONVERSATION.md` for cross-project design decisions.
