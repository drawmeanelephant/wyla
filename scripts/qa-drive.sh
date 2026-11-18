#!/bin/sh
# Drives the running WYLA menu bar app through System Events: opens the menu, opens the main
# window, checks the window's text, and quits through the menu. The process that runs this
# script (Terminal, an IDE, or an agent host) needs Accessibility permission in
# System Settings > Privacy & Security > Accessibility.
# Usage: scripts/qa-drive.sh [path/to/Wyla.app]   (launches the app first when given a path)
set -eu

if [ $# -gt 0 ]; then
    open -n "$1"
    sleep 3
fi
pgrep -x Wyla >/dev/null || { echo "WYLA is not running. Run \`make run\` first." >&2; exit 1; }

osascript <<'APPLESCRIPT'
on menuBarItem()
    tell application "System Events" to return menu bar item 1 of menu bar 2 of process "Wyla"
end menuBarItem

on fail(message)
    error "qa-drive: " & message number 1
end fail

tell application "System Events"
    tell process "Wyla"
        click my menuBarItem()
        delay 0.5
        set itemNames to name of every menu item of menu 1 of my menuBarItem()
        if itemNames does not contain "Open WYLA" then my fail("menu has no Open WYLA item: " & (itemNames as text))
        log "menu: " & (itemNames as text)
        click menu item "Open WYLA" of menu 1 of my menuBarItem()
        delay 1.5
        if not (exists window "WYLA") then my fail("main window did not open")
        set windowText to ""
        set elements to entire contents of window "WYLA"
        repeat with i from 1 to count of elements
            try
                set element to item i of elements
                if value of attribute "AXRole" of element is "AXStaticText" then
                    set windowText to windowText & (value of attribute "AXValue" of element as text) & " / "
                end if
            end try
        end repeat
        log "window text: " & windowText
        if windowText does not contain "No activity recorded yet" then my fail("main window is missing its empty-state text")
        click my menuBarItem()
        delay 0.5
        click menu item "Quit WYLA" of menu 1 of my menuBarItem()
    end tell
end tell
APPLESCRIPT

for _ in 1 2 3 4 5; do
    pgrep -x Wyla >/dev/null || { echo "QA drive passed: menu, main window, and quit all work."; exit 0; }
    sleep 1
done
echo "qa-drive: WYLA did not quit from its menu." >&2
exit 1
