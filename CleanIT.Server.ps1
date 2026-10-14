# CleanIT.Server.ps1 - local web UI backend. Dot-sourced by CleanIT.ps1 after CleanIT.Core.ps1.
#
# Security model (the server runs as administrator, so this matters):
#  - listens on 127.0.0.1 only, on a random free port
#  - the app window is opened with a single-use login token (expires in 2 minutes) which is swapped for an
#    HttpOnly, SameSite=Strict session cookie; every other request needs that cookie
#  - the Host header must be exactly 127.0.0.1:<port> (blocks DNS-rebinding attacks from web pages)
#  - POSTs need the X-CleanIT header (forces a CORS preflight that we never answer -> no cross-site posts)
#  - file/registry paths sent back by the page are only accepted if the server itself produced them in the
#    last scan (large files, duplicates, leftovers), items are referenced by server-side ids
# Slow work runs in background runspaces ("jobs"); the page polls /api/jobs/<id>.

$script:Jobs = @{}
$script:JobSeq = 0
$script:Cache = @{ Startup = @(); Bloat = @{}; Programs = @{}; Leftovers = @{}; Files = @{}; Disk = $null }
$script:RestorePointMade = $false
$script:Protection = $null
$script:ServerQuit = $false
$script:TempLinks = New-Object System.Collections.Generic.List[object]
$script:SessionFile = Join-Path $script:StateDir 'session.json'

function New-Secret {
    $b = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    ([BitConverter]::ToString($b) -replace '-', '').ToLowerInvariant()
}

function New-LoginToken {
    $t = New-Secret
    $script:LoginTokens[$t] = (Get-Date).AddMinutes(2)
    $t
}

# ---------------------------------------------------------------------------
# Background jobs
# ---------------------------------------------------------------------------
function Start-ServerJob {
    param([string]$Name, [scriptblock]$Work, $Params, [scriptblock]$Finalize, $ScanState)
    $sync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Cancel = $false; Progress = -1; Status = ''
    })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('CleanITBg', $sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $boot = 'param($Core, $LogFile, $LogDir, $WorkText, $P)
$ErrorActionPreference = ''SilentlyContinue''
$script:LogDir = $LogDir; $script:LogFile = $LogFile
. $Core
& ([scriptblock]::Create($WorkText)) $P'
    [void]$ps.AddScript($boot).AddArgument($script:CorePath).AddArgument($script:LogFile).AddArgument($script:LogDir).AddArgument($Work.ToString()).AddArgument($Params)
    $script:JobSeq++
    $job = [pscustomobject]@{
        Id = "j$($script:JobSeq)"; Name = $Name; PS = $ps; RS = $rs; Handle = $null; Sync = $sync; Finalize = $Finalize
        ScanState = $ScanState; Status = 'running'; Result = $null; Error = $null; Started = Get-Date; Ended = $null
    }
    $job.Handle = $ps.BeginInvoke()
    $script:Jobs[$job.Id] = $job
    $job
}

function Receive-JobLog {
    param($Job)
    $line = $null
    while ($Job.Sync.Log.TryDequeue([ref]$line)) {
        $p = $line.IndexOf('|')
        Write-LogLine $line.Substring($p + 1) $line.Substring(0, $p)
    }
}

function Update-ServerJobs {
    foreach ($j in @($script:Jobs.Values)) {
        if ($j.Status -ne 'running') {
            if ($j.Ended -and ((Get-Date) - $j.Ended).TotalMinutes -gt 15) { $script:Jobs.Remove($j.Id) }
            continue
        }
        $done = $j.Handle.IsCompleted
        Receive-JobLog $j
        if (-not $done) { continue }
        $out = @()
        try { $out = @($j.PS.EndInvoke($j.Handle)) }
        catch {
            $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
            $hint = Get-AvBlockHint $msg; if ($hint) { $msg = $hint }
            $j.Error = $msg
            Write-Log "$($j.Name) failed: $msg" 'ERROR'
        }
        Receive-JobLog $j
        $j.PS.Dispose(); $j.RS.Dispose()
        if (-not $j.Error) {
            try {
                if ($j.Finalize) { $j.Result = & $j.Finalize $out }
                else { $j.Result = $out | Select-Object -Last 1 }
            }
            catch { $j.Error = $_.Exception.Message; Write-Log "$($j.Name): $($j.Error)" 'ERROR' }
        }
        if ($j.Error) { $j.Status = 'error' } else { $j.Status = 'done' }
        $j.Ended = Get-Date
    }
}

function Get-JobDto {
    param($Job, [switch]$Light)
    $text = [string]$Job.Sync.Status
    if ($Job.ScanState -and $Job.Status -eq 'running') {
        $s = $Job.ScanState
        $text = ('{0} {1:N0} folders, {2:N0} files, {3} - {4}' -f $s.Phase, $s.Dirs, $s.Files, (Format-Size $s.Bytes), $s.Current).Trim()
    }
    $o = [ordered]@{ id = $Job.Id; name = $Job.Name; status = $Job.Status; progress = [int]$Job.Sync.Progress; statusText = $text; error = $Job.Error }
    if (-not $Light -and $Job.Status -eq 'done') { $o.result = $Job.Result }
    [pscustomobject]$o
}

# ---------------------------------------------------------------------------
# Helpers used by actions
# ---------------------------------------------------------------------------
function Use-RestorePoint {
    param($A)
    if ($A -and $A.restorePoint -and (Get-Settings).RestorePoint -and -not $script:RestorePointMade) {
        $script:RestorePointMade = $true
        return $true
    }
    $false
}

function Get-CategoryKeys {
    param($Keys)
    $valid = @($script:CategoryDefs | ForEach-Object { $_.Key })
    @($Keys | Where-Object { $valid -contains [string]$_ } | ForEach-Object { [string]$_ })
}

function Open-ForUser {
    # explorer.exe hands the request to the already-running (non-admin) shell, so things open as the user.
    param([string]$Target, [switch]$Select)
    if ($Select) { Start-Process explorer.exe "/select,`"$Target`"" } else { Start-Process explorer.exe "`"$Target`"" }
}

function Open-AppWindow {
    param([string]$Url)
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $edge) { Start-Process explorer.exe $Url; return }
    $profileDir = Join-Path $env:LOCALAPPDATA 'CleanIT\Window'
    $lnkPath = Join-Path $env:TEMP ('CleanIT-open-{0}.lnk' -f (Get-Random))
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($lnkPath)
    $lnk.TargetPath = $edge
    $lnk.Arguments = "--app=`"$Url`" --user-data-dir=`"$profileDir`" --window-size=1340,880 --no-first-run --no-default-browser-check"
    $lnk.Save()
    # Starting Edge through explorer runs it as the normal user, not as administrator.
    Start-Process explorer.exe "`"$lnkPath`""
    $script:TempLinks.Add([pscustomobject]@{ Path = $lnkPath; At = Get-Date })
    $script:TagUntil = (Get-Date).AddSeconds(40)   # give the new window CleanIT's taskbar identity once it appears
}

# Edge app windows inherit Edge's taskbar identity (so pinning showed the Edge logo). Stamp ours on them.
function Set-WindowIdentity {
    if (-not $script:TagUntil -or (Get-Date) -gt $script:TagUntil) { return }
    if ($script:LastTag -and ((Get-Date) - $script:LastTag).TotalMilliseconds -lt 900) { return }
    $script:LastTag = Get-Date
    try {
        $pids = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*CleanIT\Window*' } | ForEach-Object { [int]$_.ProcessId })
        if (-not $pids.Count) { return }
        $vbs = Join-Path $script:DataDir 'CleanIT.vbs'
        if (-not (Test-Path -LiteralPath $vbs)) { $vbs = Join-Path $script:AppDir 'CleanIT.vbs' }
        $relaunch = "`"$env:SystemRoot\System32\wscript.exe`" `"$vbs`""
        $n = [CleanIT.Taskbar]::TagWindows('CleanIT', [int[]]$pids, $script:AppUserModelId, $relaunch, "$($script:IconFile),0", 'CleanIT')
        if ($n -gt 0) { $script:TagUntil = (Get-Date).AddSeconds(3) }   # keep watching briefly for extra windows
    }
    catch { $script:TagUntil = $null; Write-Log "Taskbar identity not set: $($_.Exception.Message)" 'WARN' }
}

