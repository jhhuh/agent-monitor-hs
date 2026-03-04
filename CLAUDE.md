# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Run (auto-detects newest session)
nix run

# Run with specific file
nix run -- path/to/session.jsonl

# Dev build (faster iteration)
nix develop -c cabal build
```

No test suite exists yet.

## Architecture

TUI dashboard for monitoring Claude Code subagent hierarchy in real-time. Built with Haskell + brick.

### Module Map

- **`app/Main.hs`** — CLI entry point. Parses args or auto-detects newest `.jsonl` via `Watcher.findNewestJsonl`, builds initial state, launches brick app.
- **`src/AgentMonitor/Types.hs`** — Core types: `AgentInfo`, `AppState`, `AgentStatus`, brick event/resource types.
- **`src/AgentMonitor/Parser.hs`** — JSONL event processing. The core logic lives here.
- **`src/AgentMonitor/Watcher.hs`** — File tailing via polling (500ms `threadDelay`). Uses `IORef Int` for main file and `IORef (Map FilePath Int)` for subagent files. Also provides `discoverProjects` for the project picker.
- **`src/AgentMonitor/UI.hs`** — Brick TUI: tree view (40% left), detail panel (60% right), status bar, `?` help overlay, `p` project picker, `h`/`l` focus switching, `g`/`G` scroll jumps.

### Data Flow

```
Main JSONL + subagent files → parseJsonlLines + processSubagentFile → AppState
                                                                         ↓
Watcher polls main + subagent files (500ms) → readNewLines/readNewSubagentLines
                                                → new events → processEvent → updated AppState
                                                                                    ↓
                                                                          brick redraws UI
```

### Session Detection

Auto-detection priority:
1. Running session: checks `/tmp/claude-$UID/<project>/tasks/` for active subagent symlinks, extracts session UUID from symlink targets
2. Newest `.jsonl` by mtime in current project directory
3. Newest `.jsonl` by mtime across all projects

### Subagent Nesting

Subagent files (`<uuid>/subagents/agent-*.jsonl`) are parsed at startup to discover sub-subagent Task calls. The `agentId` hex string in subagent files maps to `aiAgentId` in the agent tree, enabling reparenting of nested agents under the correct parent.

### Agent Identity Model

Events are attributed to agents via `parentToolUseID`:
- `Nothing` → belongs to `"main"` session
- `Just id` → belongs to the subagent whose `tool_use` id matches

New subagents are spawned when `processAssistant` finds `Task` or `Skill` tool_use blocks in message content. The `tool_use` id becomes the agent's identity key in the `Map AgentId AgentInfo`.

Sub-subagents (nested Task calls within `agent_progress` events) are also tracked — `processAgentProgress` extracts inner assistant messages and spawns children.

## Conventions

- GHC2021 language standard
- `-Wall` with zero warnings policy
- Brick for TUI, aeson for JSON, vty-crossplatform for terminal backend
- No `OverloadedStrings` at cabal level — enabled per-file via pragma where needed

## Gotchas

- **Flat tree appearance**: Claude Code stores subagent session files at the same directory level regardless of nesting depth. The tree reconstructs hierarchy from `parentToolUseID` linkage and subagent file parsing, but if a `progress` event arrives before its parent `Task` tool_use was parsed, the agent gets parented to `"main"` (see `updateAgent` fallback in Parser.hs).
- **Completed agent filtering**: Completed agents are hidden by default (`c` to toggle). A completed parent with running descendants stays visible to avoid hiding active agents. The `flattenTreeFiltered` function handles both navigation order and tree rendering.
- **No streaming parse**: The initial load reads the entire file into memory (`BL.readFile`), parses all lines, then tailing reads incremental chunks. Large session files may cause a pause on startup.
- **IORef tailing**: File watching uses `IORef Int` for main file byte offset and `IORef (Map FilePath Int)` for subagent files. The watcher only signals "file grew"; the actual read happens in `handleFileUpdate` on the brick event thread.

## Keybindings

| Key | Tree focused | Detail focused | Global |
|-----|-------------|---------------|--------|
| `j`/`↓` | Select down | Scroll down | — |
| `k`/`↑` | Select up | Scroll up | — |
| `l` | Focus detail | — | — |
| `h` | — | Focus tree | — |
| `g` | — | Scroll to top | — |
| `G` | — | Scroll to bottom | — |
| `c` | Toggle completed | Toggle completed | — |
| `r` | — | — | Manual refresh |
| `p` | — | — | Project picker |
| `?` | — | — | Toggle help |
| `q`/`Esc` | — | — | Quit (or close overlay) |
