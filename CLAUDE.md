# CleanIT - project context for Claude Code

## What this is
A personal, transparent replacement for Avast Cleanup Premium / CCleaner for Windows 10/11 (formerly "PC Cleanup" v1).
WinForms GUI + CLI switches, used by the owner on several personal PCs. v2.0.0.

- `CleanIT.Core.ps1` - engine: every function, the category/privacy/bloat tables, and an inline C# helper
  (`$script:NativeSource`, compiled lazily by `Initialize-Native`). Dot-sourced by the GUI AND by every background job.
- `CleanIT.ps1` - params, elevation, GUI (one `Add-*Tab` function per tab, dot-sourced into `Show-Gui`), CLI entry point.
- `Run-CleanIT.bat` - double-click launcher.
Roadmap: `ROADMAP.md`.

## Architecture notes
- Self-elevates via UAC; GUI runs in a hidden PowerShell window. `-Notify` runs WITHOUT elevation (shows the weekly result).
- Data: `C:\ProgramData\CleanIT` (override with env `CLEANIT_DATADIR` for tests). Logs, settings.json, history.json,
  `State\*.json` (original values: privacy, startup, services, removed apps, last update check), `Backups\*.reg`.
- Logging: `Write-Log`. Inside a background job it enqueues to `$global:CleanITBg.Log`; the GUI timer drains it.
- Background work: `Start-BgJob` (CleanIT.ps1) runs a scriptblock in a new runspace that dot-sources the core.
  One WinForms timer polls all jobs: log lines, `OnTick`, `OnDone($out, $job)`.
  **OnDone/OnTick must only use Show-Gui-level variables, `$S` (shared state hashtable) or `$job.Data`** - handler-local
  variables are gone by the time they run. Assigning to a plain variable inside a handler creates a local; use `$S.x = ...`.
- Junk categories are data: `New-Category` entries in `$script:CategoryDefs` (Group, Paths, MinAgeHours, Before/After,
  Size, CleanBlock, Processes, Warning). GUI and CLI pick them up automatically.
- `Get-TreeSafe` (PowerShell) and `CleanIT.Disk` (C#) never follow junctions/symlinks/mount points; C# also skips
  online-only cloud placeholders and dedupes hard links in the duplicate finder.
- Startup manager: StartupApproved registry (like Task Manager) for Run/Startup folder; `Disable-ScheduledTask` for
  logon/boot tasks; `sc.exe config start=` for services (unticked = Manual). All recorded in `State\startup.json`.
- Leftover finder is intentionally strict (exact product name, or name + setup/data/cache/... suffix, children only
  inside the publisher/first-word folder). Fuzzy matching was tried and produced dangerous false positives.
- Updates: winget table parsing (`ConvertFrom-WingetTable`), Windows Update Agent COM API for software + drivers.
- Weekly task runs as SYSTEM: `-Clean -Silent -NoRestorePoint -Scheduled`; then starts `CleanIT Notify` (Users group)
  so the signed-in user gets a balloon. `Protect-DataDir` locks the folder to Admins/SYSTEM.

## Hard rules
- Must run on stock **Windows PowerShell 5.1** (no `??`, ternary, `-Parallel`, PS7-only cmdlets). C# must be C# 5
  (no `$""`, `?.`, `=>` members, `nameof`).
- Keep source files **ASCII-only** (PS 5.1 misreads BOM-less UTF-8; use '-' not em dashes).
- Never delete through reparse points; never touch event logs; **no registry cleaner**, no RAM/game "boosters".
- Anything destructive: scan/preview first, explicit confirmation in the GUI, logged.
- Anything that changes system settings must be reversible and record the previous state under `State\`.
- Finder tools (large/duplicate files, leftovers) only list results; deleting is a user action per item, to Recycle Bin
  (registry: `reg export` backup first).
- Never `New-Item -Force` on an existing registry key (it wipes it) - test with `Test-Path` first.
- `[math]::Max/Min` with a long and an int literal picks Int32 and overflows - cast both to `[double]`.
- Prefer Windows' own mechanisms (Optimize-Volume, Checkpoint-Computer, Windows Update API, cleanmgr) over custom hacks.
- Keep CLI parity: new features get a switch where it makes sense, and `-Silent` stays non-interactive.

## Testing
- Parse check: `[System.Management.Automation.Language.Parser]::ParseFile(...)` returns no errors; ASCII check (no byte > 127).
- Engine: dot-source `CleanIT.Core.ps1` with `$env:CLEANIT_DATADIR` pointing at a temp folder; test destructive logic
  against a throwaway folder containing a junction to a "precious" folder and confirm it survives.
- GUI without clicking: dot-source `CleanIT.ps1` (it skips elevation and the entry point when dot-sourced) and call
  `Show-Gui -RenderTo <folder> [-RenderHook { ... }]` - every tab is rendered to PNG; the hook can PerformClick buttons.
  (RichTextBox log panel does not render in DrawToBitmap - that's expected.)
- Non-admin runs can't see: Get-AppxPackage -AllUsers, SMART counters, TPM, Secure Boot, restore points. Final check
  must be an elevated run via `Run-CleanIT.bat`.
