# agent-monitor-hs

A terminal UI dashboard for monitoring Claude Code subagent hierarchy in real-time.

![Haskell](https://img.shields.io/badge/Haskell-GHC2021-5e5086)
![License](https://img.shields.io/badge/license-MIT-blue)

![demo](docs/demo.gif)

## What It Does

When Claude Code spawns background agents via the Task tool, this TUI shows you:

- **Agent tree** with live status icons (✓ completed, ⟳ running, ✗ failed)
- **Detail panel** for the selected agent (tokens, duration, tool calls, last output)
- **Status bar** with aggregate counts and total token usage
- **Live tailing** — updates every 500ms as agents complete

## Install

```bash
# Run directly (auto-detects newest session)
nix run github:jhhuh/agent-monitor-hs

# Run with specific file
nix run github:jhhuh/agent-monitor-hs -- ~/.claude/projects/<project>/<session-uuid>.jsonl

# Or build with cabal
cabal build
```

### Keybindings

| Key | Action |
|-----|--------|
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `?` | Show help overlay |
| `q` / `Esc` | Quit |

## Dependencies

- [brick](https://hackage.haskell.org/package/brick) — Terminal UI framework
- [aeson](https://hackage.haskell.org/package/aeson) — JSON parsing
- [vty](https://hackage.haskell.org/package/vty) — Terminal backend

## License

MIT
