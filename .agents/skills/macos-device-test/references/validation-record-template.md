# Device validation: <topic>

<!-- Path: docs/validation/<YYYY-MM-DD>-<topic>.md. Commit on its own with the Validated-by trailer.
     No screenshots, personal paths beyond ~/.rclick-roster/…, or user data in this file: the repo is public. -->

- Run: `<run-id>` (evidence in `~/.rclick-roster/device/<run-id>/`)
- Change under test: <issue/PR on anzchy/RClick>, commit `<8-char sha>` (doctor `bundle-hash` PASS)
- Tester: <role> (not the implementer of the change)
- Machine: <model>, <chip>, <memory>, macOS <version>, <display> @<scale>x
- Build: Debug, Xcode <version>, signing `<team:XXXXXXXXXX | adhoc>`, bundle `<path>`
- Extension: `cn.wflixu.RClick.FinderSyncExt` <version>, enabled by the owner; doctor <13/13 PASS>
- System language: <tag>; app language override: <none | tag>
- App Group state: <created by this run | existing, backed up to settings-before.json and restored>
- GUI lock: acquired <time>, released <time>
- Fixtures: per-run, `fixtures.sha256` in the run folder

## Verdicts

| # | Recipe | Criterion | Entry point | Result |
|---|---|---|---|---|
| 1 | EXT-02 | | | |

## Deviations from a real user

- <synthetic right-click via CGEvent; AX value write into the folder panel; SIGSTOP for CONN-04; …>

## NOT VERIFIED

- <recipe> — <the specific blocker>

## Defects filed

- <#issue — one line>