function Remove-TempLinks {
    foreach ($t in $script:TempLinks.ToArray()) {
        if (((Get-Date) - $t.At).TotalSeconds -gt 20) { Remove-Item -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue; [void]$script:TempLinks.Remove($t) }
    }
}

function Get-DiskNodeDto {
    param($Node)
    $kids = @($Node.Children | Sort-Object Size -Descending | Select-Object -First 400 | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; path = $_.FullPath; size = [double]$_.Size; files = [double]$_.Files; denied = $_.Denied; hasChildren = ($_.Children.Count -gt 0) }
    })
    $parent = $null; if ($Node.Parent) { $parent = $Node.Parent.FullPath }
    $root = $script:Cache.Disk
    [pscustomobject]@{
        path = $Node.FullPath; name = $Node.Name; size = [double]$Node.Size; files = [double]$Node.Files; ownBytes = [double]$Node.OwnBytes
        ownFiles = [double]$Node.OwnFiles; parent = $parent; root = $root.FullPath; children = $kids; more = [math]::Max(0, $Node.Children.Count - 400)
    }
}

function Find-DiskNode {
    param([string]$Path)
    $n = $script:Cache.Disk
    if (-not $n) { return $null }
    $p = $Path.TrimEnd('\')
    while ($n) {
        if ($n.FullPath.TrimEnd('\') -eq $p) { return $n }
        $next = $null
        foreach ($c in $n.Children) {
            if ($p.StartsWith($c.FullPath + '\', [StringComparison]::OrdinalIgnoreCase) -or $p -eq $c.FullPath) { $next = $c; break }
        }
        $n = $next
    }
    $null
}

function Test-SafeId { param([string]$Value, [string]$Pattern) [bool]($Value -and $Value -match $Pattern) }

# ---------------------------------------------------------------------------
# Actions: Prep (main thread: validate input, build params) -> Work (background) -> Finalize (main thread)
# ---------------------------------------------------------------------------
$script:Actions = @{
    dashboard = @{ Name = 'Checking PC health'; Work = { param($P) Get-DashboardData } }

    smartScan = @{ Name = 'Smart Scan'; Work = {
        param($P)
        Write-Log 'Smart Scan started.'
        $keys = @($script:CategoryDefs | Where-Object { $_.Default } | ForEach-Object { $_.Key })
        $scan = @(Invoke-JunkScan $keys)
        Set-BgProgress 70 'Checking app updates'
        if (Test-Winget) { [void]@(Get-WingetUpgrades) }
        Set-BgProgress 78 'Checking drivers'
        [void](Get-DriverReport -Quick)
        Set-BgProgress 85 'Checking health and security'
        $dash = Get-DashboardData
        $junk = 0; foreach ($x in $scan) { if ($x.Size -gt 0) { $junk += $x.Size } }
        Write-Log ('Smart Scan done: {0} of junk, score {1}/100, {2} item(s) to look at.' -f (Format-Size $junk), $dash.Score, @($dash.Issues).Count) 'OK'
        [pscustomobject]@{ scan = $scan; dash = $dash; junk = [double]$junk }
    } }

    junkScan = @{ Name = 'Scanning junk'
        Prep = { param($A) @{ Keys = (Get-CategoryKeys $A.keys) } }
        Work = { param($P) Write-Log 'Scanning...'; $r = @(Invoke-JunkScan $P.Keys); Write-Log 'Scan complete.' 'OK'; [pscustomobject]@{ items = $r } } }

    clean = @{ Name = 'Cleaning'
        Prep = {
            param($A)
            $k = Get-CategoryKeys $A.keys
            if (-not $k.Count) { throw 'Pick at least one category.' }
            @{ Keys = $k; Rp = (Use-RestorePoint $A) }
        }
        Work = { param($P) $r = Invoke-CleanRun -Keys $P.Keys -Source 'Manual' -RestorePoint:$P.Rp; Write-FleetReport; $r } }

    startupList = @{ Name = 'Loading startup items'
        Prep = { param($A) @{ Ms = [bool]$A.includeMicrosoft } }
        Work = { param($P) [pscustomobject]@{ items = @(Get-StartupItems -IncludeMicrosoft:$P.Ms) } }
        Finalize = {
            param($Out)
            $items = @(($Out | Select-Object -Last 1).items)
            $i = 0
            foreach ($x in $items) { $x | Add-Member -NotePropertyName id -NotePropertyValue "s$i" -Force; $i++ }
            $script:Cache.Startup = $items
            [pscustomobject]@{ items = $items }
        } }

    startupApply = @{ Name = 'Applying startup changes'
        Prep = {
            param($A)
            $changes = @(foreach ($c in @($A.changes)) {
                $item = $script:Cache.Startup | Where-Object { $_.id -eq [string]$c.id } | Select-Object -First 1
                if ($item) { [pscustomobject]@{ Item = $item; Enable = [bool]$c.enable } }
            })
            if (-not $changes.Count) { throw 'Nothing to change - refresh the list and try again.' }
            $rp = $false
            if (@($changes | Where-Object { $_.Item.Kind -eq 'Service' }).Count) { $rp = Use-RestorePoint $A }
            @{ Changes = $changes; Rp = $rp }
        }
        Work = {
            param($P)
            if ($P.Rp) { [void](New-CleanITRestorePoint 'Before startup/service changes') }
            foreach ($c in $P.Changes) {
                $verb = 'disabled'; if ($c.Enable) { $verb = 'enabled' }
                try { Set-StartupItemState $c.Item $c.Enable; Write-Log "Startup: $($c.Item.Name) $verb" 'OK' }
                catch { Write-Log "Startup: $($c.Item.Name) - $($_.Exception.Message)" 'ERROR' }
            }
        } }

    startupUndo = @{ Name = 'Undoing startup changes'; Work = { param($P) Undo-AllStartupChanges } }

    bloatList = @{ Name = 'Listing Store apps'
        Work = { param($P) [pscustomobject]@{ items = @(Get-AppxInventory) } }
        Finalize = {
            param($Out)
            $items = @(($Out | Select-Object -Last 1).items | Where-Object { $_.Name })
            $script:Cache.Bloat = @{}
            foreach ($a in $items) { $script:Cache.Bloat[$a.Name] = $a }
            [pscustomobject]@{ items = @($items | ForEach-Object {
                [pscustomobject]@{ name = $_.Name; label = $_.Label; publisher = $_.Publisher; installed = $_.Installed
                                   provisioned = [bool]$_.Provisioned; recommended = $_.Recommended; known = $_.Known } }) }
        } }

    bloatRemove = @{ Name = 'Removing apps'
        Prep = {
            param($A)
            $apps = @(foreach ($n in @($A.names)) { if ($script:Cache.Bloat.ContainsKey([string]$n)) { $script:Cache.Bloat[[string]$n] } })
            if (-not $apps.Count) { throw 'Tick the apps to remove first.' }
            @{ Apps = $apps; Deprov = [bool]$A.deprovision; Rp = (Use-RestorePoint $A) }
        }
        Work = {
            param($P)
            if ($P.Rp) { [void](New-CleanITRestorePoint 'Before removing apps') }
            $i = 0
            foreach ($a in $P.Apps) {
                Set-BgProgress ([int](100 * $i / $P.Apps.Count)) "Removing $($a.Label)"
                Write-Log "Removing $($a.Label) ($($a.Name))..."
                [void](Remove-BloatApp $a -Deprovision:$P.Deprov)
                $i++
            }
            Write-Log "App removal finished ($($P.Apps.Count) app(s))." 'OK'
        } }

    removedApps = @{ Name = 'Loading removed apps'; Work = { param($P) [pscustomobject]@{ items = @(Get-RemovedApps) } } }

    programsList = @{ Name = 'Listing programs'
        Work = { param($P) [pscustomobject]@{ items = @(Get-InstalledPrograms) } }
        Finalize = {
            param($Out)
            $items = @(($Out | Select-Object -Last 1).items | Where-Object { $_.Name })
            $script:Cache.Programs = @{}
            foreach ($p in $items) { $script:Cache.Programs[$p.RegKey] = $p }
            [pscustomobject]@{ items = @($items | ForEach-Object {
                $d = $null; if ($_.InstallDate) { $d = $_.InstallDate.ToString('yyyy-MM-dd') }
                [pscustomobject]@{ id = $_.RegKey; name = $_.Name; publisher = $_.Publisher; version = $_.Version; size = $_.SizeBytes
                                   date = $d; scope = $_.Scope; location = $_.InstallLocation } }) }
        } }

    uninstall = @{ Name = 'Uninstalling'
        Prep = {
            param($A)
            $p = $script:Cache.Programs[[string]$A.id]
            if (-not $p) { throw 'Program not found - refresh the list.' }
            @{ Program = $p; All = @($script:Cache.Programs.Values); Rp = (Use-RestorePoint $A) }
        }
        Work = {
            param($P)
            if ($P.Rp) { [void](New-CleanITRestorePoint 'Before uninstall') }
            $prog = $P.Program
            $proc = Start-ProgramUninstall $prog
            Set-BgProgress -1 "Waiting for the $($prog.Name) uninstaller - finish it in its own window"
            while ($proc -and -not $proc.HasExited) { Start-Sleep 1; if (Test-BgCancel) { break } }
            # Many uninstallers hand off to a copy of themselves (Au_.exe, Un_A.exe...) - wait for those too.
            $key = "Registry::$($prog.RegKey)"
            $deadline = (Get-Date).AddMinutes(20)
            $quiet = 0
            while ((Test-Path -LiteralPath $key) -and (Get-Date) -lt $deadline -and -not (Test-BgCancel)) {
                $busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { ($_.ProcessName -match '^(Au_|Un_A|un_a|uninst|unins\d*|Uninstall|msiexec|_iu14D2N|setup)$') -or (($_.ProcessName -like 'Un*') -and ($_.ProcessName.Length -le 6)) }).Count
                if ($busy) { $quiet = 0 } else { $quiet++ }
                if ($quiet -ge 5) { break }
                Start-Sleep 2
            }
            $gone = -not (Test-Path -LiteralPath $key)
            $hits = @()
            if ($gone) {
                Write-Log "$($prog.Name) was uninstalled. Looking for leftovers..." 'OK'
                $hits = @(Find-ProgramLeftovers $prog $P.All)
                Write-Log "$($hits.Count) possible leftover(s) found." 'OK'
            }
            else { Write-Log "$($prog.Name) still looks installed. If its uninstaller is open, finish it, then click 'Find leftovers'." 'WARN' }
            [pscustomobject]@{ gone = $gone; name = $prog.Name; hits = $hits }
        }
        Finalize = {
            param($Out)
            $r = $Out | Select-Object -Last 1
            $script:Cache.Leftovers = @{}
            foreach ($h in @($r.hits)) { $script:Cache.Leftovers[$h.Path] = $h }
            $r
        } }

    leftovers = @{ Name = 'Looking for leftovers'
        Prep = {
            param($A)
            $p = $script:Cache.Programs[[string]$A.id]
            if (-not $p) { throw 'Program not found - refresh the list.' }
            @{ Program = $p; All = @($script:Cache.Programs.Values) }
        }
        Work = { param($P) [pscustomobject]@{ name = $P.Program.Name; hits = @(Find-ProgramLeftovers $P.Program $P.All) } }
        Finalize = {
            param($Out)
            $r = $Out | Select-Object -Last 1
            $script:Cache.Leftovers = @{}
            foreach ($h in @($r.hits)) { $script:Cache.Leftovers[$h.Path] = $h }
            $r
        } }

    leftoversRemove = @{ Name = 'Removing leftovers'
        Prep = {
            param($A)
            $hits = @(foreach ($p in @($A.paths)) { if ($script:Cache.Leftovers.ContainsKey([string]$p)) { $script:Cache.Leftovers[[string]$p] } })
            if (-not $hits.Count) { throw 'Nothing selected.' }
            @{ Hits = $hits }
        }
        Work = {
            param($P)
            $done = @()
            foreach ($h in $P.Hits) {
                try { Remove-Leftover $h; $done += $h.Path } catch { Write-Log "Not removed ($($h.Path)): $($_.Exception.Message)" 'WARN' }
            }
            [pscustomobject]@{ removed = $done }
        } }

    wingetList = @{ Name = 'Checking app updates'
        Work = { param($P) if (-not (Test-Winget)) { throw "winget isn't available - install 'App Installer' from the Microsoft Store." }; [pscustomobject]@{ items = @(Get-WingetUpgrades) } } }

    wingetUpdate = @{ Name = 'Updating apps'
        Prep = {
            param($A)
            $ids = @($A.ids | Where-Object { Test-SafeId $_ '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,120}$' })
            if (-not $ids.Count) { throw 'Tick the apps to update first.' }
            @{ Ids = $ids }
        }
        Work = { param($P) Invoke-WingetUpgrade $P.Ids } }

    wuList = @{ Name = 'Checking Windows Update'
        Prep = { param($A) $t = 'Software'; if ($A.type -eq 'Driver') { $t = 'Driver' }; @{ Type = $t } }
        Work = { param($P) [pscustomobject]@{ items = @(Get-WindowsUpdateList -Type $P.Type) } } }

    wuInstall = @{ Name = 'Installing updates'
        Prep = {
            param($A)
            $t = 'Software'; if ($A.type -eq 'Driver') { $t = 'Driver' }
            $ids = @($A.ids | Where-Object { Test-SafeId $_ '^[0-9a-fA-F\-]{36}$' })
            if (-not $ids.Count) { throw 'Tick the updates to install first.' }
            @{ Type = $t; Ids = $ids }
        }
        Work = { param($P) Install-WindowsUpdates -Ids $P.Ids -Type $P.Type } }

    privacyList = @{ Name = 'Reading privacy settings'
        Work = {
            param($P)
            [pscustomobject]@{ items = @(Get-PrivacyStatus | ForEach-Object {
                [pscustomobject]@{ key = $_.Item.Key; name = $_.Item.Name; group = $_.Item.Group; description = $_.Item.Description
                                   recommended = $_.Item.Recommended; protected = $_.Protected; changed = $_.ChangedByCleanIT } }) }
        } }

    privacyApply = @{ Name = 'Applying privacy settings'
        Prep = {
            param($A)
            $valid = @($script:PrivacyItems | ForEach-Object { $_.Key })
            $changes = @(foreach ($c in @($A.changes)) { if ($valid -contains [string]$c.key) { [pscustomobject]@{ Key = [string]$c.key; Protect = [bool]$c.protect } } })
            if (-not $changes.Count) { throw 'Nothing to change.' }
            @{ Changes = $changes; Rp = (Use-RestorePoint $A) }
        }
        Work = {
            param($P)
            if ($P.Rp) { [void](New-CleanITRestorePoint 'Before privacy changes') }
            foreach ($c in $P.Changes) {
                $item = $script:PrivacyItems | Where-Object { $_.Key -eq $c.Key } | Select-Object -First 1
                try { Set-PrivacyItem $item $c.Protect } catch { Write-Log "Privacy: $($item.Name) - $($_.Exception.Message)" 'ERROR' }
            }
        } }

    privacyRestore = @{ Name = 'Restoring privacy settings'; Work = { param($P) Restore-AllPrivacy } }

    restartExplorer = @{ Name = 'Restarting Explorer'; Work = { param($P) Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force; Write-Log 'Explorer restarted.' 'OK' } }

    security = @{ Name = 'Security check'; Work = { param($P) [pscustomobject]@{ items = @(Get-SecurityChecks) } } }

    securityFix = @{ Name = 'Security fix'
        Prep = { param($A) $f = [string]$A.fix; if ($f -notin @('QuickScan', 'UpdateSignatures', 'EnableFirewall')) { throw 'Unknown fix.' }; @{ Fix = $f } }
        Work = {
            param($P)
            switch ($P.Fix) {
                'QuickScan' { Invoke-DefenderQuickScan }
                'UpdateSignatures' { Update-DefenderSignatures }
                'EnableFirewall' { Set-NetFirewallProfile -All -Enabled True; Write-Log 'Firewall turned on for all profiles.' 'OK' }
            }
        } }

    protectStatus = @{ Name = 'Checking protection'; Work = { param($P) Get-ProtectStatus } }

    protectSet = @{ Name = 'Changing Defender protection'
        Prep = {
            param($A)
            $valid = @($script:ProtectSettings | ForEach-Object { $_.Key })
            $changes = @(foreach ($c in @($A.changes)) { if ($valid -contains [string]$c.key) { [pscustomobject]@{ Key = [string]$c.key; On = [bool]$c.on } } })
            if (-not $changes.Count) { throw 'Nothing to change.' }
            @{ Changes = $changes; Rp = (Use-RestorePoint $A) }
        }
        Work = {
            param($P)
            if ($P.Rp) { [void](New-CleanITRestorePoint 'Before Defender changes') }
            foreach ($c in $P.Changes) { try { Set-ProtectSetting $c.Key $c.On } catch { Write-Log "Protect: $($c.Key) - $($_.Exception.Message)" 'ERROR' } }
            Get-ProtectStatus
        } }

    protectRestore = @{ Name = 'Restoring Defender settings'; Work = { param($P) Restore-ProtectSettings; Get-ProtectStatus } }

    defScan = @{ Name = 'Microsoft Defender scan'
        Prep = {
            param($A)
            $type = [string]$A.type
            if ($type -notin @('Quick', 'Full', 'Custom', 'Downloads')) { throw 'Unknown scan type.' }
            $path = $null
            if ($type -eq 'Downloads') { $type = 'Custom'; $path = Get-DownloadsFolder }
            elseif ($type -eq 'Custom') { $path = [string]$A.path; if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw "Folder not found: $path" } }
            @{ Type = $type; Path = $path }
        }
        Work = { param($P) Update-DefenderSignatures; Invoke-DefenderScan -Type $P.Type -Path $P.Path } }

    offlineScan = @{ Name = 'Starting offline scan'; Work = { param($P) Start-OfflineScan } }

    threats = @{ Name = 'Reading threat history'
        Work = { param($P) [pscustomobject]@{ items = @(Get-ThreatHistory | Sort-Object Detected -Descending) } }
        Finalize = {
            param($Out)
            $r = $Out | Select-Object -Last 1
            $script:Cache.Quarantine = @{}
            foreach ($x in @($r.items)) { if ($x.Quarantined) { $script:Cache.Quarantine[$x.Name] = $true } }
            $r
        } }

    threatsRemove = @{ Name = 'Removing threats'; Work = { param($P) Remove-ActiveThreats } }

    threatRestore = @{ Name = 'Restoring from quarantine'
        Prep = { param($A) $n = [string]$A.name; if (-not ($script:Cache.Quarantine -and $script:Cache.Quarantine.ContainsKey($n))) { throw 'Not in quarantine - refresh the list.' }; @{ Name = $n } }
        Work = { param($P) Restore-QuarantinedThreat $P.Name } }

    protectSchedule = @{ Name = 'Saving scan schedule'
        Prep = { param($A) @{ Weekly = [bool]$A.weeklyQuick; Monthly = [bool]$A.monthlyFull; AppDir = $script:AppDir } }
        Work = { param($P) Set-ProtectSchedule -WeeklyQuick $P.Weekly -MonthlyFull $P.Monthly -SourceDir $P.AppDir; Get-ProtectSchedule } }

    sandboxStatus = @{ Name = 'Checking Windows Sandbox'; Work = { param($P) Get-SandboxStatus } }
    sandboxEnable = @{ Name = 'Turning on Windows Sandbox'; Work = { param($P) [pscustomobject]@{ restart = (Enable-Sandbox) } } }
    sandboxOpen = @{ Name = 'Opening Windows Sandbox'
        Work = { param($P) New-SandboxConfig }
        Finalize = { param($Out) $w = [string]($Out | Select-Object -Last 1); if ($w) { Open-ForUser $w }; $true } }

    networkCheck = @{ Name = 'Checking your network'; Work = { param($P) Get-NetworkCheck } }

    perfStatus = @{ Name = 'Checking performance settings'
        Work = { param($P) [pscustomobject]@{ items = @(Get-PerfStatus); checks = @(Get-PerformanceChecks) } } }
    perfApply = @{ Name = 'Changing performance settings'
        Prep = {
            param($A)
            $valid = @($script:PerfItems | ForEach-Object { $_.Key })
            $changes = @(foreach ($c in @($A.changes)) { if ($valid -contains [string]$c.key) { [pscustomobject]@{ Key = [string]$c.key; On = [bool]$c.on } } })
            if (-not $changes.Count) { throw 'Nothing to change.' }
            @{ Changes = $changes; Rp = (Use-RestorePoint $A) }
        }
        Work = {
            param($P)
            if ($P.Rp) { [void](New-CleanITRestorePoint 'Before performance changes') }
            foreach ($c in $P.Changes) {
                $item = $script:PerfItems | Where-Object { $_.Key -eq $c.Key } | Select-Object -First 1
                try { Set-PerfItem $item $c.On } catch { Write-Log "Performance: $($item.Name) - $($_.Exception.Message)" 'ERROR' }
            }
            [pscustomobject]@{ items = @(Get-PerfStatus) }
        } }
    perfRestore = @{ Name = 'Putting performance settings back'; Work = { param($P) Restore-AllPerf; [pscustomobject]@{ items = @(Get-PerfStatus) } } }

    health = @{ Name = 'Health report'; Work = { param($P) [pscustomobject]@{ text = (Get-HealthReport) } } }
    shutdowns = @{ Name = 'Reading shutdown history'; Work = { param($P) Get-ShutdownHistory } }
    optimize = @{ Name = 'Optimizing drives'; Work = { param($P) Invoke-DriveOptimize } }
    repair = @{ Name = 'Repairing Windows'; Work = { param($P) Invoke-WindowsRepair } }
    flushDns = @{ Name = 'Flushing DNS'; Work = { param($P) & ipconfig.exe /flushdns 2>&1 | Out-Null; Write-Log 'DNS cache flushed. If websites still fail, restart the router or use Settings > Network reset.' 'OK' } }
    batteryReport = @{ Name = 'Battery report'
        Work = { param($P) $o = Join-Path $script:DataDir 'battery-report.html'; & powercfg.exe /batteryreport /output $o 2>&1 | Out-Null; $o }
        Finalize = { param($Out) $f = $Out | Select-Object -Last 1; if ($f -and (Test-Path -LiteralPath $f)) { Open-ForUser $f }; $f } }

    drivers = @{ Name = 'Checking drivers'
        Work = { param($P) Get-DriverReport }
        Finalize = {
            param($Out)
            $r = $Out | Select-Object -Last 1
            $script:Cache.DriverPkgs = @{}
            foreach ($p in @($r.Packages | Where-Object { $_.Removable })) { $script:Cache.DriverPkgs[$p.Published] = $p }
            $r
        } }

    driverHide = @{ Name = 'Saving'
        Prep = {
            param($A)
            $k = [string]$A.key
            if ($k -notmatch '^(drv|chipset|gpu|bios)\|.{1,200}$') { throw 'Invalid item.' }
            @{ Key = $k; Hide = [bool]$A.hide }
        }
        Work = { param($P) Set-DriverHidden $P.Key $P.Hide } }

    driverPackagesRemove = @{ Name = 'Removing old driver packages'
        Prep = {
            param($A)
            $names = @($A.names | Where-Object { $script:Cache.DriverPkgs -and $script:Cache.DriverPkgs.ContainsKey([string]$_) } | ForEach-Object { [string]$_ })
            if (-not $names.Count) { throw 'Nothing selected - run the driver check again.' }
            @{ Names = $names; Rp = (Use-RestorePoint $A) }
        }
        Work = {
            param($P)
            if ($P.Rp) { [void](New-CleanITRestorePoint 'Before removing old driver packages') }
            $done = @()
            foreach ($n in $P.Names) {
                try { Remove-DriverPackage $n; $done += $n } catch { Write-Log "Driver package $n kept: $($_.Exception.Message)" 'WARN' }
            }
            [pscustomobject]@{ removed = $done }
        } }

    updateCheck = @{ Name = 'Checking for CleanIT updates'
        Prep = { param($A) @{ Force = [bool]$A.force } }
        Work = { param($P) Get-UpdateInfo -Force:$P.Force } }

    updateInstall = @{ Name = 'Updating CleanIT'
        Work = { param($P) Install-CleanITUpdate }
        Finalize = {
            param($Out)
            $res = $Out | Select-Object -Last 1
            if (-not $res -or -not $res.Path) { return [pscustomobject]@{ updated = $false } }
            $path = [string]$res.Path
            # Start the new version a few seconds from now; it replaces this (older) running copy and opens a new window.
            $cmd = "Start-Sleep -Seconds 4; & '" + $path.Replace("'", "''") + "'"
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
            [pscustomobject]@{ updated = $true; version = [string]$res.Version }
        } }

    restorePointNow = @{ Name = 'Creating restore point'; Work = { param($P) [void](New-CleanITRestorePoint 'Manual restore point') } }
    enableProtection = @{ Name = 'Turning on System Protection'
        Work = { param($P) Enable-SystemProtection }
        Finalize = { param($Out) $script:Protection = $true; $true } }

    diskScan = @{ Name = 'Analyzing disk space'; Scan = $true
        Prep = { param($A) $p = [string]$A.path; if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { throw "Folder not found: $p" }; @{ Path = $p } }
        Work = { param($P) Initialize-Native; [CleanIT.Disk]::ScanTree($P.Path, $P.State) }
        Finalize = {
            param($Out)
            $root = $Out | Select-Object -Last 1
            $script:Cache.Disk = $root
            Write-Log ('Analyzed {0}: {1} in {2:N0} files.' -f $root.FullPath, (Format-Size $root.Size), $root.Files) 'OK'
            Get-DiskNodeDto $root
        } }

    spaceScan = @{ Name = 'Looking for space to free'
        Work = { param($P) Get-SpaceReport }
        Finalize = {
            param($Out)
            $r = $Out | Select-Object -Last 1
            $script:Cache.SpaceFiles = @{}
            foreach ($i in @($r.Safe) + @($r.Review)) { if ($i) { $script:Cache.SpaceFiles[$i.Path] = $true } }
            $r
        } }

    spaceDelete = @{ Name = 'Deleting files'
        Prep = {
            param($A)
            $paths = @($A.paths | Where-Object { $script:Cache.SpaceFiles -and $script:Cache.SpaceFiles.ContainsKey([string]$_) } | ForEach-Object { [string]$_ })
            if (-not $paths.Count) { throw 'Nothing selected - scan again.' }
            @{ Paths = $paths }
        }
        Work = { param($P) Remove-SpaceItems $P.Paths } }

    emptyBin = @{ Name = 'Emptying the Recycle Bin'
        Prep = { param($A) $d = [string]$A.drive; if ($d -notmatch '^[A-Za-z]:?$') { throw 'Invalid drive.' }; @{ Drive = $d } }
        Work = { param($P) Clear-DriveRecycleBin $P.Drive } }

    largeFiles = @{ Name = 'Finding large files'; Scan = $true
        Prep = {
            param($A)
            $p = [string]$A.path; if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { throw "Folder not found: $p" }
            @{ Path = $p; Min = [int]$A.minMB; Days = [int]$A.days; Sys = [bool]$A.includeSystem }
        }
        Work = { param($P) [pscustomobject]@{ items = @(Find-LargeFiles -Path $P.Path -MinSizeMB $P.Min -UnusedDays $P.Days -IncludeSystem:$P.Sys -State $P.State) } }
        Finalize = {
            param($Out)
            $items = @(($Out | Select-Object -Last 1).items | Where-Object { $_.Path })
            $script:Cache.Files = @{}
            foreach ($f in $items) { $script:Cache.Files[$f.Path] = $true }
            [pscustomobject]@{ items = @($items | ForEach-Object {
                $last = $_.LastWrite; if ($_.LastAccess -gt $last) { $last = $_.LastAccess }
                [pscustomobject]@{ path = $_.Path; size = [double]$_.Size; lastUsed = $last.ToString('yyyy-MM-dd') } }) }
        } }

    duplicates = @{ Name = 'Finding duplicates'; Scan = $true
        Prep = {
            param($A)
            $p = [string]$A.path; if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { throw "Folder not found: $p" }
            @{ Path = $p; Min = [int]$A.minMB; Sys = [bool]$A.includeSystem }
        }
        Work = { param($P) [pscustomobject]@{ items = @(Find-DuplicateFiles -Path $P.Path -MinSizeMB $P.Min -IncludeSystem:$P.Sys -State $P.State) } }
        Finalize = {
            param($Out)
            $items = @(($Out | Select-Object -Last 1).items | Where-Object { $_.Path })
            $script:Cache.Files = @{}
            foreach ($f in $items) { $script:Cache.Files[$f.Path] = $true }
            [pscustomobject]@{ items = @($items | ForEach-Object {
                [pscustomobject]@{ group = $_.Group; path = $_.Path; size = [double]$_.Size; modified = $_.LastWrite.ToString('yyyy-MM-dd') } }) }
        } }

    recycle = @{ Name = 'Moving files to the Recycle Bin'
        Prep = {
            param($A)
            $paths = @($A.paths | Where-Object { $script:Cache.Files.ContainsKey([string]$_) } | ForEach-Object { [string]$_ })
            if (-not $paths.Count) { throw 'Nothing selected.' }
            @{ Paths = $paths }
        }
        Work = {
            param($P)
            $done = @()
            foreach ($f in $P.Paths) {
                try { Send-ToRecycleBin $f; $done += $f; Write-Log "Recycled: $f" 'OK' } catch { Write-Log "Could not recycle ${f}: $($_.Exception.Message)" 'WARN' }
            }
            [pscustomobject]@{ removed = $done }
        } }

    scheduleSave = @{ Name = 'Saving schedule'
        Prep = {
            param($A)
            $t = [string]$A.time
            try { [void][datetime]::ParseExact($t, 'HH:mm', $null) } catch { throw 'Time must look like 03:00 or 21:30.' }
            $d = [string]$A.day
            if ([Enum]::GetNames([DayOfWeek]) -notcontains $d) { throw 'Pick a day.' }
            $s = Get-Settings; $s.ScheduleDay = $d; $s.ScheduleTime = $t; $s.ScheduleUpdates = [bool]$A.updates; Save-Settings $s
            @{ Enabled = [bool]$A.enabled; AppDir = $script:AppDir }
        }
        Work = { param($P) if ($P.Enabled) { Install-Schedule $P.AppDir } else { Remove-Schedule } } }

    fleetList = @{ Name = 'Reading fleet reports'; Work = { param($P) [pscustomobject]@{ items = @(Get-FleetReports) } } }
    fleetOneDrive = @{ Name = 'Setting up the OneDrive fleet'; Work = { param($P) Use-OneDriveFleet } }
    fleetSetPath = @{ Name = 'Setting fleet folder'
        Prep = { param($A) @{ Path = ([string]$A.path).Trim() } }
        Work = { param($P) Set-FleetPath $P.Path } }
    fleetWrite = @{ Name = 'Writing fleet report'; Work = { param($P) Write-FleetReport } }
    fleetSetup = @{ Name = 'Creating "Add a PC" setup'
        Prep = { param($A) $dest = $null; if ($A.target -eq 'desktop') { $dest = [Environment]::GetFolderPath('Desktop') }; @{ Dest = $dest; AppDir = $script:AppDir } }
        Work = { param($P) New-FleetSetup -SourceDir $P.AppDir -Destination $P.Dest }
        Finalize = { param($Out) $d = $Out | Select-Object -Last 1; if ($d) { Open-ForUser $d }; $d } }
    fleetRemove = @{ Name = 'Removing PC from fleet view'
        Prep = { param($A) @{ Computer = [string]$A.computer } }
        Work = { param($P) Remove-FleetReport $P.Computer } }

    installApp = @{ Name = 'Installing CleanIT'; Prep = { param($A) @{ AppDir = $script:AppDir } }; Work = { param($P) Install-CleanITApp $P.AppDir } }
    uninstallApp = @{ Name = 'Removing shortcuts and tasks'; Work = { param($P) Uninstall-CleanITApp } }
}

function Start-Action {
    param([string]$Action, $A)
    $def = $script:Actions[$Action]
    if (-not $def) { throw "Unknown action '$Action'." }
    $p = @{}
    if ($def.Prep) { $p = & $def.Prep $A }
    $st = $null
    if ($def.Scan) { Initialize-Native; $st = New-Object CleanIT.ScanState; $p.State = $st }
    $job = Start-ServerJob -Name $def.Name -Work $def.Work -Params $p -Finalize $def.Finalize -ScanState $st
    $job.Id
}

function Get-AppState {
    $s = Get-Settings
    $drives = @(Get-FixedDrives | ForEach-Object { "$($_.DeviceID)\" })
    $places = @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Videos')) |
        Where-Object { Test-Path -LiteralPath $_ }
    [pscustomobject]@{
        version = $script:Version; computer = $env:COMPUTERNAME; settings = $s; isAdmin = (Test-Admin)
        protection = $script:Protection; restorePointMade = $script:RestorePointMade; schedule = (Test-Schedule)
        fleet = (Get-FleetStatus); winget = (Test-Winget); update = (Get-UpdateInfo -CacheOnly); antivirus = @($script:AvInfo); dataDir = $script:DataDir; logDir = $script:LogDir
        places = @($drives + $places); userProfile = $env:USERPROFILE
        categories = @($script:CategoryDefs | ForEach-Object {
            [pscustomobject]@{ key = $_.Key; name = $_.Name; description = $_.Description; group = $_.Group; default = $_.Default; deep = $_.Deep; warning = $_.Warning } })
        jobs = @($script:Jobs.Values | Where-Object { $_.Status -eq 'running' } | ForEach-Object { Get-JobDto $_ -Light })
    }
}

# ---------------------------------------------------------------------------
# Minimal HTTP/1.1 server on a TcpListener (one request per connection)
# ---------------------------------------------------------------------------
function Read-HttpRequest {
    param($Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 5000
    $buf = New-Object byte[] 16384
    $ms = New-Object IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        if ($ms.Length -gt 65536) { return $null }
        $headerEnd = [Text.Encoding]::ASCII.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
    }
    $all = $ms.ToArray()
    $lines = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd) -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 2) { return $null }
    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $c = $lines[$i].IndexOf(':')
        if ($c -gt 0) { $headers[$lines[$i].Substring(0, $c).Trim().ToLowerInvariant()] = $lines[$i].Substring($c + 1).Trim() }
    }
    $len = 0
    if ($headers['content-length']) { $len = [int]$headers['content-length'] }
    if ($len -gt 4MB) { return $null }
    $body = New-Object IO.MemoryStream
    $start = $headerEnd + 4
    if ($all.Length -gt $start) { $body.Write($all, $start, $all.Length - $start) }
    while ($body.Length -lt $len) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $body.Write($buf, 0, $n)
    }
    $target = $parts[1]; $path = $target; $query = @{}
    $q = $target.IndexOf('?')
    if ($q -ge 0) {
        $path = $target.Substring(0, $q)
        foreach ($kv in ($target.Substring($q + 1) -split '&')) {
            if (-not $kv) { continue }
            $e = $kv.IndexOf('=')
            if ($e -ge 0) { $query[[Uri]::UnescapeDataString($kv.Substring(0, $e).Replace('+', ' '))] = [Uri]::UnescapeDataString($kv.Substring($e + 1).Replace('+', ' ')) }
            else { $query[$kv] = '' }
        }
    }
    [pscustomobject]@{
        Method = $parts[0].ToUpperInvariant(); Path = [Uri]::UnescapeDataString($path); Query = $query; Headers = $headers
        Body = [Text.Encoding]::UTF8.GetString($body.ToArray()); Stream = $stream
    }
}

function Send-HttpResponse {
    param($Req, [int]$Status = 200, [string]$ContentType = 'application/json; charset=utf-8', [byte[]]$Body = @(), [hashtable]$Headers = @{})
    $reasons = @{ 200 = 'OK'; 302 = 'Found'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }
    $h = [ordered]@{
        'Content-Type' = $ContentType; 'Content-Length' = $Body.Length; 'Connection' = 'close'; 'Cache-Control' = 'no-store'
        'X-Content-Type-Options' = 'nosniff'; 'X-Frame-Options' = 'DENY'; 'Referrer-Policy' = 'no-referrer'
        'Content-Security-Policy' = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; form-action 'none'"
    }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status $($reasons[$Status])`r`n")
    foreach ($k in $h.Keys) { [void]$sb.Append("${k}: $($h[$k])`r`n") }
    [void]$sb.Append("`r`n")
    $hb = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Req.Stream.Write($hb, 0, $hb.Length)
    if ($Body.Length) { $Req.Stream.Write($Body, 0, $Body.Length) }
    $Req.Stream.Flush()
}

function Send-Json {
    param($Req, $Object, [int]$Status = 200)
    $json = 'null'
    if ($null -ne $Object) { $json = ConvertTo-Json -InputObject $Object -Depth 10 -Compress }
    Send-HttpResponse $Req $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Send-Page {
    param($Req, [int]$Status, [string]$Message)
    $html = "<!doctype html><meta charset=utf-8><title>CleanIT</title><body style=""font-family:Segoe UI,sans-serif;padding:40px;color:#334155""><h2>CleanIT</h2><p>$Message</p></body>"
    Send-HttpResponse $Req $Status 'text/html; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($html))
}

function Get-Cookie {
    param($Req, [string]$Name)
    $raw = [string]$Req.Headers['cookie']
    foreach ($part in ($raw -split ';')) {
        $kv = $part.Trim() -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0] -eq $Name) { return $kv[1] }
    }
    $null
}

