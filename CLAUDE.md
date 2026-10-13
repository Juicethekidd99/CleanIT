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

## macOS version (`mac/`)
- Swift package (`mac/Package.swift`), built into `mac/build/CleanIT.app` by `mac/build.sh` (ad-hoc signed). Bundle id
  `io.github.juicethekidd99.cleanit`. Targets macOS 12+, Swift 5 language mode, no third-party dependencies.
- The window is a WKWebView showing `mac/web/` (index.html, app.js, mac.css) + the shared `web/app.css` (copied in at build).
  `mac/web/app.js` is a fork of `web/app.js`: same helpers and look; `api()` calls `window.webkit.messageHandlers.api`
  with the same `/api/...` paths. Engine side: `Bridge.swift` (routes + actions table), `Jobs.swift` (background jobs).
- Engine files: `Clean.swift` (categories are data, like `$script:CategoryDefs`), `Disk.swift`, `Startup.swift`,
  `Apps.swift`, `Updates.swift`, `Health.swift` (Security, Health, Dashboard), `Schedule.swift` (weekly LaunchAgent).
- Mac rules: never follow symlinks; user files, apps and leftovers go to the Trash (`trashItem` / `NSWorkspace.recycle`);
  caches are deleted in place but the cache folder itself stays; skip caches of running apps (owner bundle id);
  startup changes only use `launchctl disable/enable` (never edit/delete plists) and are recorded in `State/startup.json`;
  admin actions go through `shAdmin` (macOS password prompt). Paths sent back by the page must come from the engine's
  last results (`Disk.trashable`, `Apps.leftoverPaths`, `Startup.lastItems`).
- Don't trigger permission prompts from the Dashboard/Security (login items via System Events only on the Startup page).
- macOS version numbers jump 15 -> 26: compare positions in `releases` (Health.swift); add each autumn's release.
- Releases: every GitHub release (vX.Y.Z, same tags as Windows) gets two extra files from `tools/release-assets.sh`:
  `CleanIT-Windows.zip` and `CleanIT-Mac.zip` (README links use releases/latest/download/<name>). Never publish a separate
  Mac-only release or a non-numeric tag: the Windows updater reads releases/latest and needs a `vX.Y.Z` tag.
- Testing: `CFFIXED_USER_HOME=<fake home> CLEANIT_DATADIR=<temp> .build/release/CleanIT --clean --categories ...` against
  a fake home containing symlinks to a "precious" folder. UI: launch with `CLEANIT_DEBUG=1` and use
  `swift tools/debug.swift '<js>' out.png` to run JS in the page and save a snapshot. Page errors are logged as ERROR.

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
- Updater: `Install-CleanITUpdate` downloads the latest GitHub release zip (repo is fixed in `$script:UpdateRepo`), verifies
  (AppFiles present, every .ps1 parses, version string matches the tag), backs up to `Backups\app-<ver>`, copies into DataDir,
  refreshes shortcuts/task, then the server starts the new copy which replaces the running one. `CLEANIT_FAKE_VERSION` = test hook.
  Releasing = bump `$script:Version` + README status, commit, push, `gh release create vX.Y.Z --notes-file`.
- Folder ACL: `Protect-DataDir` locks the folder only and `icacls /reset`s children to inherit (never `/T` with (OI)(CI)
  grants - that left files with an empty DACL in v2.0-2.2). session.json stays admin-only.
- Weekly task runs as SYSTEM: `-Clean -Silent -NoRestorePoint -Scheduled`; then starts `CleanIT Notify` (Users group).

## Hard rules
- Must run on stock **Windows PowerShell 5.1** (no `??`, ternary, `-Parallel`, PS7-only cmdlets). C# must be C# 5.
- Keep ALL source files **ASCII-only**, including web files (use \u escapes / HTML entities).
- UI: data from Windows goes into the DOM via textContent only (the `h()` helper) - never innerHTML.
- Never delete through reparse points; never touch event logs; **no registry cleaner**, no RAM/game "boosters".
- Anything destructive: preview first, explicit confirmation in the UI, logged. Files go to the Recycle Bin;
  registry keys are `reg export`ed first.
- Exception: the Free-up-space assistant deletes permanently (so space is really freed), but only plain FILES directly in
  the Downloads folder that its own scan listed - never folders, never through junctions (`Remove-SpaceItems` enforces
  this) - after a confirmation listing every file. Moving Steam games/VMs is explained step by step, never done by CleanIT.
- Plain English everywhere: every finding says what to do and why (Recommended / Optional / Not needed, Important /
  Recommended / Optional / Automatic). Old driver dates alone never mean "outdated".
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
