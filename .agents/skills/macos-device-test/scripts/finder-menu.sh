#!/bin/zsh
# finder-menu.sh — print the items of Finder's open context menu (or toolbar-button menu), one per line:
#   <title>|<enabled>|<submenu item count>
# Read-only accessibility; requires the host terminal's Accessibility grant. Run while the menu is open, then
# dismiss it with finder-kc.sh 53. Not yet proven live in RClick: if it prints nothing while a menu is visibly
# open, record that as a tool limit and fall back to a screenshot of the menu region.
osascript <<'OSA'
tell application "System Events" to tell process "Finder"
  set out to ""
  set menusOpen to (every UI element whose role is "AXMenu")
  if (count of menusOpen) is 0 then error "no open menu on Finder"
  repeat with m in menusOpen
    repeat with mi in (menu items of m)
      set t to name of mi
      if t is missing value then set t to "—"
      set n to 0
      try
        set n to count of menu items of menu 1 of mi
      end try
      set out to out & t & "|" & (enabled of mi as text) & "|" & n & linefeed
    end repeat
  end repeat
  return out
end tell
OSA