$script:StaticFiles = @{ '/' = @('index.html', 'text/html; charset=utf-8'); '/index.html' = @('index.html', 'text/html; charset=utf-8')
                         '/app.js' = @('app.js', 'text/javascript; charset=utf-8'); '/app.css' = @('app.css', 'text/css; charset=utf-8') }

function Invoke-HttpClient {
    param($Client)
    $req = Read-HttpRequest $Client
    if (-not $req) { return }
    # Only our own address - blocks DNS-rebinding tricks from web pages.
    if ($req.Headers['host'] -ne $script:HostHeader) { Send-Page $req 403 'Forbidden.'; return }

    if ($req.Path -eq '/login') {
        $t = [string]$req.Query['t']
        if ($t -and $script:LoginTokens.ContainsKey($t) -and $script:LoginTokens[$t] -gt (Get-Date)) {
            $script:LoginTokens.Remove($t)
            $script:LastPing = Get-Date
            Send-HttpResponse $req 302 'text/plain' @() @{ 'Location' = '/'; 'Set-Cookie' = "cleanit=$($script:SessionCookie); HttpOnly; SameSite=Strict; Path=/" }
        }
        else { Send-Page $req 401 'This link has expired. Open CleanIT again from its shortcut.' }
        return
    }
    if ($req.Path -eq '/api/newlogin' -and $req.Method -eq 'POST') {
        # A second launch of CleanIT asks this running instance for a new window (it knows the admin-only secret).
        if ($req.Headers['x-cleanit-master'] -and $req.Headers['x-cleanit-master'] -eq $script:MasterSecret) {
            Send-Json $req @{ token = (New-LoginToken); version = $script:Version; appDir = $script:AppDir }
        }
        else { Send-Page $req 403 'Forbidden.' }
        return
    }
    if ((Get-Cookie $req 'cleanit') -ne $script:SessionCookie) { Send-Page $req 401 'Please open CleanIT from its shortcut.'; return }
    if ($req.Method -eq 'POST' -and $req.Headers['x-cleanit'] -ne '1') { Send-Page $req 403 'Forbidden.'; return }

    if ($req.Path -eq '/favicon.png') { Send-HttpResponse $req 200 'image/png' $script:FaviconBytes; return }
    if ($script:StaticFiles.ContainsKey($req.Path)) {
        $f = Join-Path $script:WebDir $script:StaticFiles[$req.Path][0]
        Send-HttpResponse $req 200 $script:StaticFiles[$req.Path][1] ([IO.File]::ReadAllBytes($f))
        return
    }
    if ($req.Path.StartsWith('/api/')) { Invoke-Api $req; return }
    Send-Page $req 404 'Not found.'
}

