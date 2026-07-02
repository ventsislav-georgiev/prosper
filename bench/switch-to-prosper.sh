#!/bin/bash
# Transition the benchmark from Cotypist to Prosper:
#   1. quit Cotypist so it can't compete for the field / hotkeys
#   2. toggle Prosper autocomplete ON via its ⌘X global shortcut
#   3. verify the pref flipped
# Run AFTER the Cotypist bench pass, and only when no bench is driving the machine.
set -u
echo "== quitting Cotypist =="
osascript -e 'tell application "Cotypist" to quit' 2>/dev/null
sleep 1
pkill -x Cotypist 2>/dev/null
sleep 1
echo "Cotypist procs: $(pgrep -x Cotypist | wc -l | tr -d ' ')"

echo "== current Prosper autocompleteEnabled =="
defaults read eu.illegible.prosper autocompleteEnabled 2>/dev/null

echo "== sending ⌘X to toggle Prosper autocomplete ON =="
# Prosper registers ⌘X as a global toggle; nothing selected → the stray Cut is a no-op.
osascript -e 'tell application "System Events" to keystroke "x" using command down'
sleep 1
echo "== after toggle =="
defaults read eu.illegible.prosper autocompleteEnabled 2>/dev/null
