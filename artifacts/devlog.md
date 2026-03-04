# Development Log: agent-monitor-hs

## 2026-03-04: Initial implementation

### Context
During a session with ~50 subagents spawned for parallel research, experiments, and tool building, needed a way to monitor the agent hierarchy live.

### Design decisions
- **brick over other TUI libs**: brick is the standard Haskell TUI library with good documentation and a clean architecture (pure rendering functions, event handling via state updates).
- **Polling over inotify**: Used `threadDelay`-based polling (500ms) instead of `fsnotify` to keep dependencies minimal. The JSONL files are append-only so polling is sufficient.
- **Strict ByteString IO**: Avoided lazy IO for file reading to prevent file handle leaks when tailing growing files.
- **callCabal2nix for Nix packaging**: Works well for pure Haskell packages. Required using unnamed library stanza (not named internal library) in the .cabal file.

### Known limitations
- Agent tree is flat — Claude Code stores all subagent files at the same level in `subagents/` directory regardless of actual nesting. Sub-subagent hierarchy is not reconstructible from the file system.
- Some completed agents may show as "running" if their final `end_turn` event isn't detected.
- No sub-subagent file parsing — only top-level subagent JSONL files are read.

## 2026-03-04: Extraction to standalone repo

Extracted to standalone repo using `git subtree split` to preserve commit history.
