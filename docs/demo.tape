Require agent-monitor-hs

Output docs/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1000
Set Height 600
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set CursorBlink false
Set TypingSpeed 50ms
Set Padding 10

Env PS1 "$ "

Type "agent-monitor-hs docs/sample-session.jsonl"
Enter
Sleep 2s

# Navigate down through the tree
Down
Sleep 800ms
Down
Sleep 800ms
Down
Sleep 800ms
Down
Sleep 800ms
Down
Sleep 800ms
Down
Sleep 800ms
Down
Sleep 800ms
Down
Sleep 800ms
Down
Sleep 800ms

# Back up to top
Up
Sleep 500ms
Up
Sleep 500ms
Up
Sleep 500ms
Up
Sleep 500ms
Up
Sleep 500ms
Up
Sleep 500ms
Up
Sleep 500ms
Up
Sleep 500ms
Up
Sleep 1.5s

# Show help overlay
Type "?"
Sleep 2s

# Dismiss help
Type " "
Sleep 1s

# Quit
Type "q"
Sleep 500ms
