# CleanIT - project context for Claude Code

## What this is
A personal, transparent replacement for Avast Cleanup Premium / CCleaner for Windows 10/11 (formerly "PC Cleanup" v1).
Local web-app UI + CLI switches, used by the owner on several PCs. Public repo: github.com/Juicethekidd99/CleanIT (MIT).
Commit identity for this repo is the GitHub username + noreply email - never the owner's real name/email.

- `CleanIT.Core.ps1` - engine: every function, the category/privacy/bloat tables, fleet helpers, and an inline C# helper
  (`$script:NativeSource`, compiled lazily by `Initialize-Native`). Dot-sourced by everything, including background jobs.
- `CleanIT.Server.ps1` - local HTTP server (TcpListener on 127.0.0.1, random port), job runner, `$script:Actions` table.
- `CleanIT.ps1` - params, elevation, CLI entry point; with no CLI switches it starts/reuses the server (`Start-CleanITApp`).
- `web/index.html`, `web/app.css`, `web/app.js` - the UI (vanilla JS, no CDN, works offline).
- `CleanIT.vbs` - launcher with no console window (ShellExecute runas, hidden). `Run-CleanIT.bat` just calls it.
Roadmap: `ROADMAP.md`.

## Architecture notes
- Window: Edge `--app=` window with its own profile (`%LOCALAPPDATA%\CleanIT\Window`), started through a temp .lnk
  opened by explorer.exe so it runs as the normal user, not admin. Falls back to the default browser.
- Auth: single-use login token in the start URL (2 min) -> HttpOnly SameSite=Strict cookie. Host header must be
  127.0.0.1:<port>; POSTs need `X-CleanIT: 1`; strict CSP (no inline script/style - set styles via `el.style`, never
  the style attribute). A second launch reads `State\session.json` (admin-only ACL) and calls /api/newlogin.
- Server lifetime: page pings every 1-4 s; server stops 3 min after the last request when no job is running.
- API: `POST /api/run {action,args}` -> job id; page polls `/api/jobs/<id>`. Each action = Prep (main thread, validates
  input, may throw) -> Work (background runspace that dot-sources the core; receives one hashtable `$P`) -> Finalize
  (main thread; caches server-side state). Paths/items sent back by the page must come from the server's own last
  results (`$script:Cache`): startup ids, bloat names, program RegKeys, leftover paths, large/duplicate file paths.
- Logging: `Write-Log`. In a job it enqueues to `$global:CleanITBg.Log`; the server drains it into `$script:LogBuffer`
  (served at /api/log) and the log file.
- Every system query that can hang (Defender, TPM, BitLocker, SMART, event log, WMI) goes through `Invoke-WithTimeout`.
- Junk categories are data: `New-Category` entries in `$script:CategoryDefs`. UI and CLI pick them up automatically.
- `Get-TreeSafe` (PowerShell) and `CleanIT.Disk` (C#) never follow junctions/symlinks/mount points; C# also skips
  online-only cloud placeholders and dedupes hard links in the duplicate finder.
- Startup: StartupApproved registry for Run/Startup folder, `Disable-ScheduledTask`, `sc.exe config start=` for services.
  All recorded in `State\startup.json`.
- Leftover finder is intentionally strict (exact product name or name + setup/data/cache/... suffix; children only inside
  the publisher/first-word folder). Fuzzy matching was tested and produced dangerous false positives.
- Fleet: `Settings.FleetPath`; each run writes `<COMPUTERNAME>.json`. "Add a PC" = `New-FleetSetup` (copy of the app +
  fleet.json with `%OneDrive%` token + "Install CleanIT on this PC.bat" -> `CleanIT.ps1 -JoinFleet fleet.json`).
- Weekly task runs as SYSTEM: `-Clean -Silent -NoRestorePoint -Scheduled`; then starts `CleanIT Notify` (Users group).

## Hard rules
- Must run on stock **Windows PowerShell 5.1** (no `??`, ternary, `-Parallel`, PS7-only cmdlets). C# must be C# 5.
- Keep ALL source files **ASCII-only**, including web files (use \u escapes / HTML entities).
- UI: data from Windows goes into the DOM via textContent only (the `h()` helper) - never innerHTML.
- Never delete through reparse points; never touch event logs; **no registry cleaner**, no RAM/game "boosters".
- Anything destructive: preview first, explicit confirmation in the UI, logged. Files go to the Recycle Bin;
  registry keys are `reg export`ed first.
- Anything that changes system settings must be reversible and record the previous state under `State\`.
- Never `New-Item -Force` on an existing registry key (it wipes it) - test with `Test-Path` first.
- `[math]::Max/Min` with a long and an int literal picks Int32 and overflows - cast both to `[double]`.
- `@($genericList)` on an empty List[object] throws in PS 5.1 - use `.ToArray()`.
- `-and`/`-or` have equal precedence in PowerShell - always parenthesize mixed conditions.
- Keep CLI parity: new features get a switch where it makes sense, and `-Silent` stays non-interactive.

## Testing
- Parse check every .ps1 (`[System.Management.Automation.Language.Parser]::ParseFile`) and ASCII-check every file.
- Engine: dot-source `CleanIT.Core.ps1` with `$env:CLEANIT_DATADIR` pointing at a temp folder; test destructive logic
  against a throwaway folder containing a junction to a "precious" folder and confirm it survives.
- UI without admin: set `CLEANIT_NOELEVATE=1`, `CLEANIT_NOWINDOW=1`, `CLEANIT_STAY=1`, `CLEANIT_DATADIR=<temp>`,
  `CLEANIT_LOGIN_FILE=<file>`, run `CleanIT.ps1`, open the login URL from that file in a browser.
  After editing app.js, do a full reload (not just a hash change).
- Non-admin runs can't see: Get-AppxPackage -AllUsers, SMART counters, TPM, Secure Boot, restore points. Final check
  must be an elevated run via `CleanIT.vbs`.
