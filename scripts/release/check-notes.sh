#!/bin/sh
# Optional directory supports static offline fixtures; workflow uses docs/release.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo 'Usage: check-notes.sh VERSION [NOTES_DIRECTORY]' >&2
  exit 1
fi
notes=${2:-docs/release}/$1-notes.md
if [ ! -f "$notes" ]; then
  echo "Release notes missing: $notes" >&2
  exit 1
fi
# Uppercase whole words only; punctuation/table separators count as boundaries.
# Handle grep errors separately so unreadable notes cannot pass.
result=0
LC_ALL=C grep -Eq '(^|[^[:alnum:]_])(PENDING|TBD)([^[:alnum:]_]|$)' "$notes" || result=$?
case "$result" in
  0) echo "Release notes unfinished (PENDING or TBD): $notes" >&2; exit 1 ;;
  1) printf 'PASS release notes ready: %s\n' "$notes" ;;
  *) echo "Cannot read release notes: $notes" >&2; exit 1 ;;
esac
