# Changelog

All notable changes to RClick are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.3.5] - TBD

This first fork release also documents upstream changes from 2.3.2–2.3.4 that never had changelog sections, so the v2.3.4…v2.3.5 compare link covers only part of this section.

### Added
- Opt-in Cut and same-volume Paste (move here), with exclusive keep-both names, partial-failure retry and a durable recovery journal (#8, #9; PR #36)
- Opt-in Undo last move for the latest same-volume Paste, for up to 24 hours including after relaunch; identity checks protect replaced items and original folders (#11)
- Several template snapshots per New File type, editable ordering, Blank entries and Finder submenus; backups retain metadata and report omitted template files (#49; PR #50)
- Valid DOCX, PPTX and XLSX templates; directory/package templates are copied intact; Office/iWork types require a usable template (#24, #49)
- Settings backup and import, log export, and a working Reset All Settings (c849fb2; #52)
- Copy File Name and multi-selection plain-text Copy Path / Copy File Name, one item per line (d4439a7; #25, #28, #32)
- Built-in app presets, per-app toolbar/context-menu visibility, icon styles and automatic/on/off containing-folder behavior (aec622a)
- Offline Copy Path, a quiet host-relaunch hint, and Settings on manual launch/reopen (b11f08e)

### Changed
- Use the fork identity and isolated App Group and communication channels; upstream settings and folder grants are not migrated (#22; PR #23)
- About and update checks use the fork repository; remove star requests and upstream app promotions while retaining GPL attribution (#57)
- Remove the custom_menu.json layout and its Settings controls; menus follow configured apps, actions, file types and common folders (967291e)
- Resetting New File defaults or all settings removes owned template snapshots and restores Blank, preserving original imported files (#49)
- Keep Finder icon caches warm and use lightweight heartbeat replies with reconnection based on peer activity (0a47497)

### Fixed
- Categorize rejected IPC messages with separate rate-limited counts; expected session, delayed/duplicate delivery and recovery rejections use debug logging, while invalid messages remain errors (#76)
- Restrict Paste to a single folder or window background, hide it on packages, support writable/searchable Drop Box destinations and directory aliases, pin source/destination parents and reject unsafe ancestor swaps (#48, #53)
- Report and discard vanished cut sources, preserve same-folder no-ops and retryable failures, quarantine damaged journals and recover interrupted moves without blocking later Paste (#9, #48, #53)
- Refuse Trash folders (including iCloud Drive and cloud-provider Trash), system roots and packages as Paste destinations, refuse moving items out of their cloud container, and recheck destination identity and safety inside coordination (#9)
- Disable the entire New File submenu while the main app is offline (#53)
- Normalize custom extensions on save and creation, including legacy dotless values, boundary dots and multipart extensions; reject whitespace and empty extensions (#51)
- Settings import immediately restores every exported preference and refreshes Finder; omitted keys in older backups retain their values (#52)
- Preserve literal percent sequences in selected paths, names and Open With targets (#5, #28, #32, #59)
- Copy Path is text-only, avoiding the sandbox-rejected file-URL clipboard write (#25)
- Preserve edited built-in extensions and custom empty text/code files; hide unsupported Pages/Keynote/Numbers entries unless a user template is available; localize built-in format names in all supported languages (#24, #49)
- Direct Delete confirms unless Option was held when the menu was built; auto-rename waits for Finder activation and explains the app's missing Accessibility permission once (142b884, 6d8b791)
- Surface failed update installations, validate the staged app version before replacement, keep the running app on relaunch failure and retire older duplicate instances; install into /Applications and trash the old copy when updating from elsewhere (4ab0b17)
- Accept missing release titles/notes and empty release feeds, and choose the highest published version including prereleases (#57)
- Preserve external-drive sidebar icons, update extension/Accessibility settings guidance and refresh permission status while visible (ae089e6, 42bb7af)
- Use the app name for shared warning windows (#24)

### Security
- Authenticate Finder IPC with a per-install key, launch sessions, freshness and replay protection; reject unsigned/tampered messages and unrelated acknowledgements, with a non-modal recovery notice (#6, #43; PR #35)
- Refuse protected folders for Delete Direct, Hide and AirDrop, including the account home, Documents, Library and filesystem root (#5; PR #29)
- File-action and bookmark diagnostics report safe counts, outcomes and closed error categories without selected paths, names or raw file errors (#9, #39)

Device validation of the final release build remains pending (#12), as does first IPC key creation on a clean Mac with the release-signed build (#40). Cross-volume Paste (#10) is outside this release. See the release notes draft for the pending checks.

## [2.3.1] - 2026-10-14

### Fixed
- RClick no longer shows up in the Dock. The app declared no `LSUIElement` and left the Dock by switching its activation policy from inside `applicationDidFinishLaunching`, so any launch that failed before reaching that call — a startup failure, or a bad first launch after installation — stayed a foreground app with a Dock icon until the Dock was restarted. It is declared as an agent now, so it never appears there at all

## [2.3.0] - 2026-09-16

### Changed
- Builds clean against the macOS 27 SDK with Xcode 27, with no compiler warnings

### Fixed
- RClick quit instantly and silently whenever it could not open its configuration database. It now reports the cause and exits cleanly instead of trapping. The case seen in the wild is a build that is not properly code-signed, which cannot reach the shared App Group container

## [2.2.1] - 2026-09-13

### Added
- Custom menu layout: arrange top-level and nested items in `custom_menu.json`
- French localization
- Simplified Chinese, Japanese and Spanish names for the built-in new-file types (Word 文档 / Excel 表格 / PowerPoint 演示文稿)
- About: live star count and a link to the issue tracker

### Changed
- Settings: the custom menu is applied only when you press "Apply", so editing the file no longer changes the Finder menu mid-keystroke
- Settings: the About tab is rebuilt around the update status, with the description folded into the identity block
- Settings: launch-at-login now leads the General toggles
- Menu layout switches moved into the shared app group, alongside the other preferences

### Fixed
- Adding or deleting an app could leave the Finder menu unchanged until the next heartbeat
- A failed save was silent; it now surfaces in the settings window
- Checking for updates reported "Failed to Check for Updates" even when the app was simply up to date
- A network failure during an update check was reported as "already up to date"
- The Japanese "Open With" submenu fell back to English
- AirDrop was untranslated in Simplified Chinese
- A one-time migration preserves existing menu layout settings after their move to the app group

### Removed
- 20 localization keys that nothing referenced
- The extension's string catalog no longer carries 131 unused copies of the app's strings

## [2.1.0] - 2026-07-12

### Changed
- Replace Full Disk Access (FDA) with Security-Scoped Bookmark permission model
- File operations (delete, create, hide, unhide, AirDrop) now prompt for per-folder authorization
- Settings: "Full Disk Access" row replaced with "Folder Permissions" management

### Removed
- Full Disk Access detection, guide alert, and settings UI
- `PermissionChecker.hasFullDiskAccess()` and related FDA methods
- Language picker in Settings (language is now fully auto-detected)
- Custom language detection logic (`AppLanguage` enum, `currentLanguage`, `localizedBundle`)

## [2.0.4] - 2026-07-05

### Fixed
- Add sandbox entitlement for FinderSyncExt to fix menu rendering in protected directories
- Set proper icons for collapsed parent menus in FinderSync
- Isolate DMG and ZIP staging into separate subdirectories to prevent artifact corruption
- Prevent nested `.app` in release ZIP caused by stale DMG temp copy

### Changed
- Bump `actions/checkout` from v4 to v5 in CI workflows

## [2.0.3] - 2026-07-04

### Fixed
- Preserve `.app` bundle structure in release ZIP archive
- Use `cp` + `ditto` + `keepParent` for correct `.app` ZIP packaging
- Avoid nested `.app` in release ZIP and DMG artifacts
- Remove stale "Create Blank File" menu item; add missing localization entries

### Added
- CI: GitHub Actions workflows for PR build verification and tag-triggered release

### Changed
- Select latest available Xcode version on CI runner
- Lower `objectVersion` for Xcode 26.0.1 CI compatibility

## [2.0.1] - 2026-06-28

### Added
- Trilingual localization with String Catalogs (zh-Hans, en, ja)
- Editable blank file creation from templates
- Draggable settings menu ordering for customizing menu appearance
- Quick-access folders master toggle (default off)
- CI: Add GitHub Actions workflows for PR build and tag release

### Fixed
- FinderSync menu click unresponsiveness after localization refactor
- Sandbox permission issues for FinderSync Extension
- VS Code detection with percent-encoded path double-encoding
- Toolbar icons disappearing after settings refactor
- Heartbeat monitoring logic for extension health checks
- Menu item default values and collapse toggle not applying correctly
- Chinese menu title truncation in Finder context menu
- Common folders icon not matching system directory appearance
- Dark mode icon adaptation for SF Symbols using `paletteColors`
- File type icon three-level fallback strategy
- `onChange(of:)` deprecation warning on macOS 14+

### Changed
- Swift 5 → Swift 6.2 migration with full concurrency checking
- Settings UI refactored to unified `Form` layout
- macOS 15.6 + Xcode 16.4 compatibility as minimum requirement
- Menu icon loading now uses memory cache for instant display
- New file icons prioritize system app icons when available
- FDA (Full Disk Access) permission guidance and detection

### Performance
- Menu icon loading now uses memory cache for instant display on subsequent right-clicks

## [1.7.2] - 2025-09-27

### Changed
- Code signing and entitlements configuration for FinderSync Extension
- Improved extension loading reliability

## [1.7.0] - 2025-09-27

### Added
- Initial stable release with core Finder context menu features
- Open with External App support
- Copy Path functionality
- Delete Directly (bypass Trash)
- Hide / Unhide file toggle
- AirDrop sharing
- Create New Files from templates
- Quick Access Folders
- Dark Mode support

---

[Unreleased]: https://github.com/anzchy/RClick/compare/v2.3.5...HEAD
[2.3.5]: https://github.com/anzchy/RClick/compare/v2.3.4...v2.3.5
[2.0.4]: https://github.com/wflixu/RClick/releases/tag/v2.0.4
[2.0.3]: https://github.com/wflixu/RClick/releases/tag/v2.0.3
[2.0.1]: https://github.com/wflixu/RClick/releases/tag/v2.0.1
[1.7.2]: https://github.com/wflixu/RClick/releases/tag/v1.7.2
[1.7.0]: https://github.com/wflixu/RClick/releases/tag/v1.7.0