function Invoke-Api {
    param($Req)
    $body = $null
    if ($Req.Body) { try { $body = $Req.Body | ConvertFrom-Json } catch { Send-Json $Req @{ error = 'Bad JSON' } 400; return } }
    $script:LastPing = Get-Date
    try {
        switch -Regex ($Req.Path) {
            '^/api/ping$' {
                Send-Json $Req @{ jobs = @($script:Jobs.Values | Where-Object { $_.Status -eq 'running' } | Sort-Object Started | ForEach-Object { Get-JobDto $_ -Light }) }
                break
            }
            '^/api/state$' { Send-Json $Req (Get-AppState); break }
            '^/api/log$' {
                $since = 0; [void][int]::TryParse([string]$Req.Query['since'], [ref]$since)
                Send-Json $Req @{ next = $script:LogSeq; lines = @($script:LogBuffer | Where-Object { $_.n -gt $since } | Select-Object -Last 400) }
                break
            }
            '^/api/jobs/(j\d+)$' {
                $j = $script:Jobs[$Matches[1]]
                if (-not $j) { Send-Json $Req @{ error = 'Job not found' } 404 } else { Send-Json $Req (Get-JobDto $j) }
                break
            }
            '^/api/jobs/(j\d+)/cancel$' {
                $j = $script:Jobs[$Matches[1]]
                if ($j) { $j.Sync.Cancel = $true; if ($j.ScanState) { $j.ScanState.Cancel = $true }; Write-Log "Cancel requested: $($j.Name)" 'WARN' }
                Send-Json $Req @{ ok = $true }
                break
            }
            '^/api/run$' {
                $id = Start-Action ([string]$body.action) $body.args
                Send-Json $Req @{ jobId = $id }
                break
            }
            '^/api/disk/node$' {
                $n = Find-DiskNode ([string]$Req.Query['path'])
                if (-not $n) { Send-Json $Req @{ error = 'Folder not in the last scan.' } 404 } else { Send-Json $Req (Get-DiskNodeDto $n) }
                break
            }
            '^/api/settings$' {
                $s = Get-Settings
                if ($null -ne $body.RestorePoint) { $s.RestorePoint = [bool]$body.RestorePoint }
                if ($null -ne $body.ShowMicrosoft) { $s.ShowMicrosoft = [bool]$body.ShowMicrosoft }
                if ($null -ne $body.UpdateCheck) { $s.UpdateCheck = [bool]$body.UpdateCheck }
                if ($null -ne $body.AutoUpdate) { $s.AutoUpdate = [bool]$body.AutoUpdate }
                if ($null -ne $body.AvNoticeHidden) { $s.AvNoticeHidden = [bool]$body.AvNoticeHidden }
                if ($body.ShutdownsSeen -eq $true) { $s.ShutdownsSeenUntil = (Get-Date).ToUniversalTime().ToString('o') }
                if ($null -ne $body.Theme) {
                    if (@('auto', 'light', 'dark') -notcontains [string]$body.Theme) { throw 'Unknown theme.' }
                    $s.Theme = [string]$body.Theme
                }
                if ($null -ne $body.WingetExclude) {
                    $s.WingetExclude = @($body.WingetExclude | Where-Object { Test-SafeId $_ '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,120}$' })
                }
                Save-Settings $s
                Send-Json $Req $s
                break
            }
            '^/api/open$' {
                $what = [string]$body.what
                switch ($what) {
                    'logs'     { Open-ForUser $script:LogDir }
                    'data'     { Open-ForUser $script:DataDir }
                    'backups'  { Open-ForUser $script:BackupDir }
                    'restore'  { Start-Process "$env:SystemRoot\System32\rstrui.exe" }
                    'devmgmt'  { Start-Process "$env:SystemRoot\System32\devmgmt.msc" }
                    'path' {
                        $p = [string]$body.path
                        if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
                        if (Test-Path -LiteralPath $p -PathType Leaf) { Open-ForUser $p -Select } else { Open-ForUser $p }
                    }
                    'url' {
                        $u = [string]$body.url
                        $web = '^https://(www\.nvidia\.com|us\.download\.nvidia\.com|www\.amd\.com|www\.intel\.com|www\.bing\.com)/[\w\-./?=&%+:]*$'
                        if ($u -notmatch '^(ms-settings:[a-z\-]+|windowsdefender:|windowsdefender://coreisolation|ms-windows-store://(pdp/\?PFN=[\w.\-]+|search/\?query=[\w%.\-+]+))$' -and $u -notmatch $web) { throw 'Link not allowed.' }
                        Open-ForUser $u
                    }
                    default { throw 'Unknown target.' }
                }
                Send-Json $Req @{ ok = $true }
                break
            }
            '^/api/quit$' { $script:ServerQuit = $true; Send-Json $Req @{ ok = $true }; break }
            default { Send-Json $Req @{ error = 'Not found' } 404 }
        }
    }
    catch { Send-Json $Req @{ error = $_.Exception.Message } 400 }
}

