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

# Navigate down through agents
Down
Sleep 1s
Down
Sleep 1s
Down
Sleep 1s
Down
Sleep 1s

# Navigate back up
Up
Sleep 1s
Up
Sleep 1.5s

# Quit
Type "q"
Sleep 500ms
