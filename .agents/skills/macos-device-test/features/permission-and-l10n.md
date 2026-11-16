# Permission and localization

The sandboxed app acts on a folder only after the user grants it once through the system folder panel; the bookmark
then covers that folder's subtree. Menu titles and alerts follow the system language (English fallback; zh-Hans, ja,
es, fr supported).

## Sub-features

- `PERM-01`: the first action on a file in an ungranted folder shows the folder-authorization panel; choosing the
  folder lets the action proceed; cancelling performs nothing.
- `PERM-02`: after relaunch the same folder needs no new panel (the bookmark is reused); Settings → folder permissions
  lists it.
- `L10N-01`: the Finder menu titles and the extension alerts are in the system language and have no raw keys or
  `__rclick_missing_localization__` warnings in the log.
- `L10N-02`: with `app-lang.txt`, the Settings window appears in that language.

## How to get to it (user POV)

Right-click a file in a folder RClick has never been granted and choose New File, Hide or Delete Direct. Settings →
General / folder permissions lists the granted folders.

## Driving it

Preconditions: baseline; the App Group backup from runbook §5, because a grant writes a bookmark into it. The fixture
folder must not be inside an already-granted folder (check Settings' list first; if `~/` or `/` is granted, PERM-01
is NOT VERIFIED on this machine).

1. `PERM-01`: right-click the background → New File → TXT. Result: the panel (`axdump.sh <rclick pid>`); capture
   `PERM-01-panel`. Cancel → no file created. Repeat → `panel-choose.sh "$RUN_DIR" "$RUN_DIR/fixtures"` → the file
   is created. Disclose the AX path write.
2. `PERM-02`: quit RClick through its UI, `cleanup.sh`, `launch.sh` into a new run directory (same bundle path is
   fine: write `bundle.path` and `build.json` from the first run), doctor, New File again → no panel. Settings lists
   the folder. Record that the same build created and resolved the bookmark.
3. `L10N-01`: read the system language (`defaults read -g AppleLanguages`, read-only). Compare the menu readbacks and
   alert texts from the other recipes with `FinderSyncExt/Localizable.xcstrings` for that language. Search the log for
   `Missing localization`. Other languages: NOT VERIFIED unless the owner's system already uses them.
4. `L10N-02`: a run with `app-lang.txt` = `ja` (or another supported tag) → the Settings window titles are Japanese.

## Gotchas

- A grant persists in the shared App Group: restore the settings backup (or remove the grant through Settings, the
  user path) at the end, and record it.
- Never pre-grant folders, copy bookmarks, or change the system language.
- `app-lang.txt` does not reach the extension; menu language rows are judged against the system language only.