# ---------------------------------------------------------------------------
# Start / reuse
# ---------------------------------------------------------------------------
function Start-CleanITApp {
    param([switch]$NoWindow)
    # Already running? Ask it for a fresh window instead of starting a second server.
    $sess = Read-JsonFile $script:SessionFile
    if ($sess -and $sess.Port -and $sess.Master) {
        try {
            $wc = New-Object Net.WebClient
            $wc.Proxy = $null
            $wc.Headers.Add('X-CleanIT-Master', [string]$sess.Master)
            $r = $wc.UploadString("http://127.0.0.1:$($sess.Port)/api/newlogin", 'POST', '') | ConvertFrom-Json
            if ($r.token -and [string]$r.version -eq $script:Version -and [string]$r.appDir -eq $script:AppDir) {
                Open-AppWindow "http://127.0.0.1:$($sess.Port)/login?t=$($r.token)"
                return
            }
            # A different CleanIT version (or copy) is still running - replace it, otherwise the new page
            # would talk to old server code ("Unknown action ...").
            $old = Get-Process -Id ([int]$sess.Pid) -ErrorAction SilentlyContinue
            if ($old -and $old.ProcessName -match '^powershell') {
                Write-Log "Replacing CleanIT $($r.version) that was still running (PID $($sess.Pid)) with $($script:Version)."
                Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 800
            }
        }
        catch {}
    }
    Start-CleanITServer -NoWindow:$NoWindow
}

