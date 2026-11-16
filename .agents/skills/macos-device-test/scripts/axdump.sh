#!/bin/zsh
# axdump.sh <PID | process name> — every window of the process, one line per element:
#   <window title>|<role>|<subrole>|<description or title>|<value>
# Use it to read an alert (NSAlert from FinderSyncExt: "RClick did not respond", "RClick is not running"),
# the Delete Direct confirmation, or the permission panel's text, instead of reading pixels.
[[ $# -eq 1 && -n $1 ]] || { print -u2 'usage: axdump.sh PID|NAME'; exit 2 }
if [[ $1 == <-> ]]; then who="first process whose unix id is $1"; else who="process \"${1//\"/}\""; fi
osascript <<OSA
tell application "System Events" to tell ($who)
  set out to ""
  repeat with w in windows
    set wt to name of w
    if wt is missing value then set wt to ""
    repeat with e in (entire contents of w)
      try
        set r to value of attribute "AXRole" of e
        if r is in {"AXButton", "AXStaticText", "AXCheckBox", "AXTextField"} then
          set sr to ""
          try
            set sr to value of attribute "AXSubrole" of e
          end try
          set d to ""
          try
            set d to description of e
          end try
          if d is missing value or d is "" then
            try
              set d to title of e
            end try
          end if
          set v to ""
          try
            set v to (value of e) as text
          end try
          set out to out & wt & "|" & r & "|" & sr & "|" & d & "|" & v & linefeed
        end if
      end try
    end repeat
  end repeat
  return out
end tell
OSA
