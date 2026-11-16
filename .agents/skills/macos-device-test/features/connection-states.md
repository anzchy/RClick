# Connection states and relaunch

The extension keeps a cache of "last message from the app" (30 s timeout) to show a disabled offline menu, and checks
real liveness at click time: each click waits up to 3 s for the app's ack. When the app quits, the extension shows
the offline state at once. Copy Path still works offline; the offline hint relaunches RClick quietly.

## Sub-features

- `CONN-01`: after RClick quits, the menu shows **RClick is not running** and **Restart RClick to restore the menu**
  (grey), and every action except Copy Path is disabled.
- `CONN-02`: offline, Copy Path still copies the paths (done in the extension).
- `CONN-03`: clicking the offline hint relaunches RClick without opening the Settings window; the menu returns.
- `CONN-04`: if the app is alive by the cache but does not ack within 3 s, Finder shows **RClick did not respond**.
- `CONN-05`: choosing an action while the extension knows the app is offline shows **RClick is not running** with the
  "requires RClick to be running" message (when reachable; the offline menu normally disables those items).

## How to get to it (user POV)

Quit RClick from its menu bar item, then right-click in Finder. Click the grey hint. (A hung RClick is not a user path;
`CONN-04` is simulated.)

## Driving it

Preconditions: baseline; doctor PASS.

1. `CONN-04` first, while the app is up: `pause.sh "$RUN_DIR"`; within 30 s of the last heartbeat, right-click
   `alpha.txt` → Copy File Name. Result: after about 3 s an alert **RClick did not respond** (`axdump.sh FinderSyncExt`);
   capture `CONN-04-alert`; OK. `resume.sh "$RUN_DIR"`. Disclose the SIGSTOP. Check `pbpaste` after resume: the
   delayed click may still run once the app resumes; record what happened.
2. Quit RClick through its own UI (menu bar item → Quit), not cleanup. Confirm the recorded PID exited. Then run
   `cleanup.sh "$RUN_DIR"` (reports already exited and retires the record).
3. `CONN-01`: right-click `alpha.txt`. Result: the two grey hint lines; `finder-menu.sh` shows actions other than Copy
   Path disabled. Capture `CONN-01-offline-menu`.
4. `CONN-02`: choose Copy Path. Result: `pbpaste` prints the path; no alert.
5. `CONN-03`: right-click → click **RClick is not running**. Result: a new RClick process from this bundle starts;
   `adopt.sh "$RUN_DIR-relaunch" --from "$RUN_DIR"`; no Settings window opens (`axdump.sh <new pid>` shows no
   Settings window); the app log shows `hintClick=true`. Re-open the menu: the normal items are back (within one
   heartbeat). Then `doctor.sh "$RUN_DIR-relaunch"` and, at the end, `cleanup.sh "$RUN_DIR-relaunch"`.
6. `CONN-05`: only reachable if an enabled non-Copy-Path item can be chosen while offline; otherwise NOT VERIFIED
   (by design the offline menu disables them) and cite the menu readback from step 3.

## Gotchas

- Quit must reach the extension (`.quit` message) for the immediate offline state. If the menu still shows normal items
  right after quit, wait 30 s and note it: that is the cache fallback, a finding to report.
- Never SIGKILL to simulate a crash; the recipe uses SIGSTOP/SIGCONT on the recorded PID only.
- The relaunch belongs to the run (it came from this run's bundle) and must be cleaned up through `adopt.sh`.