function Start-CleanITServer {
    param([switch]$NoWindow)
    $script:LogBuffer = New-Object System.Collections.Generic.List[object]
    $script:Quiet = $true
    $script:WebDir = Join-Path $script:AppDir 'web'
    $script:LoginTokens = @{}
    $script:MasterSecret = New-Secret
    $script:SessionCookie = New-Secret
    if ((Test-Admin) -and -not $env:CLEANIT_DATADIR) { try { Protect-DataDir } catch {} }   # repairs files locked by v2.0-2.2
    $script:Protection = Test-SystemProtection
    $script:AvInfo = @(Get-ThirdPartyAntivirus)   # cached: Security Center can be slow
    Initialize-Native

    $ms = New-Object IO.MemoryStream
    (Get-CleanITIconBitmap 64).Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $script:FaviconBytes = $ms.ToArray()
    $script:IconFile = Join-Path $script:DataDir 'CleanIT.ico'
    if (-not (Test-Path -LiteralPath $script:IconFile)) { try { Save-CleanITIco $script:IconFile } catch {} }

    $tcp = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $script:HostHeader = "127.0.0.1:$port"

    # Lets a second launch reuse this window/server. Readable by administrators only (it holds the master secret).
    try {
        Write-JsonFile $script:SessionFile ([pscustomobject]@{ Port = $port; Master = $script:MasterSecret; Pid = $PID })
        & icacls.exe $script:SessionFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-Null
    }
    catch { Write-Log "Could not write the session file: $($_.Exception.Message)" 'WARN' }

    Write-Log "CleanIT $($script:Version) started (local web UI on 127.0.0.1:$port). Log file: $($script:LogFile)"
    $url = "http://127.0.0.1:$port/login?t=$(New-LoginToken)"
    if ($env:CLEANIT_LOGIN_FILE) { Set-Content -LiteralPath $env:CLEANIT_LOGIN_FILE -Value $url }
    if (-not $NoWindow) { Open-AppWindow $url }

    $script:LastPing = (Get-Date).AddSeconds(90)   # time for the window to open
    $lastTick = Get-Date
    try {
        while (-not $script:ServerQuit) {
            if ($tcp.Pending()) {
                $client = $tcp.AcceptTcpClient()
                try { Invoke-HttpClient $client } catch { Write-Log "Web UI request failed: $($_.Exception.Message)" 'WARN' } finally { $client.Close() }
            }
            else { Start-Sleep -Milliseconds 15 }
            if (((Get-Date) - $lastTick).TotalMilliseconds -ge 150) {
                $lastTick = Get-Date
                Update-ServerJobs
                Remove-TempLinks
                Set-WindowIdentity
                $running = @($script:Jobs.Values | Where-Object { $_.Status -eq 'running' }).Count
                # Window closed (no pings for a while) and nothing running -> stop. Minimized windows ping slowly, hence 3 minutes.
                if (-not $running -and -not $env:CLEANIT_STAY -and ((Get-Date) - $script:LastPing).TotalSeconds -gt 180) {
                    Write-Log 'CleanIT window closed - stopping.'
                    break
                }
            }
        }
    }
    finally {
        $tcp.Stop()
        Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue
        foreach ($t in $script:TempLinks.ToArray()) { Remove-Item -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue }
    }
}
