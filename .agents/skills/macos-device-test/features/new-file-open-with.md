# New File, Open With and Common Dirs

New File creates a file from a template in the target folder, reveals it and starts renaming it. Open With opens the
selection (or, for terminal presets, the containing folder) in a configured app. Common Dirs open a pinned folder.

## Sub-features

- `NEW-01`: New File → each template (txt, md, json, docx, pptx, xlsx, pages, key, numbers) creates `Untitled.<ext>`
  (or a unique variant) in the clicked folder, or in the folder of a clicked file, with the template's bytes.
- `NEW-02`: after creation the file is selected in Finder and in rename mode (needs Accessibility for RClick).
- `NEW-03`: without Accessibility for RClick, a one-time explanation appears instead of a silent failure.
- `APP-01`: Open With → TextEdit (or another configured non-terminal app) opens the selected file.
- `APP-02`: Open With → Terminal opens the containing folder of a selected file (automatic containing-folder rule).
- `APP-03`: an app hidden for the context menu in Settings is absent from the context menu.
- `DIR-01`: Common Dirs → a pinned folder opens in Finder.

## How to get to it (user POV)

Right-click a folder, a file or the window background → **New File** → a type. Right-click a file → an app name (or
**Open With** submenu). Right-click → a Common Dir.

## Driving it

Preconditions: baseline; fixture folder granted. Record whether RClick has Accessibility (System Settings shows it;
the run never toggles it). Note which apps RClick lists.

1. `NEW-01`: right-click the background → New File → TXT. Result: `ls` shows the new file in `$RUN_DIR/fixtures`;
   `shasum` matches the template from the built bundle's resources (or is empty for txt). Repeat once to check the
   unique name. Right-click `alpha.txt` → New File → Markdown: the file lands next to it.
2. `NEW-02`: with Accessibility granted to RClick, the new file is selected and its name field is editable
   (`ui.sh rows` and `ui.sh selection` show the new file selected; the name field is an `AXTextField`); type `renamed` + Return through `finder-kc.sh`/AX, then `ls`.
   Without it: NOT VERIFIED for `NEW-02`, and run `NEW-03`.
3. `NEW-03`: without Accessibility for RClick, the first New File shows the explanation once (`ui.sh dialog <rclick pid>`), naming the
   RClick app, not the extension; a second New File does not repeat it.
4. `APP-01`: right-click `alpha.txt` → TextEdit. Result: TextEdit opens the file (window title); quit only the
   TextEdit document window the run opened (⌘W), not TextEdit if it was already running.
5. `APP-02`: right-click `folder a/inner.txt` → Terminal. Result: a Terminal window whose cwd is `folder a`
   (window title or `pwd` typed only in that new window). Close only that window.
6. `APP-03`: only if the brief authorizes changing Settings (with the §5 backup): hide one app for the context menu,
   re-open the menu → it is absent; restore.
7. `DIR-01`: right-click → a Common Dir (e.g. Downloads) → a Finder window opens there. Close only that window; never
   open files in it.

## Gotchas

- iWork templates (pages/key/numbers) may open a "Choose a template" UI if the app is opened; don't open them.
- Opening an app the user is already running brings their windows forward: check `pgrep -x` first and record it.
- `NEW-02` rename waits for Finder to become active; a terminal stealing focus can make it miss.
