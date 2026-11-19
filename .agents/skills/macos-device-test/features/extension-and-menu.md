# Extension and menu presence

With RClick running and its Finder extension enabled, Finder's context menu and the RClick toolbar button show the
configured RClick items: actions, Open With apps, New File templates and Common Dirs, inline or in submenus as set in
Settings.

## Sub-features

- `EXT-01`: exactly one `cn.anzchy.RClick.FinderSyncExt` registration, from this build, enabled; one extension process.
- `EXT-02`: right-click on a file shows the RClick items.
- `EXT-03`: right-click on a folder and on a multi-selection (file + folder) shows the items.
- `EXT-04`: right-click on the window background shows the items (New File, Common Dirs, apps for the folder).
- `EXT-05`: right-click on a sidebar entry shows the items for the sidebar trigger.
- `EXT-06`: the RClick toolbar button (once the owner adds it to the toolbar) opens the same menu; apps hidden for the
  toolbar in Settings are absent there and present in the context menu.

## How to get to it (user POV)

Launch RClick, enable the extension in System Settings, open any Finder window and right-click a file, a folder, the
empty area or a sidebar item. Customize the toolbar (View → Customize Toolbar…) to add the RClick button.

## Driving it

Preconditions: baseline; doctor PASS including `extension-registered`, `extension-enabled`, `extension-process`.

1. `EXT-01`: save `pluginkit -m -v -i cn.anzchy.RClick.FinderSyncExt` and `doctor.txt`. Result: one `+` line whose path
   is inside `$RUN_DIR`'s bundle.
2. `EXT-02`: `ui.sh open-menu alpha.txt`, then `ui.sh menu X,Y > "$RUN_DIR/menus/EXT-02-file.txt"`; region
   screenshot `EXT-02-file-menu` if Screen Recording is granted. Result: the Actions items (Copy Path, Copy File Name, Delete Direct, AirDrop, Hide, Unhide — or
   the **Actions** submenu), Open With apps, **New File**, Common Dirs. `ui.sh close-menu X,Y`.
3. `EXT-03`: right-click `folder a` (`ui.sh open-menu "folder a"`); `ui.sh close-menu X,Y`; then select `alpha.txt`
   and `folder a` (⌘-click) and right-click the selection. Result: the items appear both times. Close each menu with
   `ui.sh close-menu X,Y` at its menu point before the next step.
4. `EXT-04`: right-click empty space below the last row (`ui.sh open-menu --background`, then `ui.sh menu X,Y`).
   Result: the items for the container trigger. `ui.sh close-menu X,Y`.
5. `EXT-05`: right-click the fixture folder's entry in the sidebar (drag it into Favorites only with the owner's
   consent; otherwise use an existing sidebar entry such as Desktop and only read the menu, never choose an action).
   Result: the items for the sidebar trigger. `ui.sh close-menu X,Y` at the point the menu was read at.
6. `EXT-06`: if the owner added the RClick toolbar button, click it. Result: the same sections; the Settings → Apps
   toolbar visibility is respected. Otherwise NOT VERIFIED (toolbar button not added; adding it changes Finder's
   toolbar, an owner step).
7. Save the extension log lines for the menu kinds (`构建菜单，触发方式: …`) and `菜单构建耗时` for each menu.

## Gotchas

- The first right-click after launch may show **RClick (loading...)** while the extension asks for the config;
  re-open the menu once. Note it if it persists past the first try.
- A second registered copy (e.g. Xcode DerivedData) can serve the menu instead of this build: doctor must pass first.
- The sidebar menu on a volume or system location reads other state; never choose an action from it.
