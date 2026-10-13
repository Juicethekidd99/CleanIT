# CleanIT.Core.ps1 - engine for CleanIT. Dot-sourced by CleanIT.ps1 and by background jobs.
# Rules: Windows PowerShell 5.1 only syntax, ASCII-only source, nothing destructive without a preview,
# every system change is reversible and its previous state is recorded under DataDir\State.

$script:AppName     = 'CleanIT'
$script:Version     = '2.0.0'
$script:CorePath    = $PSCommandPath
$script:DataDir     = $env:CLEANIT_DATADIR
if (-not $script:DataDir) { $script:DataDir = Join-Path $env:ProgramData 'CleanIT' }
$script:StateDir    = Join-Path $script:DataDir 'State'
$script:BackupDir   = Join-Path $script:DataDir 'Backups'
$script:HistoryFile = Join-Path $script:DataDir 'history.json'
$script:SettingsFile = Join-Path $script:DataDir 'settings.json'
$script:TaskName       = 'CleanIT Weekly'
$script:NotifyTaskName = 'CleanIT Notify'
$script:OldTaskName    = 'PCCleanup Weekly'
if (-not $script:LogDir)  { $script:LogDir = Join-Path $script:DataDir 'Logs' }
if (-not $script:LogFile) { $script:LogFile = Join-Path $script:LogDir ('CleanIT_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date)) }
foreach ($d in @($script:DataDir, $script:StateDir, $script:BackupDir, $script:LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------------------------------------------------------------------------
# Logging & small helpers
# ---------------------------------------------------------------------------
$script:LogSink = $null    # RichTextBox when the GUI is running
$script:Quiet   = $false   # -Silent

function Write-LogLine {
    param([string]$Line, [string]$Level = 'INFO')
    Add-Content -Path $script:LogFile -Value $Line
    if ($script:LogSink) {
        $color = switch ($Level) {
            'WARN'  { [System.Drawing.Color]::FromArgb(250, 204, 21) }
            'ERROR' { [System.Drawing.Color]::FromArgb(248, 113, 113) }
            'OK'    { [System.Drawing.Color]::FromArgb(74, 222, 128) }
            default { [System.Drawing.Color]::FromArgb(212, 212, 216) }
        }
        $script:LogSink.SelectionStart = $script:LogSink.TextLength
        $script:LogSink.SelectionColor = $color
        $script:LogSink.AppendText($Line + [Environment]::NewLine)
        $script:LogSink.ScrollToCaret()
    }
    elseif (-not $script:Quiet) {
        $c = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host $Line -ForegroundColor $c
    }
}

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Msg
    # Background jobs hand their lines to the UI thread, which writes file + window.
    if ($global:CleanITBg) { $global:CleanITBg.Log.Enqueue($Level + '|' + $line); return }
    Write-LogLine $line $Level
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -lt 0)   { return 'n/a' }
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function Format-Ago {
    param($Date)
    if (-not $Date) { return 'never' }
    $span = (Get-Date) - [datetime]$Date
    if ($span.TotalMinutes -lt 2) { return 'just now' }
    if ($span.TotalHours -lt 1)   { return ('{0:N0} min ago' -f $span.TotalMinutes) }
    if ($span.TotalDays -lt 1)    { return ('{0:N0} h ago' -f $span.TotalHours) }
    return ('{0:N0} day(s) ago' -f [math]::Floor($span.TotalDays))
}

# Runs a status query in its own runspace and gives up after $Seconds, so one stuck provider
# (WMI, Defender, TPM, BitLocker...) can never freeze a scan. Returns $Default on timeout/error.
$script:TimedOut = New-Object System.Collections.Generic.List[string]
function Invoke-WithTimeout {
    param([string]$Name, [scriptblock]$Script, [int]$Seconds = 15, $Default = $null)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript('$ErrorActionPreference = ''SilentlyContinue''; ' + $Script.ToString())
    $h = $ps.BeginInvoke()
    if ($h.AsyncWaitHandle.WaitOne($Seconds * 1000)) {
        $r = $Default
        try { $r = @($ps.EndInvoke($h)) | ForEach-Object { $_ } } catch {}
        $ps.Dispose(); $rs.Dispose()
        if ($null -eq $r) { return $Default }
        return $r
    }
    # Abandon the stuck query (its thread is left to finish or die with the process).
    $script:TimedOut.Add($Name)
    Write-Log "$Name did not respond within $Seconds s - skipped." 'WARN'
    try { [void]$ps.BeginStop($null, $null) } catch {}
    $Default
}

function Invoke-UiPump { if ($script:LogSink) { [System.Windows.Forms.Application]::DoEvents() } }

function Test-BgCancel { [bool]($global:CleanITBg -and $global:CleanITBg.Cancel) }

function Set-BgProgress {
    param([int]$Percent, [string]$Status)
    if ($global:CleanITBg) {
        $global:CleanITBg.Progress = [math]::Max(0, [math]::Min(100, $Percent))
        if ($Status) { $global:CleanITBg.Status = $Status }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UserProfiles {
    Get-CimInstance Win32_UserProfile |
        Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
        ForEach-Object { $_.LocalPath }
}

function Get-FixedDrives { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' }

function Read-JsonFile {
    param([string]$Path, $Default = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        if (-not $raw.Trim()) { return $Default }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { return $Default }
}

function Write-JsonFile {
    param([string]$Path, $Object, [int]$Depth = 6)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

# Pulls the executable out of a command line ("C:\x y\a.exe" -b, C:\x y\a.exe -b, %windir%\..., rundll32 ...)
function Get-ExePath {
    param([string]$Command)
    if (-not $Command) { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim()) -replace '^\\\?\?\\', ''
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
    }
    $parts = $c -split ' '
    for ($i = 1; $i -le $parts.Count; $i++) {
        $cand = ($parts[0..($i - 1)] -join ' ')
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
        if (Test-Path -LiteralPath "$cand.exe" -PathType Leaf) { return "$cand.exe" }
    }
    $gc = Get-Command $parts[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gc) { return $gc.Source }
    return $parts[0]
}

function Split-CommandLine {
    param([string]$Command)
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    $exe = Get-ExePath $c
    $rest = ''
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 0) { $rest = $c.Substring($end + 1).Trim() }
    }
    elseif ($exe -and $c.Length -ge $exe.Length -and $c.Substring(0, $exe.Length) -eq $exe) {
        $rest = $c.Substring($exe.Length).Trim()
    }
    else {
        $sp = $c.IndexOf(' ')
        if ($sp -gt 0) { $rest = $c.Substring($sp + 1).Trim() }
    }
    @($exe, $rest)
}

$script:SigCache = @{}
function Get-FilePublisher {
    param([string]$Path)
    if (-not $Path) { return '' }
    if ($script:SigCache.ContainsKey($Path)) { return $script:SigCache[$Path] }
    $pub = ''
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($sig -and $sig.SignerCertificate) {
            $subj = $sig.SignerCertificate.Subject
            if ($subj -match 'O="([^"]+)"') { $pub = $Matches[1] }
            elseif ($subj -match 'O=([^,]+)') { $pub = $Matches[1] }
            elseif ($subj -match 'CN="?([^",]+)') { $pub = $Matches[1] }
            if ($sig.Status -ne 'Valid') { $pub += ' (signature NOT valid)' }
        }
        else {
            $co = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).VersionInfo.CompanyName
            if ($co) { $pub = "$co (unsigned)" } else { $pub = '(unsigned)' }
        }
    }
    $script:SigCache[$Path] = $pub.Trim()
    $script:SigCache[$Path]
}

# ---------------------------------------------------------------------------
# Native helpers (C#): fast junction-safe folder walker, duplicate hashing, list sorting/bars
# ---------------------------------------------------------------------------
$script:NativeSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

namespace CleanIT
{
    public class DirNode
    {
        public string Name;
        public string FullPath;
        public DirNode Parent;
        public List<DirNode> Children = new List<DirNode>();
        public long OwnBytes;
        public long OwnFiles;
        public long Size;
        public long Files;
        public bool Denied;
    }

    public class FileHit
    {
        public string Path;
        public long Size;
        public DateTime LastWrite;
        public DateTime LastAccess;
        public string Hash;
        public int Group;
    }

    public class ScanState
    {
        public long Dirs;
        public long Files;
        public long Bytes;
        public string Current = "";
        public string Phase = "";
        public volatile bool Cancel;
    }

    public static class Disk
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct FindData
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
            public System.Runtime.InteropServices.ComTypes.FILETIME Access;
            public System.Runtime.InteropServices.ComTypes.FILETIME Write;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Reserved0;
            public uint Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string FileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AltName;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleInfo
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
            public System.Runtime.InteropServices.ComTypes.FILETIME Access;
            public System.Runtime.InteropServices.ComTypes.FILETIME Write;
            public uint VolumeSerial;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Links;
            public uint IndexHigh;
            public uint IndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileExW(string name, int infoLevel, out FindData data, int searchOp, IntPtr filter, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool FindNextFileW(IntPtr h, out FindData data);
        [DllImport("kernel32.dll")]
        private static extern bool FindClose(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle h, out ByHandleInfo info);

        private const uint ATTR_DIR = 0x10, ATTR_REPARSE = 0x400, ATTR_OFFLINE = 0x1000;
        private const uint ATTR_RECALL_OPEN = 0x40000, ATTR_RECALL_DATA = 0x400000;
        private static readonly IntPtr Invalid = new IntPtr(-1);

        private struct Entry
        {
            public string Name;
            public uint Attr;
            public long Size;
            public DateTime Write;
            public DateTime Access;
            public uint Tag;
        }

        public static string LongPath(string p)
        {
            if (p.StartsWith(@"\\?\")) return p;
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
            return @"\\?\" + p;
        }

        private static string Join(string dir, string name)
        {
            return dir.EndsWith("\\") ? dir + name : dir + "\\" + name;
        }

        private static DateTime Ft(System.Runtime.InteropServices.ComTypes.FILETIME f)
        {
            long v = ((long)(uint)f.dwHighDateTime << 32) | (uint)f.dwLowDateTime;
            try { return DateTime.FromFileTime(v); } catch { return DateTime.MinValue; }
        }

        private static bool List(string dir, List<Entry> into)
        {
            into.Clear();
            FindData fd;
            string pattern = LongPath(dir.TrimEnd('\\')) + @"\*";
            IntPtr h = FindFirstFileExW(pattern, 1, out fd, 0, IntPtr.Zero, 2);
            if (h == Invalid) return false;
            try
            {
                do
                {
                    if (fd.FileName == "." || fd.FileName == "..") continue;
                    Entry e = new Entry();
                    e.Name = fd.FileName;
                    e.Attr = fd.Attributes;
                    e.Size = ((long)fd.SizeHigh << 32) | fd.SizeLow;
                    e.Write = Ft(fd.Write);
                    e.Access = Ft(fd.Access);
                    e.Tag = ((fd.Attributes & ATTR_REPARSE) != 0) ? fd.Reserved0 : 0;
                    into.Add(e);
                } while (FindNextFileW(h, out fd));
            }
            finally { FindClose(h); }
            return true;
        }

        private static bool IsCloudTag(uint tag) { return (tag & 0xFFFF0FFF) == 0x9000001A; }

        // Never descend into junctions, symlinks or mount points. OneDrive (cloud files) folders are not links.
        private static bool CanDescend(Entry e)
        {
            if ((e.Attr & ATTR_DIR) == 0) return false;
            if ((e.Attr & ATTR_REPARSE) == 0) return true;
            return IsCloudTag(e.Tag);
        }

        // Files that really take space on this disk (not online-only cloud placeholders, not symlinks)
        private static bool IsLocal(Entry e)
        {
            if ((e.Attr & (ATTR_OFFLINE | ATTR_RECALL_DATA | ATTR_RECALL_OPEN)) != 0) return false;
            if ((e.Attr & ATTR_REPARSE) != 0 && !IsCloudTag(e.Tag)) return false;
            return true;
        }

        private static bool Excluded(string path, string[] ex)
        {
            if (ex == null) return false;
            foreach (string x in ex)
            {
                if (string.IsNullOrEmpty(x)) continue;
                string t = x.TrimEnd('\\');
                if (path.Equals(t, StringComparison.OrdinalIgnoreCase)) return true;
                if (path.StartsWith(t + "\\", StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private delegate void FileVisitor(string path, Entry e);

        private static void Walk(string root, string[] excludes, ScanState st, FileVisitor onFile)
        {
            Stack<string> stack = new Stack<string>();
            stack.Push(root);
            List<Entry> buf = new List<Entry>();
            while (stack.Count > 0)
            {
                if (st.Cancel) return;
                string dir = stack.Pop();
                st.Current = dir;
                Interlocked.Increment(ref st.Dirs);
                if (!List(dir, buf)) continue;
                foreach (Entry e in buf)
                {
                    string full = Join(dir, e.Name);
                    if ((e.Attr & ATTR_DIR) != 0)
                    {
                        if (CanDescend(e) && !Excluded(full, excludes)) stack.Push(full);
                    }
                    else
                    {
                        Interlocked.Increment(ref st.Files);
                        onFile(full, e);
                    }
                }
            }
        }

        public static DirNode ScanTree(string root, ScanState st)
        {
            DirNode top = new DirNode();
            top.FullPath = root.EndsWith(":") ? root + "\\" : root;
            top.Name = top.FullPath;
            List<DirNode> order = new List<DirNode>();
            Stack<DirNode> stack = new Stack<DirNode>();
            stack.Push(top);
            List<Entry> buf = new List<Entry>();
            while (stack.Count > 0)
            {
                if (st.Cancel) break;
                DirNode n = stack.Pop();
                order.Add(n);
                st.Current = n.FullPath;
                Interlocked.Increment(ref st.Dirs);
                if (!List(n.FullPath, buf)) { n.Denied = true; continue; }
                foreach (Entry e in buf)
                {
                    if ((e.Attr & ATTR_DIR) != 0)
                    {
                        if (!CanDescend(e)) continue;
                        DirNode c = new DirNode();
                        c.Name = e.Name;
                        c.FullPath = Join(n.FullPath, e.Name);
                        c.Parent = n;
                        n.Children.Add(c);
                        stack.Push(c);
                    }
                    else if (IsLocal(e))
                    {
                        n.OwnBytes += e.Size;
                        n.OwnFiles++;
                        Interlocked.Increment(ref st.Files);
                        Interlocked.Add(ref st.Bytes, e.Size);
                    }
                }
            }
            for (int i = order.Count - 1; i >= 0; i--)
            {
                DirNode n = order[i];
                n.Size += n.OwnBytes;
                n.Files += n.OwnFiles;
                if (n.Parent != null) { n.Parent.Size += n.Size; n.Parent.Files += n.Files; }
            }
            return top;
        }

        public static long FolderSize(string root)
        {
            return ScanTree(root, new ScanState()).Size;
        }

        public static List<FileHit> FindLarge(string root, long minBytes, DateTime notUsedSince, int max, string[] excludes, ScanState st)
        {
            List<FileHit> hits = new List<FileHit>();
            Comparison<FileHit> bySizeDesc = delegate(FileHit a, FileHit b) { return b.Size.CompareTo(a.Size); };
            Walk(root, excludes, st, delegate(string path, Entry e)
            {
                if (e.Size < minBytes || !IsLocal(e)) return;
                DateTime last = e.Write > e.Access ? e.Write : e.Access;
                if (last > notUsedSince) return;
                FileHit f = new FileHit();
                f.Path = path; f.Size = e.Size; f.LastWrite = e.Write; f.LastAccess = e.Access;
                hits.Add(f);
                Interlocked.Add(ref st.Bytes, e.Size);
                if (hits.Count > max * 2) { hits.Sort(bySizeDesc); hits.RemoveRange(max, hits.Count - max); }
            });
            hits.Sort(bySizeDesc);
            if (hits.Count > max) hits.RemoveRange(max, hits.Count - max);
            return hits;
        }

        private static string HashFile(string path, long maxBytes, ScanState st, out string fileId)
        {
            fileId = null;
            SafeFileHandle h = CreateFileW(LongPath(path), 0x80000000, 7, IntPtr.Zero, 3, 0x08000000, IntPtr.Zero);
            if (h.IsInvalid) { h.Dispose(); return null; }
            ByHandleInfo bi;
            if (GetFileInformationByHandle(h, out bi))
                fileId = bi.VolumeSerial.ToString("X") + ":" + bi.IndexHigh.ToString("X") + ":" + bi.IndexLow.ToString("X");
            using (FileStream fs = new FileStream(h, FileAccess.Read, 1 << 16))
            using (SHA256 sha = SHA256.Create())
            {
                byte[] buf = new byte[1 << 16];
                long left = maxBytes <= 0 ? long.MaxValue : maxBytes;
                while (left > 0)
                {
                    if (st.Cancel) return null;
                    int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left));
                    if (n <= 0) break;
                    sha.TransformBlock(buf, 0, n, null, 0);
                    left -= n;
                    Interlocked.Add(ref st.Bytes, n);
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                return BitConverter.ToString(sha.Hash).Replace("-", "");
            }
        }

        public static List<FileHit> FindDuplicates(string root, long minBytes, string[] excludes, ScanState st)
        {
            Dictionary<long, List<FileHit>> bySize = new Dictionary<long, List<FileHit>>();
            st.Phase = "Listing files";
            Walk(root, excludes, st, delegate(string path, Entry e)
            {
                if (e.Size < minBytes || !IsLocal(e)) return;
                FileHit f = new FileHit();
                f.Path = path; f.Size = e.Size; f.LastWrite = e.Write; f.LastAccess = e.Access;
                List<FileHit> l;
                if (!bySize.TryGetValue(e.Size, out l)) { l = new List<FileHit>(); bySize[e.Size] = l; }
                l.Add(f);
            });
            List<FileHit> result = new List<FileHit>();
            if (st.Cancel) return result;

            List<List<FileHit>> groups = new List<List<FileHit>>();
            foreach (KeyValuePair<long, List<FileHit>> kv in bySize) if (kv.Value.Count > 1) groups.Add(kv.Value);
            groups.Sort(delegate(List<FileHit> a, List<FileHit> b) { return b[0].Size.CompareTo(a[0].Size); });

            st.Phase = "Comparing contents";
            st.Bytes = 0;
            int gid = 0;
            foreach (List<FileHit> g in groups)
            {
                if (st.Cancel) break;
                Dictionary<string, List<FileHit>> byPartial = new Dictionary<string, List<FileHit>>();
                HashSet<string> seenIds = new HashSet<string>();
                foreach (FileHit f in g)
                {
                    st.Current = f.Path;
                    string id = null, ph = null;
                    try { ph = HashFile(f.Path, 65536, st, out id); } catch { ph = null; }
                    if (ph == null) continue;
                    if (id != null && !seenIds.Add(id)) continue; // hard link to a file already listed - no space to win
                    List<FileHit> l;
                    if (!byPartial.TryGetValue(ph, out l)) { l = new List<FileHit>(); byPartial[ph] = l; }
                    l.Add(f);
                    f.Hash = ph;
                }
                foreach (List<FileHit> pg in byPartial.Values)
                {
                    if (pg.Count < 2) continue;
                    Dictionary<string, List<FileHit>> byFull = new Dictionary<string, List<FileHit>>();
                    foreach (FileHit f in pg)
                    {
                        if (st.Cancel) break;
                        string full = f.Hash;
                        if (f.Size > 65536)
                        {
                            string id2;
                            try { full = HashFile(f.Path, 0, st, out id2); } catch { full = null; }
                        }
                        if (full == null) continue;
                        f.Hash = full;
                        List<FileHit> l;
                        if (!byFull.TryGetValue(full, out l)) { l = new List<FileHit>(); byFull[full] = l; }
                        l.Add(f);
                    }
                    foreach (List<FileHit> fg in byFull.Values)
                    {
                        if (fg.Count < 2) continue;
                        gid++;
                        foreach (FileHit f in fg) { f.Group = gid; result.Add(f); }
                    }
                }
            }
            return result;
        }
    }

    // Click-to-sort for ListViews. Sort key = SubItem.Tag when set (numbers/dates), else the text.
    public class LvSorter : IComparer
    {
        public int Column = -1;
        public bool Desc;

        private static object Key(ListViewItem it, int col)
        {
            if (col >= it.SubItems.Count) return "";
            object t = it.SubItems[col].Tag;
            return t ?? it.SubItems[col].Text;
        }

        public int Compare(object a, object b)
        {
            object x = Key((ListViewItem)a, Column), y = Key((ListViewItem)b, Column);
            int r;
            if (x is IComparable && y != null && x.GetType() == y.GetType()) r = ((IComparable)x).CompareTo(y);
            else r = string.Compare(Convert.ToString(x), Convert.ToString(y), StringComparison.CurrentCultureIgnoreCase);
            return Desc ? -r : r;
        }

        public static void Attach(ListView lv)
        {
            LvSorter s = new LvSorter();
            lv.ColumnClick += delegate(object sender, ColumnClickEventArgs e)
            {
                if (s.Column == e.Column) s.Desc = !s.Desc;
                else
                {
                    s.Column = e.Column;
                    s.Desc = lv.Items.Count > 0 && e.Column < lv.Items[0].SubItems.Count && lv.Items[0].SubItems[e.Column].Tag is double;
                }
                lv.ListViewItemSorter = s;
                lv.Sort();
            };
        }
    }

    // Draws a percentage bar in one ListView column (value = SubItem.Tag as double 0..100).
    public static class BarList
    {
        public static void Enable(ListView lv, int col, Color color)
        {
            lv.OwnerDraw = true;
            lv.DrawColumnHeader += delegate(object s, DrawListViewColumnHeaderEventArgs e) { e.DrawDefault = true; };
            lv.DrawItem += delegate(object s, DrawListViewItemEventArgs e) { };
            lv.DrawSubItem += delegate(object s, DrawListViewSubItemEventArgs e)
            {
                if (e.ColumnIndex != col) { e.DrawDefault = true; return; }
                Rectangle r = e.Bounds;
                bool sel = e.Item.Selected;
                using (SolidBrush bg = new SolidBrush(sel ? SystemColors.Highlight : lv.BackColor)) e.Graphics.FillRectangle(bg, r);
                double pct = 0;
                if (e.SubItem.Tag is double) pct = (double)e.SubItem.Tag;
                pct = Math.Max(0, Math.Min(100, pct));
                int w = (int)((r.Width - 8) * pct / 100.0);
                if (w > 0)
                    using (SolidBrush b = new SolidBrush(color)) e.Graphics.FillRectangle(b, new Rectangle(r.X + 4, r.Y + 4, w, r.Height - 8));
                TextRenderer.DrawText(e.Graphics, e.SubItem.Text, lv.Font, new Rectangle(r.X + 6, r.Y, r.Width - 10, r.Height),
                    sel ? SystemColors.HighlightText : lv.ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
            };
        }
    }
}
'@

function Initialize-Native {
    if ('CleanIT.Disk' -as [type]) { return }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -TypeDefinition $script:NativeSource -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Settings, history, state
# ---------------------------------------------------------------------------
function Get-DefaultSettings {
    [ordered]@{
        RestorePoint    = $true         # create a restore point before system changes / cleaning
        ScheduleDay     = 'Sunday'
        ScheduleTime    = '03:00'
        ScheduleUpdates = $false        # weekly task also updates apps via winget
        FleetPath       = ''            # shared folder for multi-PC reports
        WingetExclude   = @()           # winget IDs never auto-updated
        ShowMicrosoft   = $false        # show Microsoft tasks/services in Startup
    }
}

function Get-Settings {
    $s = Get-DefaultSettings
    $j = Read-JsonFile $script:SettingsFile
    if ($j) { foreach ($p in $j.PSObject.Properties) { if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value } } }
    $s.WingetExclude = @($s.WingetExclude | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
    $s
}

function Save-Settings { param($Settings) Write-JsonFile $script:SettingsFile $Settings }

function Get-CleanHistory { @(Read-JsonFile $script:HistoryFile @()) | Where-Object { $_ } }

function Add-HistoryEntry {
    param([string]$Source, [double]$Freed, $Details)
    $h = New-Object System.Collections.Generic.List[object]
    foreach ($e in Get-CleanHistory) { $h.Add($e) }
    $h.Add([pscustomobject]@{
        Date = (Get-Date).ToString('s'); Source = $Source; Freed = [double]$Freed; Details = @($Details)
    })
    while ($h.Count -gt 300) { $h.RemoveAt(0) }
    Write-JsonFile $script:HistoryFile $h.ToArray()
}

function Get-FreedTotal {
    $t = 0
    foreach ($e in Get-CleanHistory) { $t += [double]$e.Freed }
    [double]$t
}

function Get-StatePath { param([string]$Name) Join-Path $script:StateDir "$Name.json" }

function Get-LastCheck {
    $j = Read-JsonFile (Get-StatePath 'lastcheck')
    $o = [ordered]@{ AppUpdates = -1; AppDate = $null; WinUpdates = -1; WinDate = $null; Drivers = -1; DriverDate = $null }
    if ($j) { foreach ($p in $j.PSObject.Properties) { if ($o.Contains($p.Name)) { $o[$p.Name] = $p.Value } } }
    $o
}

function Set-LastCheck {
    param([string]$Field, [int]$Count)
    $o = Get-LastCheck
    $o[$Field] = $Count
    $dateField = @{ AppUpdates = 'AppDate'; WinUpdates = 'WinDate'; Drivers = 'DriverDate' }[$Field]
    $o[$dateField] = (Get-Date).ToString('s')
    Write-JsonFile (Get-StatePath 'lastcheck') $o
}

# ---------------------------------------------------------------------------
# Restore points
# ---------------------------------------------------------------------------
# $true = System Protection on for the system drive, $false = off, $null = unknown
function Test-SystemProtection {
    try {
        $vol = Invoke-WithTimeout 'System Protection check' { Get-CimInstance Win32_Volume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) } 10
        if (-not $vol) { return $null }
        if ($vol.DeviceID -notmatch 'Volume(\{[^}]+\})') { return $null }
        $guid = $Matches[1]
        $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -ErrorAction Stop
        $v = $key.'{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
        if (-not $v) { return $false }
        return [bool](($v -join ' ') -match [regex]::Escape($guid))
    }
    catch { return $null }
}

function Enable-SystemProtection {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
    & vssadmin.exe resize shadowstorage /for=$env:SystemDrive /on=$env:SystemDrive /maxsize=5% 2>&1 | Out-Null
    Write-Log "System Protection enabled on $env:SystemDrive (max 5% of the drive)." 'OK'
}

function New-CleanITRestorePoint {
    param([string]$Reason = 'CleanIT changes')
    $key  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    $old  = (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name
    try {
        # Windows silently skips a restore point if one was made in the last 24h - lift that for this one call.
        Set-ItemProperty -Path $key -Name $name -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Write-Log "Creating restore point ($Reason) - this can take a minute..."
        Checkpoint-Computer -Description "CleanIT: $Reason" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created.' 'OK'
        $true
    }
    catch {
        Write-Log ('Restore point not created: {0}' -f $_.Exception.Message) 'WARN'
        $false
    }
    finally {
        if ($null -eq $old) { Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $key -Name $name -Value $old -Type DWord -ErrorAction SilentlyContinue }
    }
}

function Get-RestorePoints {
    @(Invoke-WithTimeout 'Restore point list' { Get-ComputerRestorePoint } 15 @()) | ForEach-Object {
        [pscustomobject]@{
            Number = $_.SequenceNumber; Description = $_.Description
            Date = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime)
        }
    }
}

# ---------------------------------------------------------------------------
# Junk cleaning
# ---------------------------------------------------------------------------
# Walks a folder tree WITHOUT following junctions/symlinks (so we never delete through a link).
function Get-TreeSafe {
    param([string]$Root, [switch]$Files, [switch]$Directories)
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            $isReparse = [bool]($e.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if ($e.PSIsContainer) {
                if ($isReparse) { continue }
                $stack.Push($e.FullName)
                if ($Directories) { $e }
            }
            elseif ($Files -and -not $isReparse) { $e }
        }
    }
}

function Resolve-Targets {
    param([string[]]$Patterns)
    foreach ($pat in $Patterns) {
        if (-not $pat) { continue }
        foreach ($i in @(Get-Item -Path $pat -Force -ErrorAction SilentlyContinue)) {
            # the target itself must not be a link either
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $i
        }
    }
}

function Get-PathSize {
    param([string[]]$Patterns)
    $sum = 0
    foreach ($i in Resolve-Targets $Patterns) {
        if ($i.PSIsContainer) { foreach ($f in Get-TreeSafe $i.FullName -Files) { $sum += $f.Length } }
        else { $sum += $i.Length }
    }
    [double]$sum
}

function Get-SteamLibraries {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $p = (Get-ItemProperty -Path $k -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
        if ($p -and (Test-Path -LiteralPath $p) -and $set.Add($p.TrimEnd('\'))) { $roots.Add($p.TrimEnd('\')) }
    }
    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        $libs.Add($r)
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
                $lp = ($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
                if ((Test-Path -LiteralPath $lp) -and $set.Add($lp)) { $libs.Add($lp) }
            }
        }
    }
    [pscustomobject]@{ Roots = $roots.ToArray(); Libraries = $libs.ToArray() }
}

function New-Category {
    param(
        [string]$Key, [string]$Name, [string]$Description, [string]$Group = 'Windows',
        [scriptblock]$Paths = { @() },
        [bool]$Default = $true, [bool]$Deep = $false, [int]$MinAgeHours = 0,
        [scriptblock]$Before, [scriptblock]$After,
        [scriptblock]$Size, [scriptblock]$CleanBlock,
        [string[]]$Processes, [string]$Warning
    )
    [pscustomobject]@{
        Key = $Key; Name = $Name; Description = $Description; Group = $Group; Paths = $Paths
        Default = $Default; Deep = $Deep; MinAgeHours = $MinAgeHours
        Before = $Before; After = $After; Size = $Size; CleanBlock = $CleanBlock
        Processes = $Processes; Warning = $Warning
    }
}

# Folder names under VolumeCaches that cleanmgr uses for Windows upgrade leftovers
$script:UpgradeCacheHandlers = @('Previous Installations', 'Temporary Setup Files', 'Windows Upgrade Log Files',
                                 'Windows ESD installation files', 'Setup Log Files')

$script:CategoryDefs = @(
    # ---------------- Windows ----------------
    New-Category -Key 'UserTemp' -Name 'User temp files' -MinAgeHours 24 `
        -Description 'Temporary files in every user profile older than 24 hours.' `
        -Paths { foreach ($p in Get-UserProfiles) { "$p\AppData\Local\Temp" } }

    New-Category -Key 'WindowsTemp' -Name 'Windows temp files' -MinAgeHours 24 `
        -Description 'System temp folder (C:\Windows\Temp), older than 24 hours.' `
        -Paths { "$env:SystemRoot\Temp" }

    New-Category -Key 'WindowsUpdate' -Name 'Windows Update cache' `
        -Description 'Already-installed update downloads (SoftwareDistribution\Download).' `
        -Paths { "$env:SystemRoot\SoftwareDistribution\Download" } `
        -Before { Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue } `
        -After  { Start-Service -Name bits, wuauserv -ErrorAction SilentlyContinue }

    New-Category -Key 'DeliveryOpt' -Name 'Delivery Optimization cache' `
        -Description 'Peer-to-peer update cache Windows keeps to share updates with other PCs.' `
        -Paths { "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" } `
        -CleanBlock {
            $p = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
            $before = Get-PathSize $p
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue | Out-Null
            }
            [math]::Max(0, $before - (Get-PathSize $p))
        }

    New-Category -Key 'CrashDumps' -Name 'Crash dumps & error reports' `
        -Description 'Memory dumps, minidumps and Windows Error Reporting archives.' `
        -Paths {
            "$env:SystemRoot\Minidump"
            "$env:SystemRoot\MEMORY.DMP"
            "$env:SystemRoot\LiveKernelReports\*.dmp"
            "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
            "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
            foreach ($p in Get-UserProfiles) {
                "$p\AppData\Local\CrashDumps"
                "$p\AppData\Local\Microsoft\Windows\WER\ReportArchive"
                "$p\AppData\Local\Microsoft\Windows\WER\ReportQueue"
            }
        }

    New-Category -Key 'OldLogs' -Name 'Old Windows logs' -MinAgeHours 168 `
        -Description 'Servicing/DISM/update log files older than 7 days. Event logs are NOT touched.' `
        -Paths {
            "$env:SystemRoot\Logs\CBS"
            "$env:SystemRoot\Logs\DISM"
            "$env:SystemRoot\Logs\WindowsUpdate"
            "$env:SystemRoot\Logs\SIH"
        }

    New-Category -Key 'Thumbnails' -Name 'Thumbnail & icon cache' -Default $false `
        -Description 'Explorer thumbnail/icon databases. Rebuilt automatically; some files stay locked until restart.' `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                "$p\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db"
                "$p\AppData\Local\Microsoft\Windows\Explorer\iconcache_*.db"
            }
        }

    New-Category -Key 'ShaderCache' -Name 'GPU shader caches' -Default $false `
        -Description 'DirectX/NVIDIA/AMD/Intel and Steam shader caches. Games rebuild these (first launch may stutter).' `
        -Processes @('steam') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                "$p\AppData\Local\D3DSCache"
                "$p\AppData\Local\NVIDIA\DXCache"
                "$p\AppData\Local\NVIDIA\GLCache"
                "$p\AppData\Local\AMD\DxCache"
                "$p\AppData\Local\AMD\DxcCache"
                "$p\AppData\Local\AMD\GLCache"
                "$p\AppData\Local\AMD\VkCache"
                "$p\AppData\LocalLow\Intel\ShaderCache"
            }
            foreach ($l in (Get-SteamLibraries).Libraries) { "$l\steamapps\shadercache" }
        }

    New-Category -Key 'RecycleBin' -Name 'Recycle Bin' -Default $false `
        -Description 'Permanently empties the Recycle Bin on all fixed drives, for all users.' `
        -Warning 'Files in the Recycle Bin will be gone for good.' `
        -Paths { foreach ($d in Get-FixedDrives) { "$($d.DeviceID)\`$Recycle.Bin" } }

    New-Category -Key 'DriverLeftovers' -Name 'Driver installer leftovers' -Default $false `
        -Description 'Unpacked NVIDIA/AMD driver installers (C:\NVIDIA, C:\AMD) and the NVIDIA downloader cache. Installed drivers are not affected.' `
        -Paths {
            "$env:SystemDrive\NVIDIA"
            "$env:SystemDrive\AMD"
            "$env:ProgramData\NVIDIA Corporation\Downloader"
        }

    New-Category -Key 'ComponentStore' -Name 'Windows component store (WinSxS)' -Default $false -Deep $true `
        -Description 'Removes superseded Windows components via DISM. Safe but slow (5-20+ min).' `
        -Size { -1 } `
        -CleanBlock {
            $filter = "DeviceID='$env:SystemDrive'"
            $before = [double](Get-CimInstance Win32_LogicalDisk -Filter $filter).FreeSpace
            Write-Log '  Running DISM component cleanup - this can take a while...'
            $proc = Start-Process -FilePath "$env:SystemRoot\System32\Dism.exe" `
                -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/Quiet' `
                -WindowStyle Hidden -PassThru
            while (-not $proc.HasExited) { Start-Sleep -Milliseconds 400; Invoke-UiPump }
            $after = [double](Get-CimInstance Win32_LogicalDisk -Filter $filter).FreeSpace
            [math]::Max(0, $after - $before)
        }

    New-Category -Key 'WindowsOld' -Name 'Previous Windows installation (Windows.old)' -Default $false `
        -Description 'Windows.old and upgrade leftovers ($Windows.~BT, ESD files) via Windows Disk Cleanup.' `
        -Warning 'REMOVES ROLLBACK: after this you can no longer go back to the previous Windows version.' `
        -Paths {
            "$env:SystemDrive\Windows.old"
            "$env:SystemDrive\`$Windows.~BT"
            "$env:SystemDrive\`$Windows.~WS"
            "$env:SystemDrive\ESD\Windows"
        } `
        -CleanBlock {
            $cm = "$env:SystemRoot\System32\cleanmgr.exe"
            if (-not (Test-Path -LiteralPath $cm)) { Write-Log '  cleanmgr.exe not found on this PC - skipped.' 'WARN'; return 0 }
            $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            $filter = "DeviceID='$env:SystemDrive'"
            $before = [double](Get-CimInstance Win32_LogicalDisk -Filter $filter).FreeSpace
            foreach ($h in $script:UpgradeCacheHandlers) {
                if (Test-Path "$vc\$h") { Set-ItemProperty -Path "$vc\$h" -Name 'StateFlags0777' -Value 2 -Type DWord }
            }
            try {
                Write-Log '  Running Windows Disk Cleanup for upgrade leftovers - this can take a while...'
                $proc = Start-Process -FilePath $cm -ArgumentList '/sagerun:777' -WindowStyle Hidden -PassThru
                while (-not $proc.HasExited) { Start-Sleep -Milliseconds 500; Invoke-UiPump }
            }
            finally {
                foreach ($h in $script:UpgradeCacheHandlers) { Remove-ItemProperty -Path "$vc\$h" -Name 'StateFlags0777' -ErrorAction SilentlyContinue }
            }
            $after = [double](Get-CimInstance Win32_LogicalDisk -Filter $filter).FreeSpace
            [math]::Max(0, $after - $before)
        }

    # ---------------- Browsers ----------------
    New-Category -Key 'BrowserCache' -Name 'Browser caches' -Group 'Browsers' `
        -Description 'Cached web data for Chrome, Edge, Brave, Vivaldi, Opera, Firefox and more. Logins, history, cookies and bookmarks are untouched.' `
        -Processes @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'firefox', 'librewolf', 'waterfox') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                foreach ($b in @('Google\Chrome', 'Google\Chrome Beta', 'Microsoft\Edge', 'Microsoft\Edge Beta',
                                 'BraveSoftware\Brave-Browser', 'Vivaldi', 'Chromium')) {
                    foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) { "$p\AppData\Local\$b\User Data\*\$sub" }
                }
                "$p\AppData\Local\Opera Software\Opera Stable\Cache"
                "$p\AppData\Local\Opera Software\Opera GX Stable\Cache"
                "$p\AppData\Local\Mozilla\Firefox\Profiles\*\cache2"
                "$p\AppData\Local\librewolf\Profiles\*\cache2"
                "$p\AppData\Local\Waterfox\Profiles\*\cache2"
                "$p\AppData\Local\Microsoft\Windows\INetCache\IE"
            }
        }

    # ---------------- Apps ----------------
    New-Category -Key 'Discord' -Name 'Discord cache' -Group 'Apps' `
        -Description 'Discord image/code/GPU cache. Messages and login are not affected.' `
        -Processes @('Discord', 'DiscordPTB', 'DiscordCanary') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                foreach ($d in @('discord', 'discordptb', 'discordcanary')) {
                    foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) { "$p\AppData\Roaming\$d\$sub" }
                }
            }
        }

    New-Category -Key 'Spotify' -Name 'Spotify streaming cache' -Group 'Apps' `
        -Description 'Spotify streaming cache. Downloaded (offline) songs are NOT touched.' `
        -Processes @('Spotify') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                "$p\AppData\Local\Spotify\Data"
                "$p\AppData\Local\Spotify\Browser\Cache"
                "$p\AppData\Local\Packages\SpotifyAB.SpotifyMusic_*\LocalCache\Spotify\Data"
            }
        }

    New-Category -Key 'Teams' -Name 'Microsoft Teams cache' -Group 'Apps' `
        -Description 'Classic and new Teams web caches. Sign-in and chats are not affected.' `
        -Processes @('Teams', 'ms-teams') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'application cache\cache', 'tmp')) { "$p\AppData\Roaming\Microsoft\Teams\$sub" }
                foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
                    "$p\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\$sub"
                }
            }
        }

    New-Category -Key 'Slack' -Name 'Slack cache' -Group 'Apps' `
        -Description 'Slack web caches. Sign-in and messages are not affected.' `
        -Processes @('slack') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
                    "$p\AppData\Roaming\Slack\$sub"
                    "$p\AppData\Local\Packages\91750D7E.Slack_*\LocalCache\Roaming\Slack\$sub"
                }
            }
        }

    New-Category -Key 'Zoom' -Name 'Zoom logs' -Group 'Apps' -MinAgeHours 24 `
        -Description 'Zoom log files. Settings and recordings are not affected.' `
        -Processes @('Zoom') `
        -Paths { foreach ($p in Get-UserProfiles) { "$p\AppData\Roaming\Zoom\logs" } }

    New-Category -Key 'VSCode' -Name 'VS Code caches' -Group 'Apps' `
        -Description 'Visual Studio Code caches and old logs. Settings and extensions are not affected.' `
        -Processes @('Code') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                foreach ($sub in @('Cache', 'CachedData', 'Code Cache', 'GPUCache', 'CachedExtensionVSIXs', 'logs')) { "$p\AppData\Roaming\Code\$sub" }
            }
        }

    New-Category -Key 'GameLaunchers' -Name 'Game launcher caches' -Group 'Apps' `
        -Description 'Steam web/HTTP cache, crash dumps and logs; Epic Games Launcher web cache. Games and saves are not affected.' `
        -Processes @('steam', 'steamwebhelper', 'EpicGamesLauncher') `
        -Paths {
            foreach ($r in (Get-SteamLibraries).Roots) {
                "$r\appcache\httpcache"
                "$r\dumps"
                "$r\logs"
            }
            foreach ($p in Get-UserProfiles) {
                "$p\AppData\Local\Steam\htmlcache"
                "$p\AppData\Local\EpicGamesLauncher\Saved\webcache*"
                "$p\AppData\Local\EpicGamesLauncher\Saved\Logs"
            }
        }

    New-Category -Key 'AdobeCache' -Name 'Adobe media cache' -Group 'Apps' -Default $false `
        -Description 'Premiere/After Effects/Media Encoder media cache. Rebuilt when projects are opened (can take a while).' `
        -Processes @('Adobe Premiere Pro', 'AfterFX', 'Adobe Media Encoder') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                "$p\AppData\Roaming\Adobe\Common\Media Cache Files"
                "$p\AppData\Roaming\Adobe\Common\Media Cache"
            }
        }

    New-Category -Key 'DevCaches' -Name 'Developer package caches' -Group 'Apps' -Default $false `
        -Description 'npm, yarn, pip, NuGet, Gradle, Maven, Go and Cargo download caches. Re-downloaded on the next build.' `
        -Processes @('node', 'java', 'dotnet', 'devenv') `
        -Paths {
            foreach ($p in Get-UserProfiles) {
                "$p\AppData\Local\npm-cache"
                "$p\AppData\Roaming\npm-cache"
                "$p\AppData\Local\Yarn\Cache"
                "$p\AppData\Local\pip\Cache"
                "$p\AppData\Local\NuGet\v3-cache"
                "$p\AppData\Local\NuGet\plugins-cache"
                "$p\.nuget\packages"
                "$p\.gradle\caches"
                "$p\.m2\repository"
                "$p\AppData\Local\go-build"
                "$p\.cargo\registry\cache"
            }
        }
)

function Get-TargetFiles {
    param($Cat)
    $cutoff = $null
    if ($Cat.MinAgeHours -gt 0) { $cutoff = (Get-Date).AddHours(-$Cat.MinAgeHours) }
    foreach ($item in Resolve-Targets (& $Cat.Paths)) {
        if ($item.PSIsContainer) { $files = Get-TreeSafe $item.FullName -Files } else { $files = @($item) }
        foreach ($f in $files) {
            if ($f.Name -eq 'desktop.ini') { continue }
            if ($cutoff -and $f.LastWriteTime -gt $cutoff) { continue }
            $f
        }
    }
}

function Get-CategorySize {
    param($Cat)
    if ($Cat.Size) { return [double](& $Cat.Size) }
    $sum = 0
    if ($Cat.MinAgeHours -eq 0) {
        # no age filter - use the fast native walker (same junction rules)
        Initialize-Native
        foreach ($i in Resolve-Targets (& $Cat.Paths)) {
            if ($i.PSIsContainer) { $sum += [CleanIT.Disk]::FolderSize($i.FullName) } else { $sum += $i.Length }
        }
        return [double]$sum
    }
    foreach ($f in Get-TargetFiles $Cat) { $sum += $f.Length }
    [double]$sum
}

function Remove-EmptyFolders {
    param($Cat)
    $cutoff = $null
    if ($Cat.MinAgeHours -gt 0) { $cutoff = (Get-Date).AddHours(-$Cat.MinAgeHours) }
    foreach ($root in (Resolve-Targets (& $Cat.Paths) | Where-Object { $_.PSIsContainer })) {
        $dirs = @(Get-TreeSafe $root.FullName -Directories) | Sort-Object { $_.FullName.Length } -Descending
        foreach ($d in $dirs) {
            if ($cutoff -and $d.LastWriteTime -gt $cutoff) { continue }
            if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-RunningForCategory {
    param($Cat)
    if (-not $Cat.Processes) { return @() }
    @(Get-Process -Name $Cat.Processes -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
}

function Invoke-CategoryClean {
    param($Cat)
    Write-Log "Cleaning: $($Cat.Name)"
    $running = Get-RunningForCategory $Cat
    if ($running.Count) { Write-Log ('  Close these for a full clean: ' + ($running -join ', ')) 'WARN' }
    if ($Cat.Before) { & $Cat.Before | Out-Null }
    $freed = 0
    try {
        if ($Cat.CleanBlock) {
            $freed = [double](& $Cat.CleanBlock | Select-Object -Last 1)
        }
        else {
            $deleted = 0; $skipped = 0; $i = 0
            foreach ($f in @(Get-TargetFiles $Cat)) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $freed += $f.Length; $deleted++
                }
                catch { $skipped++ }
                $i++
                if (($i % 250) -eq 0) { Invoke-UiPump; if (Test-BgCancel) { break } }
            }
            Remove-EmptyFolders $Cat
            Write-Log ('  {0} files removed, {1} skipped (in use or protected)' -f $deleted, $skipped)
        }
    }
    finally {
        if ($Cat.After) { & $Cat.After | Out-Null }
    }
    Write-Log ('  Freed {0}' -f (Format-Size $freed)) 'OK'
    [double]$freed
}

function Get-SelectedCategories {
    param([string[]]$Keys, [switch]$Deep)
    if ($Keys) {
        $k = $Keys | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $script:CategoryDefs | Where-Object { $k -contains $_.Key }
    }
    else {
        $script:CategoryDefs | Where-Object { $_.Default -or ($Deep -and $_.Deep) }
    }
}

function Invoke-JunkScan {
    param([string[]]$Keys)
    $cats = @($script:CategoryDefs | Where-Object { $Keys -contains $_.Key })
    $i = 0
    foreach ($c in $cats) {
        if (Test-BgCancel) { break }
        Set-BgProgress ([int](100 * $i / [math]::Max(1, $cats.Count))) "Scanning $($c.Name)"
        [pscustomobject]@{ Key = $c.Key; Size = (Get-CategorySize $c); Running = (Get-RunningForCategory $c) -join ', ' }
        $i++
    }
}

function Invoke-CleanRun {
    param([string[]]$Keys, [string]$Source = 'Manual', [switch]$RestorePoint)
    $cats = @($script:CategoryDefs | Where-Object { $Keys -contains $_.Key })
    if ($RestorePoint) { [void](New-CleanITRestorePoint 'Before cleanup') }
    $grand = 0
    $details = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($c in $cats) {
        if (Test-BgCancel) { Write-Log 'Cleaning cancelled.' 'WARN'; break }
        Set-BgProgress ([int](100 * $i / [math]::Max(1, $cats.Count))) "Cleaning $($c.Name)"
        $f = [double](Invoke-CategoryClean $c | Select-Object -Last 1)
        $grand += $f
        $details.Add([pscustomobject]@{ Key = $c.Key; Freed = $f })
        $i++
    }
    Write-Log "All done. Total freed: $(Format-Size $grand)" 'OK'
    Add-HistoryEntry $Source $grand $details.ToArray()
    [pscustomobject]@{ Freed = [double]$grand; Details = $details.ToArray() }
}

# ---------------------------------------------------------------------------
# Startup manager: Run keys, Startup folders, logon/boot scheduled tasks, auto-start services
# Every change is recorded in State\startup.json so "Undo all" can put things back.
# ---------------------------------------------------------------------------
function Get-StartupState {
    $j = Read-JsonFile (Get-StatePath 'startup')
    $o = [pscustomobject]@{ Approved = @(); Tasks = @(); Services = @() }
    if ($j) {
        $o.Approved = @($j.Approved | Where-Object { $_ })
        $o.Tasks    = @($j.Tasks | Where-Object { $_ })
        $o.Services = @($j.Services | Where-Object { $_ })
    }
    $o
}

function Save-StartupState { param($State) Write-JsonFile (Get-StatePath 'startup') $State }

function Test-StartupEnabled {
    param([string]$ApprovedKey, [string]$ValueName)
    $v = (Get-ItemProperty -Path $ApprovedKey -Name $ValueName -ErrorAction SilentlyContinue).$ValueName
    if ($null -eq $v -or $v.Count -lt 1) { return $true }
    return (($v[0] -band 1) -eq 0)   # even first byte = enabled, odd = disabled
}

function Get-StartupItems {
    param([switch]$IncludeMicrosoft, [switch]$Quick)
    $base = 'Software\Microsoft\Windows\CurrentVersion'
    $regSources = @(
        @{ Run = "HKCU:\$base\Run";  Approved = "HKCU:\$base\Explorer\StartupApproved\Run";   Scope = 'Run key (you)' },
        @{ Run = "HKLM:\$base\Run";  Approved = "HKLM:\$base\Explorer\StartupApproved\Run";   Scope = 'Run key (all users)' },
        @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
           Approved = "HKLM:\$base\Explorer\StartupApproved\Run32"; Scope = 'Run key (all users, 32-bit)' }
    )
    foreach ($s in $regSources) {
        $key = Get-Item -Path $s.Run -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        foreach ($name in $key.GetValueNames()) {
            if (-not $name) { continue }
            $cmd = [string]$key.GetValue($name)
            $exe = ''; $pub = ''
            if (-not $Quick) { $exe = Get-ExePath $cmd; $pub = Get-FilePublisher $exe }
            [pscustomobject]@{
                Kind = 'Run'; Name = $name; Command = $cmd; Location = $s.Scope; Exe = $exe; Publisher = $pub
                Microsoft = ($pub -match '^Microsoft'); Approved = $s.Approved; ValueName = $name
                Enabled = (Test-StartupEnabled $s.Approved $name); Status = ''
            }
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $folderSources = @(
        @{ Path = [Environment]::GetFolderPath('Startup');       Approved = "HKCU:\$base\Explorer\StartupApproved\StartupFolder"; Scope = 'Startup folder (you)' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$base\Explorer\StartupApproved\StartupFolder"; Scope = 'Startup folder (all)' }
    )
    foreach ($s in $folderSources) {
        if (-not $s.Path) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $s.Path -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.Name -eq 'desktop.ini') { continue }
            $cmd = $f.FullName
            if ($f.Extension -eq '.lnk') { try { $cmd = $shell.CreateShortcut($f.FullName).TargetPath } catch {} }
            $pub = ''; if (-not $Quick) { $pub = Get-FilePublisher $cmd }
            [pscustomobject]@{
                Kind = 'Folder'; Name = $f.BaseName; Command = $cmd; Location = $s.Scope; Exe = $cmd; Publisher = $pub
                Microsoft = ($pub -match '^Microsoft'); Approved = $s.Approved; ValueName = $f.Name
                Enabled = (Test-StartupEnabled $s.Approved $f.Name); Status = ''
            }
        }
    }
    if ($Quick) { return }

    # Scheduled tasks that start at logon or boot
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($t.TaskName -like 'CleanIT*') { continue }
        $isMsPath = $t.TaskPath -like '\Microsoft\*'
        if ($isMsPath -and -not $IncludeMicrosoft) { continue }
        $trig = @($t.Triggers | Where-Object { $_ -and $_.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger') })
        if (-not $trig.Count) { continue }
        $act = @($t.Actions | Where-Object { $_.Execute }) | Select-Object -First 1
        $cmd = ''; $exe = ''
        if ($act) { $cmd = ('{0} {1}' -f $act.Execute, $act.Arguments).Trim(); $exe = Get-ExePath $act.Execute }
        $pub = Get-FilePublisher $exe
        $when = ($trig | ForEach-Object { if ($_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger') { 'boot' } else { 'logon' } } | Sort-Object -Unique) -join '+'
        [pscustomobject]@{
            Kind = 'Task'; Name = $t.TaskName; Command = $cmd; Location = "Task at $when ($($t.TaskPath))"; Exe = $exe
            Publisher = $pub; Microsoft = ($isMsPath -or $pub -match '^Microsoft'); TaskPath = $t.TaskPath
            Enabled = ($t.State -ne 'Disabled'); Status = [string]$t.State
        }
    }

    # Services that start automatically (plus ones we switched to manual, so they can be switched back)
    $state = Get-StartupState
    $changed = @{}
    foreach ($s in $state.Services) { $changed[$s.Name] = $s.Original }
    foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        $isAuto = $svc.StartMode -eq 'Auto'
        if (-not $isAuto -and -not $changed.ContainsKey($svc.Name)) { continue }
        $exe = Get-ExePath $svc.PathName
        $inWindows = $exe -and $exe.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)
        if ($inWindows -and -not $IncludeMicrosoft) { continue }
        if ($inWindows) { $pub = 'Microsoft Windows' } else { $pub = Get-FilePublisher $exe }
        $isMs = $inWindows -or $pub -match '^Microsoft'
        if ($isMs -and -not $IncludeMicrosoft) { continue }
        $delayed = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)" -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart -eq 1
        $status = [string]$svc.StartMode
        if ($isAuto) { $status = 'Automatic'; if ($delayed) { $status = 'Automatic (delayed)' } }
        [pscustomobject]@{
            Kind = 'Service'; Name = $svc.DisplayName; Command = $svc.PathName; Location = "Service ($($svc.Name), $($svc.State))"
            Exe = $exe; Publisher = $pub; Microsoft = $isMs; ServiceName = $svc.Name; Delayed = $delayed
            Enabled = $isAuto; Status = $status
        }
    }
}

function Set-ServiceStartMode {
    param([string]$Name, [ValidateSet('auto', 'delayed-auto', 'demand', 'disabled')][string]$Mode)
    $out = & sc.exe config $Name start= $Mode 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($out | Out-String).Trim()) }
}

function Set-StartupItemState {
    param($Item, [bool]$Enable, [string]$ServiceOffMode = 'demand')
    $state = Get-StartupState
    switch ($Item.Kind) {
        { $_ -in @('Run', 'Folder') } {
            if (-not (Test-Path $Item.Approved)) { New-Item -Path $Item.Approved -Force | Out-Null }
            $bytes = New-Object byte[] 12
            if ($Enable) { $bytes[0] = 2 }
            else { $bytes[0] = 3; [BitConverter]::GetBytes((Get-Date).ToFileTimeUtc()).CopyTo($bytes, 4) }
            Set-ItemProperty -Path $Item.Approved -Name $Item.ValueName -Value $bytes -Type Binary
            $state.Approved = @($state.Approved | Where-Object { -not ($_.Approved -eq $Item.Approved -and $_.ValueName -eq $Item.ValueName) })
            if (-not $Enable) { $state.Approved += [pscustomobject]@{ Approved = $Item.Approved; ValueName = $Item.ValueName; Name = $Item.Name } }
        }
        'Task' {
            if ($Enable) { Enable-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.Name -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.Name -ErrorAction Stop | Out-Null }
            $state.Tasks = @($state.Tasks | Where-Object { -not ($_.TaskPath -eq $Item.TaskPath -and $_.TaskName -eq $Item.Name) })
            if (-not $Enable) { $state.Tasks += [pscustomobject]@{ TaskPath = $Item.TaskPath; TaskName = $Item.Name } }
        }
        'Service' {
            $prev = @($state.Services | Where-Object { $_.Name -eq $Item.ServiceName }) | Select-Object -First 1
            if ($Enable) {
                $mode = 'auto'
                if ($prev) { $mode = $prev.Original }
                Set-ServiceStartMode $Item.ServiceName $mode
                $state.Services = @($state.Services | Where-Object { $_.Name -ne $Item.ServiceName })
            }
            else {
                if (-not $prev) {
                    $orig = 'auto'; if ($Item.Delayed) { $orig = 'delayed-auto' }
                    $state.Services += [pscustomobject]@{ Name = $Item.ServiceName; DisplayName = $Item.Name; Original = $orig }
                }
                Set-ServiceStartMode $Item.ServiceName $ServiceOffMode
            }
        }
    }
    Save-StartupState $state
}

function Undo-AllStartupChanges {
    $state = Get-StartupState
    $n = 0
    foreach ($a in $state.Approved) {
        $item = [pscustomobject]@{ Kind = 'Run'; Approved = $a.Approved; ValueName = $a.ValueName; Name = $a.Name }
        try { Set-StartupItemState $item $true; Write-Log "Startup: re-enabled $($a.Name)" 'OK'; $n++ } catch { Write-Log "Startup: could not re-enable $($a.Name): $_" 'WARN' }
    }
    foreach ($t in $state.Tasks) {
        $item = [pscustomobject]@{ Kind = 'Task'; TaskPath = $t.TaskPath; Name = $t.TaskName }
        try { Set-StartupItemState $item $true; Write-Log "Startup: re-enabled task $($t.TaskName)" 'OK'; $n++ } catch { Write-Log "Startup: could not re-enable task $($t.TaskName): $_" 'WARN' }
    }
    foreach ($s in $state.Services) {
        $item = [pscustomobject]@{ Kind = 'Service'; ServiceName = $s.Name; Name = $s.DisplayName }
        try { Set-StartupItemState $item $true; Write-Log "Startup: service $($s.DisplayName) back to $($s.Original)" 'OK'; $n++ } catch { Write-Log "Startup: could not restore service $($s.Name): $_" 'WARN' }
    }
    Write-Log "Startup: $n change(s) undone." 'OK'
}

# ---------------------------------------------------------------------------
# Bloatware (Appx packages)
# ---------------------------------------------------------------------------
# Never offered for removal - Windows breaks or the user loses the Store / winget / security UI.
$script:AppxBlocklist = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
    'Microsoft.Windows.*', 'MicrosoftWindows.Client.CBS', 'MicrosoftWindows.Client.Core', 'MicrosoftWindows.Client.FileExp',
    'MicrosoftWindows.Client.LKG', 'MicrosoftWindows.Client.AIX', 'MicrosoftWindows.Client.OOBE', 'MicrosoftWindows.UndockedDevKit',
    'Microsoft.UI.Xaml*', 'Microsoft.VCLibs*', 'Microsoft.NET.*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.Services.Store.Engagement',
    'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.LockApp', 'Microsoft.Winget.*', 'Microsoft.CredDialogHost',
    'Microsoft.ECApp', 'Microsoft.Win32WebViewHost', 'Microsoft.WidgetsPlatformRuntime', 'Microsoft.StartExperiencesApp',
    'Microsoft.*Extension*', 'Microsoft.*Extensions', 'Microsoft.ApplicationCompatibilityEnhancements', 'Microsoft.MicrosoftEdge*',
    'Microsoft.SecureAssessmentBrowser', 'Microsoft.XboxIdentityProvider', 'Microsoft.GamingServices', 'Microsoft.OneDriveSync',
    'Microsoft.LanguageExperiencePack*', 'Microsoft.Ink.Handwriting*', 'Microsoft.WindowsAppRuntime.*', 'Microsoft.BioEnrollment',
    'Microsoft.AsyncTextService', 'Microsoft.Copilot.Runtime*', 'NcsiUwpApp', 'windows.immersivecontrolpanel', 'Windows.*',
    'NVIDIACorp.*', 'RealtekSemiconductorCorp.*', 'AppUp.Intel*', 'AdvancedMicroDevicesInc*', 'DolbyLaboratories.*',
    'WavesAudio.*', 'Microsoft.MicrosoftEdgeDevToolsClient', 'Microsoft.WindowsTerminal', 'MicrosoftCorporationII.WinAppRuntime*',
    'Microsoft.HEVCVideoExtension', 'Microsoft.WebMediaExtensions'
)

# Pattern, friendly name, pre-tick (1 = recommended to remove)
$script:BloatRules = @(
    @('Microsoft.BingNews', 'Microsoft News', 1), @('Microsoft.BingWeather', 'Weather', 1),
    @('Microsoft.BingFinance', 'Money', 1), @('Microsoft.BingSports', 'Sports', 1), @('Microsoft.BingTravel', 'Travel', 1),
    @('Microsoft.BingFoodAndDrink', 'Food & Drink', 1), @('Microsoft.BingHealthAndFitness', 'Health & Fitness', 1),
    @('Microsoft.BingSearch', 'Bing Search app', 1), @('Microsoft.GetHelp', 'Get Help', 1), @('Microsoft.Getstarted', 'Tips', 1),
    @('Microsoft.MicrosoftSolitaireCollection', 'Solitaire Collection (ads)', 1), @('Microsoft.MicrosoftOfficeHub', 'Microsoft 365 hub', 1),
    @('Microsoft.People', 'People', 1), @('Microsoft.WindowsFeedbackHub', 'Feedback Hub', 1), @('Clipchamp.Clipchamp', 'Clipchamp', 1),
    @('Microsoft.PowerAutomateDesktop', 'Power Automate', 1), @('MicrosoftCorporationII.MicrosoftFamily', 'Microsoft Family', 1),
    @('Microsoft.549981C3F5F10', 'Cortana', 1), @('Microsoft.MixedReality.Portal', 'Mixed Reality Portal', 1),
    @('Microsoft.SkypeApp', 'Skype (retired)', 1), @('Microsoft.WindowsMaps', 'Maps', 1), @('Microsoft.3DBuilder', '3D Builder', 1),
    @('Microsoft.Microsoft3DViewer', '3D Viewer', 1), @('Microsoft.MSPaint', 'Paint 3D', 1), @('Microsoft.Print3D', 'Print 3D', 1),
    @('Microsoft.Messaging', 'Messaging', 1), @('Microsoft.OneConnect', 'Mobile Plans', 1), @('Microsoft.Wallet', 'Wallet', 1),
    @('Microsoft.ZuneVideo', 'Movies & TV', 1), @('Microsoft.Office.Sway', 'Sway', 1), @('Microsoft.WindowsCommunicationsApps', 'Mail & Calendar (retired)', 1),
    @('Microsoft.Windows.DevHome', 'Dev Home (retired)', 1), @('7EE7776C.LinkedInforWindows', 'LinkedIn', 1),
    @('king.com.*', 'King game (Candy Crush etc.)', 1), @('*Disney*', 'Disney+ promo', 1), @('*Facebook*', 'Facebook promo', 1),
    @('BytedancePte.Ltd.TikTok', 'TikTok promo', 1), @('*McAfee*', 'McAfee (OEM trial)', 1), @('*Norton*', 'Norton (OEM trial)', 1),
    @('*ExpressVPN*', 'ExpressVPN promo', 1), @('*Booking*', 'Booking.com promo', 1),
    @('MicrosoftTeams', 'Teams (personal chat)', 0), @('Microsoft.Todos', 'Microsoft To Do', 0), @('Microsoft.Copilot', 'Copilot', 0),
    @('Microsoft.OutlookForWindows', 'Outlook (new)', 0), @('Microsoft.YourPhone', 'Phone Link', 0), @('Microsoft.WindowsSoundRecorder', 'Sound Recorder', 0),
    @('Microsoft.XboxApp', 'Xbox Console Companion', 0), @('Microsoft.GamingApp', 'Xbox app', 0), @('Microsoft.XboxGamingOverlay', 'Xbox Game Bar', 0),
    @('Microsoft.XboxSpeechToTextOverlay', 'Xbox speech overlay', 0), @('Microsoft.Xbox.TCUI', 'Xbox TCUI (some games need it)', 0),
    @('Microsoft.XboxGameOverlay', 'Xbox overlay', 0), @('Microsoft.MicrosoftStickyNotes', 'Sticky Notes', 0), @('Microsoft.WindowsCamera', 'Camera', 0),
    @('Microsoft.WindowsAlarms', 'Clock', 0), @('Microsoft.Whiteboard', 'Whiteboard', 0), @('MicrosoftWindows.Client.WebExperience', 'Widgets', 0),
    @('MicrosoftWindows.CrossDevice', 'Cross Device Experience', 0), @('SpotifyAB.SpotifyMusic', 'Spotify', 0), @('*Netflix*', 'Netflix', 0),
    @('AmazonVideo.PrimeVideo', 'Prime Video', 0), @('AD2F1837.*', 'HP app', 0), @('E046963F.*', 'Lenovo app', 0), @('DellInc.*', 'Dell app', 0),
    @('B9ECED6F.*', 'ASUS app', 0), @('AcerIncorporated.*', 'Acer app', 0), @('Microsoft.ZuneMusic', 'Media Player', 0),
    @('Microsoft.Windows.Photos', 'Photos', 0), @('Microsoft.Paint', 'Paint', 0), @('Microsoft.WindowsCalculator', 'Calculator', 0),
    @('Microsoft.WindowsNotepad', 'Notepad', 0), @('Microsoft.ScreenSketch', 'Snipping Tool', 0)
)

function Test-AppxBlocked {
    param([string]$Name)
    if ($Name -like 'MicrosoftWindows.Client.WebExperience' -or $Name -like 'MicrosoftWindows.CrossDevice' -or $Name -eq 'Microsoft.Windows.Photos' -or $Name -eq 'Microsoft.Windows.DevHome') { return $false }
    foreach ($p in $script:AppxBlocklist) { if ($Name -like $p) { return $true } }
    $false
}

function Get-BloatRule {
    param([string]$Name)
    foreach ($r in $script:BloatRules) { if ($Name -like $r[0]) { return $r } }
    $null
}

function Get-AppxInventory {
    $prov = @{}
    foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) { $prov[$p.DisplayName] = $p.PackageName }
    $byName = @{}
    $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    if (-not $pkgs.Count) { $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue) }   # not elevated: current user only
    foreach ($p in $pkgs) {
        if ($p.IsFramework -or $p.NonRemovable -or $p.IsResourcePackage -or $p.SignatureKind -eq 'System') { continue }
        if (Test-AppxBlocked $p.Name) { continue }
        if (-not $byName.ContainsKey($p.Name)) {
            $byName[$p.Name] = [pscustomobject]@{ Name = $p.Name; Family = $p.PackageFamilyName; Version = [string]$p.Version
                                                Publisher = $p.Publisher; FullNames = New-Object System.Collections.Generic.List[string] }
        }
        $byName[$p.Name].FullNames.Add($p.PackageFullName)
    }
    foreach ($n in $prov.Keys) {
        if ($byName.ContainsKey($n) -or (Test-AppxBlocked $n)) { continue }
        $byName[$n] = [pscustomobject]@{ Name = $n; Family = ''; Version = ''; Publisher = ''; FullNames = New-Object System.Collections.Generic.List[string] }
    }
    foreach ($a in $byName.Values) {
        $rule = Get-BloatRule $a.Name
        $label = $a.Name; $rec = $false
        if ($rule) { $label = $rule[1]; $rec = [bool]$rule[2] }
        $pubName = ''
        if ($a.Publisher -match 'O=([^,]+)') { $pubName = $Matches[1] } elseif ($a.Publisher -match 'CN=([^,]+)') { $pubName = $Matches[1] }
        if ($pubName -match '^[0-9A-Fa-f]{8}-') { $pubName = '' }   # Store-signed: publisher is just a GUID
        [pscustomobject]@{
            Label = $label; Name = $a.Name; Family = $a.Family; Version = $a.Version; Publisher = $pubName
            FullNames = $a.FullNames.ToArray(); Provisioned = $prov[$a.Name]; Installed = ($a.FullNames.Count -gt 0)
            Recommended = $rec; Known = [bool]$rule
        }
    }
}

function Remove-BloatApp {
    param($App, [switch]$Deprovision)
    $ok = $true
    foreach ($fn in $App.FullNames) {
        try { Remove-AppxPackage -Package $fn -AllUsers -ErrorAction Stop; Write-Log "  removed $fn" }
        catch {
            try { Remove-AppxPackage -Package $fn -ErrorAction Stop; Write-Log "  removed $fn (current user)" }
            catch { Write-Log "  could not remove ${fn}: $($_.Exception.Message)" 'WARN'; $ok = $false }
        }
    }
    if ($Deprovision -and $App.Provisioned) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $App.Provisioned -ErrorAction Stop | Out-Null; Write-Log "  de-provisioned $($App.Name) (won't come back for new users)" }
        catch { Write-Log "  could not de-provision $($App.Name): $($_.Exception.Message)" 'WARN' }
    }
    $file = Get-StatePath 'removed-apps'
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Read-JsonFile $file @())) { if ($e) { $list.Add($e) } }
    $list.Add([pscustomobject]@{ Name = $App.Name; Label = $App.Label; Family = $App.Family; Date = (Get-Date).ToString('s') })
    Write-JsonFile $file $list.ToArray()
    $ok
}

function Get-RemovedApps { @(Read-JsonFile (Get-StatePath 'removed-apps') @()) | Where-Object { $_ } }

# ---------------------------------------------------------------------------
# Programs: uninstall + leftover finder
# ---------------------------------------------------------------------------
function Get-InstalledPrograms {
    $roots = @(
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'All users' },
        @{ P = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'All users (32-bit)' },
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'You' }
    )
    $seen = @{}
    foreach ($r in $roots) {
        foreach ($k in @(Get-ChildItem -Path $r.P -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $v -or -not $v.DisplayName) { continue }
            if ($v.SystemComponent -eq 1 -or $v.ParentKeyName -or [string]$v.ReleaseType -match 'Update|Hotfix') { continue }
            if (-not $v.UninstallString -and -not $v.QuietUninstallString) { continue }
            $id = '{0}|{1}' -f $v.DisplayName, $v.DisplayVersion
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $date = $null
            if ([string]$v.InstallDate -match '^\d{8}$') { try { $date = [datetime]::ParseExact($v.InstallDate, 'yyyyMMdd', $null) } catch {} }
            [pscustomobject]@{
                Name = ([string]$v.DisplayName).Trim(); Publisher = ([string]$v.Publisher).Trim(); Version = [string]$v.DisplayVersion
                SizeBytes = [double]$v.EstimatedSize * 1KB; InstallDate = $date; Scope = $r.S
                RegKey = $k.Name; UninstallString = [string]$v.UninstallString; QuietUninstallString = [string]$v.QuietUninstallString
                InstallLocation = ([string]$v.InstallLocation).Trim('"', ' ', '\'); WindowsInstaller = ($v.WindowsInstaller -eq 1)
            }
        }
    }
}

function Start-ProgramUninstall {
    param($Program)
    $cmd = $Program.UninstallString
    if (-not $cmd) { $cmd = $Program.QuietUninstallString }
    Write-Log "Starting uninstaller for $($Program.Name)..."
    if ($cmd -match 'msiexec' -and $cmd -match '(\{[0-9A-Fa-f\-]{36}\})') {
        return (Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList "/x $($Matches[1])" -PassThru)
    }
    $parts = Split-CommandLine $cmd
    if ($parts[0] -and (Test-Path -LiteralPath $parts[0])) {
        if ($parts[1]) { return (Start-Process -FilePath $parts[0] -ArgumentList $parts[1] -PassThru) }
        return (Start-Process -FilePath $parts[0] -PassThru)
    }
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/c `"$cmd`"" -WindowStyle Hidden -PassThru
}

function Get-NameKey {
    param([string]$Text)
    $t = $Text.ToLowerInvariant()
    $t = $t -replace '\([^)]*\)', ''
    $t = $t -replace '\b(x64|x86|amd64|win64|win32)\b', ''
    $t = $t -replace '\bv?\d+(\.\d+)+\b', ''
    ($t -replace '[^a-z0-9]', '')
}

# Folder/key names that are shared by many products - never suggested by a fuzzy match.
$script:LeftoverGeneric = @('microsoft', 'windows', 'commonfiles', 'windowsapps', 'packages', 'programs', 'temp', 'installer',
    'system32', 'intel', 'nvidia', 'nvidiacorporation', 'amd', 'realtek', 'dell', 'hp', 'lenovo', 'asus', 'adobe', 'google',
    'mozilla', 'apple', 'oracle', 'java', 'python', 'nodejs', 'cache', 'logs', 'data', 'app', 'apps', 'tools', 'classes',
    'policies', 'wow6432node', 'clients', 'software', 'microsoftcorporation', 'windowspowershell', 'internetexplorer', 'msbuild',
    'referenceassemblies', 'dotnet', 'windowsdefender', 'windowsmail', 'windowsmediaplayer', 'windowsnt', 'modifiablewindowsapps',
    'uninstallinformation', 'crashdumps', 'd3dscache', 'publishers', 'policydefinitions', 'usoshared', 'usoprivate')

function Find-ProgramLeftovers {
    param($Program, [object[]]$OtherPrograms)
    # Matching is deliberately strict: exact product names only (plus "<name>Setup", "<name>Data"...).
    # Fuzzy/substring matching was tested and hit unrelated products (e.g. GameInput -> Microsoft\Input).
    $appKey = Get-NameKey $Program.Name
    if ($appKey.Length -lt 3) { return }
    $pubKey = ''
    if ($Program.Publisher) { $pubKey = Get-NameKey ($Program.Publisher -replace '(?i)\b(inc|llc|ltd|gmbh|corp|corporation|co|limited|aps|ag|ab|s\.a\.)\b\.?', '') }
    $firstWord = Get-NameKey (($Program.Name -split '\s+')[0])
    $appKeys = New-Object System.Collections.Generic.List[string]
    $appKeys.Add($appKey)
    foreach ($prefix in @($pubKey, $firstWord)) {
        if ($prefix -and $appKey.StartsWith($prefix) -and ($appKey.Length - $prefix.Length) -ge 3) { $appKeys.Add($appKey.Substring($prefix.Length)) }
    }
    $parentKeys = @(@($pubKey, $firstWord) | Where-Object { $_ -and $_.Length -ge 3 -and $_ -ne $appKey })
    # no "update"/"updater": EdgeUpdate, GoogleUpdate etc. are shared by other products
    $suffixes = @('setup', 'data', 'cache', 'logs', 'installer', 'service', 'launcher', 'x64', 'x86')
    $others = @($OtherPrograms | Where-Object { $_.InstallLocation -and $_.RegKey -ne $Program.RegKey } | ForEach-Object { $_.InstallLocation.TrimEnd('\') })
    $hits = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $matchName = {
        param([string]$Name, [bool]$UnderParent)
        $k = Get-NameKey $Name
        if (-not $k -or $script:LeftoverGeneric -contains $k) { return $false }
        $cands = @($appKey)
        if ($UnderParent) { $cands = $appKeys.ToArray() }   # "Edge" only counts inside the Microsoft folder
        foreach ($a in $cands) {
            if ($k -eq $a) { return $true }
            foreach ($s in $suffixes) { if ($k -eq ($a + $s)) { return $true } }
        }
        $false
    }
    $addFolder = {
        param([string]$Path, [string]$Reason)
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        if ($Path.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
        foreach ($o in $others) {
            if ($o -and ($o.StartsWith($Path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $o -eq $Path.TrimEnd('\'))) { return }
        }
        if (-not $seen.Add($Path)) { return }
        $size = 0; try { $size = [CleanIT.Disk]::FolderSize($Path) } catch {}
        $hits.Add([pscustomobject]@{ Type = 'Folder'; Path = $Path; Reason = $Reason; Size = [double]$size })
    }
    $addKey = {
        param([string]$Path, [string]$Reason)
        if (-not (Test-Path -LiteralPath "Registry::$Path")) { return }
        if (-not $seen.Add($Path)) { return }
        $hits.Add([pscustomobject]@{ Type = 'Registry'; Path = $Path; Reason = $Reason; Size = [double]0 })
    }

    Initialize-Native
    if ($Program.InstallLocation) { & $addFolder $Program.InstallLocation 'Install folder still exists' }

    $folderRoots = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) { if ($r) { $folderRoots.Add($r) } }
    foreach ($p in Get-UserProfiles) { foreach ($s in @('AppData\Roaming', 'AppData\Local', 'AppData\LocalLow', 'AppData\Local\Programs')) { $folderRoots.Add("$p\$s") } }
    foreach ($root in $folderRoots) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if (& $matchName $d.Name $false) { & $addFolder $d.FullName "Name matches in $root" ; continue }
            if ($parentKeys -contains (Get-NameKey $d.Name)) {
                foreach ($sub in @(Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    if (& $matchName $sub.Name $true) { & $addFolder $sub.FullName "Inside $($d.FullName)" }
                }
            }
        }
    }

    $regRoots = @('HKEY_LOCAL_MACHINE\SOFTWARE', 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node', 'HKEY_CURRENT_USER\Software')
    foreach ($root in $regRoots) {
        foreach ($k in @(Get-ChildItem -LiteralPath "Registry::$root" -ErrorAction SilentlyContinue)) {
            if (& $matchName $k.PSChildName $false) { & $addKey $k.Name 'Key name matches'; continue }
            if ($parentKeys -contains (Get-NameKey $k.PSChildName)) {
                foreach ($sub in @(Get-ChildItem -LiteralPath $k.PSPath -ErrorAction SilentlyContinue)) {
                    if (& $matchName $sub.PSChildName $true) { & $addKey $sub.Name "Under $($k.PSChildName)" }
                }
            }
        }
    }
    if ($Program.RegKey) { & $addKey $Program.RegKey 'Uninstall entry still present' }
    $hits.ToArray()
}

function Send-ToRecycleBin {
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    if (Test-Path -LiteralPath $Path -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
}

function Remove-Leftover {
    param($Hit)
    if ($Hit.Type -eq 'Folder') {
        Send-ToRecycleBin $Hit.Path
        Write-Log "  Folder sent to Recycle Bin: $($Hit.Path)" 'OK'
        $parent = Split-Path -Parent $Hit.Path
        if ($parent -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue | Select-Object -First 1) -and
            $parent -notin @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        $safe = ($Hit.Path -replace '[\\/:*?"<>|]', '_')
        if ($safe.Length -gt 120) { $safe = $safe.Substring($safe.Length - 120) }
        $backup = Join-Path $script:BackupDir ('{0:yyyyMMdd_HHmmss}_{1}.reg' -f (Get-Date), $safe)
        & reg.exe export $Hit.Path $backup /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not back up $($Hit.Path) - not removed." }
        Remove-Item -LiteralPath "Registry::$($Hit.Path)" -Recurse -Force -ErrorAction Stop
        Write-Log "  Registry key removed: $($Hit.Path) (backup: $backup)" 'OK'
    }
}

# ---------------------------------------------------------------------------
# Updates: winget apps + Windows Update (software and drivers) via the Windows Update Agent API
# ---------------------------------------------------------------------------
function Get-WingetPath {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    # SYSTEM (scheduled task) has no winget alias - use the App Installer package directly
    $cand = @(Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue) |
        Sort-Object { try { [version](($_.Directory.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    if ($cand) { return $cand.FullName }
    $null
}

function Test-Winget { [bool](Get-WingetPath) }

function Select-CleanWingetLines {
    process {
        $line = [string]$_
        if ($line -match '^\s*[-\\|/]\s*$') { return }        # spinner frames
        if ($line -match '[\u2580-\u259F]') { return }         # progress bars
        if ($line.Trim() -eq '') { return }
        $line
    }
}

function Invoke-Winget {
    param([string[]]$Arguments)
    $w = Get-WingetPath
    if (-not $w) { return }
    & $w @Arguments 2>&1 | ForEach-Object { [string]$_ } | Select-CleanWingetLines
}

function ConvertFrom-WingetTable {
    param([string[]]$Lines)
    $cols = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l -match '^-{10,}\s*$' -and $i -gt 0) {
            $cols = @([regex]::Matches($Lines[$i - 1], '\S+') | ForEach-Object { $_.Index })
            continue
        }
        if (-not $cols -or $cols.Count -lt 4 -or $l.Length -le $cols[2]) { continue }
        $cells = New-Object System.Collections.Generic.List[string]
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $start = $cols[$c]
            if ($start -ge $l.Length) { $cells.Add(''); continue }
            if ($c + 1 -lt $cols.Count) { $len = [math]::Min($cols[$c + 1], $l.Length) - $start; $cells.Add($l.Substring($start, [math]::Max(0, $len)).Trim()) }
            else { $cells.Add($l.Substring($start).Trim()) }
        }
        $id = $cells[1]
        if (-not $id -or $id -match '\s' -or $id.Contains([string][char]0x2026)) { continue }
        $src = ''; if ($cells.Count -ge 5) { $src = $cells[4] }
        [pscustomobject]@{ Name = $cells[0]; Id = $id; Version = $cells[2]; Available = $cells[3]; Source = $src }
    }
}

function Get-WingetUpgrades {
    $exclude = @((Get-Settings).WingetExclude)
    $lines = @(Invoke-Winget @('upgrade', '--include-unknown', '--accept-source-agreements'))
    $rows = @(ConvertFrom-WingetTable $lines)
    Set-LastCheck 'AppUpdates' @($rows | Where-Object { $exclude -notcontains $_.Id }).Count
    foreach ($r in $rows) { $r | Add-Member -NotePropertyName Excluded -NotePropertyValue ($exclude -contains $r.Id) -PassThru }
}

function Invoke-WingetUpgrade {
    param([string[]]$Ids)
    $ok = 0; $fail = 0
    foreach ($id in $Ids) {
        if (Test-BgCancel) { break }
        Write-Log "Updating $id ..."
        Invoke-Winget @('upgrade', '--id', $id, '--exact', '--silent', '--include-unknown',
                        '--accept-source-agreements', '--accept-package-agreements') | ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++; Write-Log "  winget exit code $LASTEXITCODE for $id" 'WARN' }
    }
    Write-Log "App updates finished: $ok updated, $fail failed." 'OK'
}

function Invoke-AllAppUpdates {
    if (-not (Test-Winget)) { Write-Log 'winget not found - install App Installer from the Microsoft Store.' 'WARN'; return }
    $ids = @(Get-WingetUpgrades | Where-Object { -not $_.Excluded } | ForEach-Object { $_.Id })
    if (-not $ids.Count) { Write-Log 'All apps are up to date.' 'OK'; return }
    Invoke-WingetUpgrade $ids
}

function Get-WindowsUpdateList {
    param([ValidateSet('Software', 'Driver')][string]$Type = 'Software')
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    Write-Log "Searching Windows Update for $($Type.ToLower()) updates (can take a few minutes)..."
    $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='$Type'")
    $out = foreach ($u in $res.Updates) {
        $kb = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
        [pscustomobject]@{
            Title = $u.Title; Id = $u.Identity.UpdateID; KB = $kb; Size = [double]$u.MaxDownloadSize
            Severity = [string]$u.MsrcSeverity; NeedsInput = [bool]$u.InstallationBehavior.CanRequestUserInput
            Reboot = ($u.InstallationBehavior.RebootBehavior -ne 0); Category = (@($u.Categories) | Select-Object -First 1).Name
            Driver = ('{0} {1}' -f $u.DriverManufacturer, $u.DriverClass).Trim()
        }
    }
    $out = @($out)
    if ($Type -eq 'Software') { Set-LastCheck 'WinUpdates' $out.Count } else { Set-LastCheck 'Drivers' $out.Count }
    Write-Log ("Windows Update: {0} {1} update(s) available." -f $out.Count, $Type.ToLower()) 'OK'
    $out
}

function Install-WindowsUpdates {
    param([string[]]$Ids, [ValidateSet('Software', 'Driver')][string]$Type = 'Software')
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $res  = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='$Type'")
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $res.Updates) {
        if ($Ids -and $Ids -notcontains $u.Identity.UpdateID) { continue }
        if ($u.InstallationBehavior.CanRequestUserInput) { Write-Log "  Skipped (needs interaction - use Settings > Windows Update): $($u.Title)" 'WARN'; continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$coll.Add($u)
    }
    if ($coll.Count -eq 0) { Write-Log 'Nothing to install.'; return }
    Write-Log "Downloading $($coll.Count) update(s)..."
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
    [void]$dl.Download()
    Write-Log 'Installing...'
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
    $r = $inst.Install()
    $codes = @{ 0 = 'not started'; 1 = 'in progress'; 2 = 'OK'; 3 = 'OK with errors'; 4 = 'FAILED'; 5 = 'aborted' }
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $c = $r.GetUpdateResult($i).ResultCode
        $lvl = 'OK'; if ($c -ge 4) { $lvl = 'WARN' }
        Write-Log ("  {0}: {1}" -f $codes[[int]$c], $coll.Item($i).Title) $lvl
    }
    if ($r.RebootRequired) { Write-Log 'A restart is required to finish installing updates.' 'WARN' }
    $remaining = @(Get-WindowsUpdateList -Type $Type).Count
}

# ---------------------------------------------------------------------------
# Privacy toggles - each one records the original value so it can be put back exactly
# ---------------------------------------------------------------------------
$script:CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$script:ExplAdv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

function New-PrivacyItem {
    param([string]$Key, [string]$Name, [string]$Group, [string]$Description, [bool]$Recommended, [object[]]$Values)
    [pscustomobject]@{
        Key = $Key; Name = $Name; Group = $Group; Description = $Description; Recommended = $Recommended
        Values = @($Values | ForEach-Object { [pscustomobject]@{ Path = $_[0]; Name = $_[1]; Data = $_[2] } })
    }
}

$script:PrivacyItems = @(
    New-PrivacyItem 'Telemetry' 'Diagnostic data: required only' 'Telemetry' 'Limits what Windows sends to Microsoft to the required minimum (policy).' $true @(
        ,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 1))
    New-PrivacyItem 'AdId' 'Advertising ID off' 'Ads' 'Stops apps from using your advertising ID for personalised ads.' $true @(
        ,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', 0))
    New-PrivacyItem 'Tailored' 'Tailored experiences off' 'Telemetry' 'Microsoft does not use your diagnostic data for tips and ads.' $true @(
        ,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy', 'TailoredExperiencesWithDiagnosticDataEnabled', 0))
    New-PrivacyItem 'StartSuggest' 'No app suggestions in Start' 'Ads' 'Removes "suggested" apps (ads) from the Start menu.' $true @(
        @($script:CDM, 'SubscribedContent-338388Enabled', 0), @($script:CDM, 'SystemPaneSuggestionsEnabled', 0))
    New-PrivacyItem 'Tips' 'No tips & tricks notifications' 'Ads' 'Stops "Get tips, tricks and suggestions as you use Windows".' $true @(
        @($script:CDM, 'SubscribedContent-338389Enabled', 0), @($script:CDM, 'SoftLandingEnabled', 0))
    New-PrivacyItem 'SettingsSuggest' 'No suggested content in Settings' 'Ads' 'Removes promoted content inside the Settings app.' $true @(
        @($script:CDM, 'SubscribedContent-338393Enabled', 0), @($script:CDM, 'SubscribedContent-353694Enabled', 0), @($script:CDM, 'SubscribedContent-353696Enabled', 0))
    New-PrivacyItem 'Welcome' 'No "welcome experience" after updates' 'Ads' 'Skips the full-screen what''s-new/sign-in pitch after updates.' $true @(
        ,@($script:CDM, 'SubscribedContent-310093Enabled', 0))
    New-PrivacyItem 'Scoobe' 'No "finish setting up your device" nag' 'Ads' 'Stops the recurring full-screen setup reminder (OneDrive, Microsoft 365, Game Pass pitches).' $true @(
        ,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', 'ScoobeSystemSettingEnabled', 0))
    New-PrivacyItem 'LockAds' 'No fun facts / ads on the lock screen' 'Ads' 'Removes tips and promotions on the lock screen (your picture stays).' $true @(
        @($script:CDM, 'RotatingLockScreenOverlayEnabled', 0), @($script:CDM, 'SubscribedContent-338387Enabled', 0))
    New-PrivacyItem 'SilentApps' 'No silently installed "suggested" apps' 'Ads' 'Stops Windows from auto-installing promoted apps like Candy Crush.' $true @(
        @($script:CDM, 'SilentInstalledAppsEnabled', 0), @($script:CDM, 'PreInstalledAppsEnabled', 0), @($script:CDM, 'OemPreInstalledAppsEnabled', 0))
    New-PrivacyItem 'StartRecs' 'No tips/promotions in Start recommendations' 'Ads' 'Removes promoted items from the Start "Recommended" area.' $true @(
        ,@($script:ExplAdv, 'Start_IrisRecommendations', 0))
    New-PrivacyItem 'AccountNotif' 'No account notifications in Start' 'Ads' 'Removes Microsoft account / backup nags from the Start menu.' $true @(
        ,@($script:ExplAdv, 'Start_AccountNotifications', 0))
    New-PrivacyItem 'SyncAds' 'No OneDrive/sync ads in File Explorer' 'Ads' 'Hides sync provider notifications in Explorer.' $true @(
        ,@($script:ExplAdv, 'ShowSyncProviderNotifications', 0))
    New-PrivacyItem 'Activity' 'Activity history off' 'Telemetry' 'Windows does not collect or upload your activity history (policy).' $true @(
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'PublishUserActivities', 0), @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'UploadUserActivities', 0))
    New-PrivacyItem 'BingStart' 'No Bing web results in Start search' 'Search' 'Start search only searches your PC (policy). Also faster.' $true @(
        @('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1), @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0))
    New-PrivacyItem 'Inking' 'No inking & typing personalisation' 'Telemetry' 'Stops sending typing/handwriting samples to build a personal dictionary.' $true @(
        @('HKCU:\Software\Microsoft\InputPersonalization', 'RestrictImplicitInkCollection', 1), @('HKCU:\Software\Microsoft\InputPersonalization', 'RestrictImplicitTextCollection', 1),
        @('HKCU:\Software\Microsoft\Personalization\Settings', 'AcceptedPrivacyPolicy', 0))
    New-PrivacyItem 'Feedback' 'Never ask for feedback' 'Telemetry' 'Windows stops popping up feedback requests.' $true @(
        ,@('HKCU:\Software\Microsoft\Siuf\Rules', 'NumberOfSIUFInPeriod', 0))
    New-PrivacyItem 'LangList' 'Websites cannot read your language list' 'Telemetry' 'Small fingerprinting reduction.' $true @(
        ,@('HKCU:\Control Panel\International\User Profile', 'HttpAcceptLanguageOptOut', 1))
    New-PrivacyItem 'Recall' 'Recall snapshots off (Copilot+ PCs)' 'AI' 'Prevents Windows Recall from saving screen snapshots (policy).' $true @(
        ,@('HKCU:\Software\Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', 1))
    New-PrivacyItem 'Copilot' 'Turn off Windows Copilot (older builds)' 'AI' 'Policy for the built-in Copilot sidebar. Newer Copilot app: remove it on the Apps tab.' $false @(
        ,@('HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1))
    New-PrivacyItem 'Speech' 'Online speech recognition off' 'Telemetry' 'Voice typing/dictation will stop working until turned back on.' $false @(
        ,@('HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy', 'HasAccepted', 0))
    New-PrivacyItem 'Widgets' 'No news feed in Widgets' 'Ads' 'Turns off the MSN news/interests feed (policy).' $false @(
        ,@('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0))
    New-PrivacyItem 'TrackProgs' 'Do not track app launches' 'Telemetry' 'Start no longer builds "most used" from launch history.' $false @(
        ,@($script:ExplAdv, 'Start_TrackProgs', 0))
)

function Get-RegValue {
    param([string]$Path, [string]$Name)
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $k -or ($k.GetValueNames() -notcontains $Name)) { return [pscustomobject]@{ Exists = $false; Data = $null; Kind = '' } }
    [pscustomobject]@{ Exists = $true; Data = $k.GetValue($Name); Kind = [string]$k.GetValueKind($Name) }
}

function Get-PrivacySaved {
    $h = @{}
    $j = Read-JsonFile (Get-StatePath 'privacy')
    if ($j) { foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    $h
}

function Get-PrivacyStatus {
    $saved = Get-PrivacySaved
    foreach ($it in $script:PrivacyItems) {
        $on = $true
        foreach ($v in $it.Values) {
            $cur = Get-RegValue $v.Path $v.Name
            if (-not $cur.Exists -or [string]$cur.Data -ne [string]$v.Data) { $on = $false }
        }
        $changedByUs = @($it.Values | Where-Object { $saved.ContainsKey("$($_.Path)|$($_.Name)") }).Count -gt 0
        [pscustomobject]@{ Item = $it; Protected = $on; ChangedByCleanIT = $changedByUs }
    }
}

function Set-PrivacyItem {
    param($Item, [bool]$Protect)
    $saved = Get-PrivacySaved
    foreach ($v in $Item.Values) {
        $id = "$($v.Path)|$($v.Name)"
        if ($Protect) {
            if (-not $saved.ContainsKey($id)) {
                $cur = Get-RegValue $v.Path $v.Name
                $saved[$id] = [pscustomobject]@{ Exists = $cur.Exists; Data = $cur.Data; Kind = $cur.Kind }
            }
            if (-not (Test-Path -LiteralPath $v.Path)) { New-Item -Path $v.Path -Force | Out-Null }
            Set-ItemProperty -LiteralPath $v.Path -Name $v.Name -Value $v.Data -Type DWord
        }
        else {
            if ($saved.ContainsKey($id)) {
                $o = $saved[$id]
                if ($o.Exists) {
                    $kind = $o.Kind; if (-not $kind) { $kind = 'DWord' }
                    Set-ItemProperty -LiteralPath $v.Path -Name $v.Name -Value $o.Data -Type $kind
                }
                else { Remove-ItemProperty -LiteralPath $v.Path -Name $v.Name -ErrorAction SilentlyContinue }
                $saved.Remove($id)
            }
            else {
                # value was set before CleanIT - remove it so Windows uses its default
                Remove-ItemProperty -LiteralPath $v.Path -Name $v.Name -ErrorAction SilentlyContinue
            }
        }
    }
    Write-JsonFile (Get-StatePath 'privacy') ([pscustomobject]$saved)
    $verb = 'restored to default'; if ($Protect) { $verb = 'applied' }
    Write-Log "Privacy: $($Item.Name) - $verb" 'OK'
}

function Restore-AllPrivacy {
    $saved = Get-PrivacySaved
    foreach ($it in $script:PrivacyItems) {
        if (@($it.Values | Where-Object { $saved.ContainsKey("$($_.Path)|$($_.Name)") }).Count) { Set-PrivacyItem $it $false }
    }
    Write-Log 'Privacy: all CleanIT changes restored.' 'OK'
}

function Set-RecommendedPrivacy {
    foreach ($s in Get-PrivacyStatus) { if ($s.Item.Recommended -and -not $s.Protected) { Set-PrivacyItem $s.Item $true } }
}

# ---------------------------------------------------------------------------
# Health, security, maintenance
# ---------------------------------------------------------------------------
function Test-PendingReboot {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Get-WindowsSupportStatus {
    $os = Get-CimInstance Win32_OperatingSystem
    $b = [int]$os.BuildNumber
    $ent = $os.Caption -match 'Enterprise|Education'
    # Home/Pro end-of-servicing dates (Enterprise/Education get +12 months on H2 releases). Update when new versions ship.
    if ($b -lt 22000) { return [pscustomobject]@{ Level = 'BAD'; Text = 'Windows 10 reached end of support on Oct 14, 2025 - no security fixes unless enrolled in ESU. Upgrade to Windows 11 if the PC supports it.' } }
    if ($b -lt 26100) { return [pscustomobject]@{ Level = 'BAD'; Text = "This Windows 11 version (build $b) is out of support - install the latest feature update." } }
    if ($b -lt 26200 -and -not $ent) {
        if ((Get-Date) -gt [datetime]'2026-10-13') { return [pscustomobject]@{ Level = 'BAD'; Text = 'Windows 11 24H2 is out of support (Oct 13, 2026) - install 25H2 from Windows Update.' } }
        return [pscustomobject]@{ Level = 'WARN'; Text = 'Windows 11 24H2 support ends Oct 13, 2026 - install 25H2 from Windows Update.' }
    }
    [pscustomobject]@{ Level = 'OK'; Text = "Windows 11 (build $b) is in support." }
}

function Get-SecurityChecks {
    $r = New-Object System.Collections.Generic.List[object]
    $add = { param($Name, $Level, $Detail, $Fix) $r.Add([pscustomobject]@{ Name = $Name; Level = $Level; Detail = $Detail; Fix = $Fix }) }

    $avs = @(Invoke-WithTimeout 'Antivirus list (Security Center)' { Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct } 15 @())
    $activeAv = @($avs | Where-Object { (($_.productState -shr 12) -band 0xF) -eq 1 } | ForEach-Object { $_.displayName })
    $mp = Invoke-WithTimeout 'Defender status' { Get-MpComputerStatus } 20
    if ($script:TimedOut -contains 'Defender status') { & $add 'Microsoft Defender' 'WARN' 'Defender did not answer within 20 s (busy scanning or updating?). Try Re-check later.' 'OpenSecurity' }
    if ($activeAv.Count) { & $add 'Antivirus' 'OK' ('Active: ' + ($activeAv -join ', ')) '' }
    elseif ($mp -and $mp.RealTimeProtectionEnabled) { & $add 'Antivirus' 'OK' 'Microsoft Defender real-time protection is on.' '' }
    else { & $add 'Antivirus' 'BAD' 'No active real-time antivirus found.' 'OpenSecurity' }

    if ($mp) {
        $defActive = $mp.AMRunningMode -eq 'Normal'
        if ($defActive) {
            if (-not $mp.RealTimeProtectionEnabled) { & $add 'Defender real-time protection' 'BAD' 'Off - turn it on in Windows Security.' 'OpenSecurity' }
            $age = [int]$mp.AntivirusSignatureAge
            if ($age -gt 3) { & $add 'Defender signatures' 'WARN' "$age day(s) old." 'UpdateSignatures' }
            else { & $add 'Defender signatures' 'OK' "Up to date ($age day(s) old)." 'UpdateSignatures' }
            $qa = [int]$mp.QuickScanAge
            if ($qa -gt 14) { & $add 'Last quick scan' 'WARN' "$qa day(s) ago." 'QuickScan' } else { & $add 'Last quick scan' 'OK' "$qa day(s) ago." 'QuickScan' }
            if ($mp.PSObject.Properties['IsTamperProtected']) {
                if ($mp.IsTamperProtected) { & $add 'Tamper protection' 'OK' 'On - malware cannot switch Defender off.' '' }
                else { & $add 'Tamper protection' 'WARN' 'Off - turn on in Windows Security > Virus & threat protection settings.' 'OpenSecurity' }
            }
        }
        else { & $add 'Microsoft Defender' 'INFO' "Running in $($mp.AMRunningMode) mode (another antivirus is in charge)." '' }
        $threats = @(Invoke-WithTimeout 'Defender threat history' { Get-MpThreatDetection } 15 @() | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-30) })
        if ($threats.Count) { & $add 'Threats (last 30 days)' 'WARN' "$($threats.Count) detection(s) - review Protection history in Windows Security." 'OpenSecurity' }
        elseif ($defActive) { & $add 'Threats (last 30 days)' 'OK' 'No detections.' '' }
    }

    $fw = @(Invoke-WithTimeout 'Firewall status' { Get-NetFirewallProfile } 15 @())
    $off = @($fw | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    if ($fw.Count -and $off.Count) { & $add 'Firewall' 'BAD' ('Off for: ' + ($off -join ', ')) 'EnableFirewall' }
    elseif ($fw.Count) { & $add 'Firewall' 'OK' 'On for all network profiles.' '' }

    $lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue)
    if ($lua.EnableLUA -eq 0) { & $add 'User Account Control' 'BAD' 'UAC is disabled - every program runs with full rights.' '' }
    elseif ($lua.ConsentPromptBehaviorAdmin -eq 0) { & $add 'User Account Control' 'WARN' 'Set to "never notify".' '' }
    else { & $add 'User Account Control' 'OK' 'On.' '' }

    $ss = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -ErrorAction SilentlyContinue).SmartScreenEnabled
    $ssPol = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -ErrorAction SilentlyContinue).EnableSmartScreen
    if ($ss -eq 'Off' -or $ssPol -eq 0) { & $add 'SmartScreen' 'WARN' 'Off - downloaded apps are not reputation-checked.' 'OpenSecurity' }
    else { & $add 'SmartScreen' 'OK' 'On.' '' }

    $sb = Invoke-WithTimeout 'Secure Boot check' { try { [string](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { 'n/a' } } 10 'n/a'
    if ($sb -eq 'True') { & $add 'Secure Boot' 'OK' 'On.' '' }
    elseif ($sb -eq 'False') { & $add 'Secure Boot' 'WARN' 'Off - enable in UEFI/BIOS setup.' '' }
    else { & $add 'Secure Boot' 'INFO' 'Not supported or legacy BIOS mode.' '' }

    $tpm = Invoke-WithTimeout 'TPM check' { Get-Tpm } 10
    if ($tpm) {
        if ($tpm.TpmPresent -and $tpm.TpmReady) { & $add 'TPM' 'OK' 'Present and ready.' '' }
        elseif ($tpm.TpmPresent) { & $add 'TPM' 'WARN' 'Present but not ready.' '' }
        else { & $add 'TPM' 'INFO' 'Not present.' '' }
    }

    $dg = Invoke-WithTimeout 'Memory integrity check' { Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard } 10
    if ($dg) {
        if (@($dg.SecurityServicesRunning) -contains 2) { & $add 'Memory integrity (HVCI)' 'OK' 'On.' '' }
        else { & $add 'Memory integrity (HVCI)' 'INFO' 'Off - Windows Security > Device security > Core isolation.' 'OpenSecurity' }
    }

    $bl = Invoke-WithTimeout 'BitLocker check' { Get-BitLockerVolume -MountPoint $env:SystemDrive } 10
    if ($bl) {
        if ([string]$bl.ProtectionStatus -eq 'On') { & $add 'Drive encryption' 'OK' "BitLocker is protecting $env:SystemDrive." '' }
        else { & $add 'Drive encryption' 'INFO' "$env:SystemDrive is not encrypted (matters most for laptops)." '' }
    }

    $smb = Invoke-WithTimeout 'SMBv1 check' { Get-SmbServerConfiguration } 10
    if ($smb -and $smb.EnableSMB1Protocol) { & $add 'SMBv1 file sharing' 'WARN' 'Old, insecure protocol (WannaCry) is enabled. Turn off unless an old NAS needs it.' '' }

    $guest = Invoke-WithTimeout 'Guest account check' { Get-LocalUser -Name Guest } 10
    if ($guest -and $guest.Enabled) { & $add 'Guest account' 'WARN' 'Enabled.' '' }

    $rdp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($rdp -eq 0) { & $add 'Remote Desktop' 'INFO' 'Remote Desktop is ON - make sure you meant that.' '' }

    $ws = Get-WindowsSupportStatus
    & $add 'Windows version' $ws.Level $ws.Text ''

    $lc = Get-LastCheck
    if ([int]$lc.WinUpdates -gt 0) { & $add 'Windows updates' 'WARN' "$($lc.WinUpdates) pending (checked $(Format-Ago $lc.WinDate))." 'GoUpdates' }
    if ([int]$lc.AppUpdates -gt 0) { & $add 'Outdated apps' 'WARN' "$($lc.AppUpdates) app(s) have updates - old apps are the #1 way in for malware." 'GoUpdates' }
    $r.ToArray()
}

function Invoke-DefenderQuickScan {
    Write-Log 'Microsoft Defender quick scan started...'
    Start-MpScan -ScanType QuickScan -ErrorAction Stop
    $t = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-2) })
    if ($t.Count) { Write-Log "Quick scan finished: $($t.Count) threat(s) found - open Windows Security > Protection history." 'WARN' }
    else { Write-Log 'Quick scan finished: no threats found.' 'OK' }
}

function Update-DefenderSignatures {
    Write-Log 'Updating Defender signatures...'
    Update-MpSignature -ErrorAction Stop
    Write-Log 'Defender signatures updated.' 'OK'
}

function Invoke-NativeLogged {
    param([string]$File, [string]$Arguments, [Text.Encoding]$Encoding, [string]$SkipPattern)
    $psi = New-Object Diagnostics.ProcessStartInfo $File, $Arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    if ($Encoding) { $psi.StandardOutputEncoding = $Encoding }
    $p = [Diagnostics.Process]::Start($psi)
    while ($true) {
        $line = $p.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        $t = ($line -replace "`0", '').Trim()
        if (-not $t) { continue }
        if ($SkipPattern -and $t -match $SkipPattern) { continue }
        Write-Log "  $t"
    }
    $p.WaitForExit()
    $p.ExitCode
}

function Invoke-WindowsRepair {
    Write-Log 'Step 1/2: DISM /RestoreHealth (repairs the Windows component store; 5-20 min)...'
    $c1 = Invoke-NativeLogged "$env:SystemRoot\System32\Dism.exe" '/Online /Cleanup-Image /RestoreHealth' $null '^\[|%'
    if ($c1 -eq 0) { Write-Log 'DISM finished OK.' 'OK' } else { Write-Log "DISM exit code $c1." 'WARN' }
    Write-Log 'Step 2/2: System File Checker (sfc /scannow; 5-15 min)...'
    $c2 = Invoke-NativeLogged "$env:SystemRoot\System32\sfc.exe" '/scannow' ([Text.Encoding]::Unicode) '% complete|^Beginning'
    if ($c2 -eq 0) { Write-Log 'SFC finished.' 'OK' } else { Write-Log "SFC exit code $c2 - details in C:\Windows\Logs\CBS\CBS.log." 'WARN' }
}

function Invoke-DriveOptimize {
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -in @('NTFS', 'ReFS') })) {
        if (Test-BgCancel) { break }
        $media = 'unknown'
        try { $media = [string](Get-Partition -DriveLetter $v.DriveLetter | Get-Disk | ForEach-Object { Get-PhysicalDisk -DeviceNumber $_.Number }).MediaType } catch {}
        $what = 'Windows picks the right method'
        if ($media -eq 'SSD') { $what = 'TRIM (no defrag on SSDs)' } elseif ($media -eq 'HDD') { $what = 'defragment' }
        Write-Log "Optimizing $($v.DriveLetter): [$media] - $what..."
        try {
            Optimize-Volume -DriveLetter $v.DriveLetter -Verbose -ErrorAction Stop 4>&1 | ForEach-Object {
                $m = [string]$_; if ($m -and $m -notmatch '^\s*$') { Write-Log "  $m" }
            }
            Write-Log "  $($v.DriveLetter): done." 'OK'
        }
        catch { Write-Log "  $($v.DriveLetter): $($_.Exception.Message)" 'WARN' }
    }
}

function Get-StabilitySummary {
    $empty = [pscustomobject]@{ Unexpected = 0; BlueScreens = 0; AppCrashes = 0; TopCrashers = @() }
    Invoke-WithTimeout 'Crash history (event log)' {
        $since = (Get-Date).AddDays(-30)
        $unexpected = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }).Count
        $bsod = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }).Count
        $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since })
        $top = @($crashes | ForEach-Object { [string]$_.Properties[0].Value } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 |
            ForEach-Object { '{0} ({1}x)' -f $_.Name, $_.Count })
        [pscustomobject]@{ Unexpected = $unexpected; BlueScreens = $bsod; AppCrashes = $crashes.Count; TopCrashers = $top }
    } 30 $empty
}

function Get-HealthReport {
    $L = New-Object System.Collections.Generic.List[string]
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $up = (Get-Date) - $os.LastBootUpTime

    $L.Add("Computer : $env:COMPUTERNAME ($($cs.Manufacturer) $($cs.Model))")
    $L.Add("OS       : $($os.Caption) (build $($os.BuildNumber))")
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cpu) { $L.Add(('CPU      : {0} - {1}% busy right now' -f $cpu.Name.Trim(), $cpu.LoadPercentage)) }
    $L.Add(('Uptime   : {0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes))
    if ($up.TotalDays -gt 7) { $L.Add('           ! Over a week since the last restart - a reboot can help.') }
    $totalRam = [double]$cs.TotalPhysicalMemory
    $usedRam  = $totalRam - ([double]$os.FreePhysicalMemory * 1KB)
    if ($totalRam -gt 0) {
        $L.Add(('Memory   : {0} used of {1} ({2:N0}%)' -f (Format-Size $usedRam), (Format-Size $totalRam), ($usedRam / $totalRam * 100)))
    }
    foreach ($g in @(Get-CimInstance Win32_VideoController)) {
        $dd = ''; if ($g.DriverDate) { $dd = ' from ' + ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') }
        $L.Add(('GPU      : {0} (driver {1}{2})' -f $g.Name, $g.DriverVersion, $dd))
        if ($g.DriverDate -and ([datetime]$g.DriverDate) -lt (Get-Date).AddYears(-1) -and $g.Name -notmatch 'Microsoft|Basic|Virtual|Parsec|Remote') {
            $L.Add('           ! GPU driver is over a year old - get the latest from the GPU maker.')
        }
    }

    $L.Add(''); $L.Add('DRIVES')
    foreach ($d in Get-FixedDrives) {
        $pct = 0; if ($d.Size) { $pct = $d.FreeSpace / $d.Size * 100 }
        $flag = ''; if ($pct -lt 10) { $flag = '  ! LOW' } elseif ($pct -lt 20) { $flag = '  ! getting full' }
        $L.Add(('  {0}  {1} free of {2} ({3:N0}% free){4}' -f $d.DeviceID, (Format-Size $d.FreeSpace), (Format-Size $d.Size), $pct, $flag))
    }

    $pd = @(Invoke-WithTimeout 'Disk health (SMART)' { Get-PhysicalDisk | ForEach-Object { $_ | Add-Member -NotePropertyName Rel -NotePropertyValue ($_ | Get-StorageReliabilityCounter) -PassThru } } 30 @())
    if ($pd.Count) {
        $L.Add(''); $L.Add('PHYSICAL DISKS (SMART)')
        foreach ($p in $pd) {
            $L.Add(('  {0}  [{1}]  {2}  health: {3}' -f $p.FriendlyName, $p.MediaType, (Format-Size $p.Size), $p.HealthStatus))
            $rc = $p.Rel
            if ($rc) {
                $bits = New-Object System.Collections.Generic.List[string]
                if ($rc.Temperature) { $bits.Add("$($rc.Temperature) C") }
                if ($null -ne $rc.Wear) { $bits.Add("wear $($rc.Wear)%") }
                if ($rc.PowerOnHours) { $bits.Add(('{0:N0} power-on hours' -f $rc.PowerOnHours)) }
                if ($rc.ReadErrorsUncorrected) { $bits.Add("UNCORRECTED READ ERRORS: $($rc.ReadErrorsUncorrected)") }
                if ($bits.Count) { $L.Add('      ' + ($bits -join ', ')) }
                if ($rc.Wear -ge 80) { $L.Add('      ! SSD is near the end of its rated life - back up and plan a replacement.') }
            }
            if ($p.HealthStatus -ne 'Healthy') { $L.Add('      ! Disk reports a problem - BACK UP NOW.') }
        }
    }

    $bat = Invoke-WithTimeout 'Battery check' { Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity } 10 | Select-Object -First 1
    $des = Invoke-WithTimeout 'Battery check' { Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData } 10 | Select-Object -First 1
    if ($bat -and $des -and $des.DesignedCapacity) {
        $hp = $bat.FullChargedCapacity / $des.DesignedCapacity * 100
        $L.Add(''); $L.Add(('Battery        : {0:N0}% of original capacity' -f $hp))
        if ($hp -lt 70) { $L.Add('                 ! Battery is worn - expect much shorter runtime.') }
    }

    $L.Add('')
    if (Test-PendingReboot) { $L.Add('Pending reboot : YES - restart to finish installing updates') } else { $L.Add('Pending reboot : no') }
    $ws = Get-WindowsSupportStatus
    $L.Add("Windows support: $($ws.Text)")
    $mp = Invoke-WithTimeout 'Defender status' { Get-MpComputerStatus } 20
    if ($mp) {
        $rt = 'OFF'; if ($mp.RealTimeProtectionEnabled) { $rt = 'ON' }
        $L.Add(('Defender       : real-time {0}, signatures {1} day(s) old' -f $rt, $mp.AntivirusSignatureAge))
    }
    $L.Add(('Startup apps   : {0} enabled' -f @(Get-StartupItems -Quick | Where-Object { $_.Enabled }).Count))
    $sched = 'off'; if (Test-Schedule) { $s = Get-Settings; $sched = "on ($($s.ScheduleDay)s $($s.ScheduleTime))" }
    $L.Add("Auto-clean     : $sched")
    $rp = @(Get-RestorePoints) | Sort-Object Date -Descending | Select-Object -First 1
    $prot = Test-SystemProtection
    if ($prot -eq $false) { $L.Add('Restore points : System Protection is OFF for ' + $env:SystemDrive) }
    elseif ($rp) { $L.Add("Restore points : last one $(Format-Ago $rp.Date) ($($rp.Description))") }

    $st = Get-StabilitySummary
    $L.Add(''); $L.Add('STABILITY (last 30 days)')
    $L.Add(('  Unexpected shutdowns: {0}   Blue screens: {1}   App crashes: {2}' -f $st.Unexpected, $st.BlueScreens, $st.AppCrashes))
    if ($st.TopCrashers.Count) { $L.Add('  Most crashes: ' + ($st.TopCrashers -join ', ')) }
    if ($st.BlueScreens -gt 0) { $L.Add('  ! Blue screens happened - check drivers (GPU, chipset) and run Repair Windows.') }
    if ($st.Unexpected -ge 3) { $L.Add('  ! Several unexpected shutdowns (power loss, hard reset, freezes or PSU/overheating). If you did not cut power yourself, check temperatures and power supply.') }

    $L.Add(''); $L.Add('TOP MEMORY USERS')
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Mem = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
    } | Sort-Object Mem -Descending | Select-Object -First 8 | ForEach-Object {
        $n = $_.Name; if ($_.Count -gt 1) { $n = "$n (x$($_.Count))" }
        $L.Add(('  {0,-34} {1,10}' -f $n, (Format-Size $_.Mem)))
    }
    $L -join "`r`n"
}

# ---------------------------------------------------------------------------
# Dashboard score + fleet reporting
# ---------------------------------------------------------------------------
function Get-DashboardData {
    $issues = New-Object System.Collections.Generic.List[object]
    $score = 100
    $add = { param($Penalty, $Level, $Text, $Tab) $issues.Add([pscustomobject]@{ Level = $Level; Text = $Text; Tab = $Tab; Penalty = $Penalty }) }

    $os = Get-CimInstance Win32_OperatingSystem
    $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $freePct = 100; if ($sys.Size) { $freePct = $sys.FreeSpace / $sys.Size * 100 }
    if ($freePct -lt 10) { & $add 25 'BAD' ('{0} is almost full ({1:N0}% free)' -f $env:SystemDrive, $freePct) 'Clean' }
    elseif ($freePct -lt 20) { & $add 10 'WARN' ('{0} is getting full ({1:N0}% free)' -f $env:SystemDrive, $freePct) 'Disk' }

    if (Test-PendingReboot) { & $add 10 'WARN' 'Restart needed to finish installing updates' 'Health' }
    $up = (Get-Date) - $os.LastBootUpTime
    if ($up.TotalDays -gt 7) { & $add 5 'INFO' ('Not restarted for {0} days' -f [math]::Floor($up.TotalDays)) 'Health' }

    foreach ($c in Get-SecurityChecks) {
        if ($c.Level -eq 'BAD') { & $add 20 'BAD' "$($c.Name): $($c.Detail)" 'Security' }
        elseif ($c.Level -eq 'WARN' -and $c.Name -notin @('Windows updates', 'Outdated apps')) { & $add 5 'WARN' "$($c.Name): $($c.Detail)" 'Security' }
    }

    foreach ($p in @(Invoke-WithTimeout 'Disk health (SMART)' { Get-PhysicalDisk } 20 @())) {
        if ($p.HealthStatus -and $p.HealthStatus -ne 'Healthy') { & $add 30 'BAD' "Disk $($p.FriendlyName) reports $($p.HealthStatus) - back up now" 'Health' }
    }

    $lc = Get-LastCheck
    if ([int]$lc.WinUpdates -gt 0) { & $add 10 'WARN' "$($lc.WinUpdates) Windows update(s) waiting" 'Updates' }
    if ([int]$lc.AppUpdates -gt 0) { & $add ([math]::Min(10, 2 * [int]$lc.AppUpdates)) 'WARN' "$($lc.AppUpdates) app update(s) available" 'Updates' }
    if (-not $lc.AppDate -or ([datetime]$lc.AppDate) -lt (Get-Date).AddDays(-14)) { & $add 3 'INFO' 'App updates not checked in the last 2 weeks' 'Updates' }

    $stab = Get-StabilitySummary
    if ($stab.BlueScreens -gt 0) { & $add 15 'BAD' "$($stab.BlueScreens) blue screen(s) in the last 30 days - see the Health tab" 'Health' }
    if ($stab.Unexpected -ge 3) { & $add 5 'WARN' "$($stab.Unexpected) unexpected shutdowns in the last 30 days (power loss, freezes or hard resets)" 'Health' }

    $startup = @(Get-StartupItems -Quick | Where-Object { $_.Enabled }).Count
    if ($startup -gt 10) { & $add 10 'WARN' "$startup apps launch at sign-in - slows startup" 'Startup' }
    elseif ($startup -gt 6) { & $add 5 'INFO' "$startup apps launch at sign-in" 'Startup' }

    $hist = @(Get-CleanHistory)
    $last = $hist | Select-Object -Last 1
    $lastDate = $null; if ($last) { $lastDate = [datetime]$last.Date }
    if (-not $lastDate -or $lastDate -lt (Get-Date).AddDays(-30)) { & $add 10 'WARN' 'Junk not cleaned in the last 30 days' 'Clean' }
    if (-not (Test-Schedule)) { & $add 3 'INFO' 'Automatic weekly cleaning is off' 'Settings' }
    if ((Test-SystemProtection) -eq $false) { & $add 5 'WARN' "System Protection (restore points) is off for $env:SystemDrive" 'Settings' }

    $priv = @(Get-PrivacyStatus | Where-Object { $_.Item.Recommended -and -not $_.Protected }).Count
    if ($priv -gt 0) { & $add ([math]::Min(8, $priv)) 'INFO' "$priv recommended privacy setting(s) not applied" 'Privacy' }

    if ($script:TimedOut.Count) {
        & $add 0 'INFO' ('Skipped (Windows did not answer in time): ' + (($script:TimedOut | Sort-Object -Unique) -join ', ')) 'Security'
    }
    foreach ($i in $issues) { $score -= $i.Penalty }
    $score = [math]::Max(0, [math]::Min(100, $score))
    $lastSched = $hist | Where-Object { $_.Source -eq 'Scheduled' } | Select-Object -Last 1

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Version = $script:Version; Time = (Get-Date).ToString('s')
        Score = [int]$score; Issues = @($issues | Sort-Object Penalty -Descending)
        FreePct = [math]::Round($freePct, 1); FreeBytes = [double]$sys.FreeSpace; SizeBytes = [double]$sys.Size
        FreedTotal = (Get-FreedTotal); LastClean = $lastDate; LastFreed = $(if ($last) { [double]$last.Freed } else { 0 })
        LastScheduled = $(if ($lastSched) { $lastSched.Date } else { $null })
        StartupCount = $startup; PendingReboot = (Test-PendingReboot); Uptime = [math]::Round($up.TotalDays, 1)
        AppUpdates = [int]$lc.AppUpdates; WinUpdates = [int]$lc.WinUpdates; OS = $os.Caption; Build = $os.BuildNumber
    }
}

function Write-FleetReport {
    param($Data)
    $path = (Get-Settings).FleetPath
    if (-not $path) { return }
    try {
        if (-not $Data) { $Data = Get-DashboardData }
        $o = $Data | Select-Object * -ExcludeProperty Issues
        $o | Add-Member -NotePropertyName Issues -NotePropertyValue @($Data.Issues | ForEach-Object { "[$($_.Level)] $($_.Text)" }) -Force
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null }
        Write-JsonFile (Join-Path $path "$env:COMPUTERNAME.json") $o
        Write-Log "Fleet report written to $path" 'OK'
    }
    catch { Write-Log "Fleet report could not be written to ${path}: $($_.Exception.Message)" 'WARN' }
}

function Get-FleetReports {
    $path = (Get-Settings).FleetPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $path -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $j = Read-JsonFile $f.FullName
        if ($j -and $j.Computer) { $j }
    }
}

# ---------------------------------------------------------------------------
# Disk tools (wrappers around the native walker)
# ---------------------------------------------------------------------------
function Get-DefaultDiskExcludes {
    @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
      "$env:SystemDrive\`$Recycle.Bin", "$env:SystemDrive\System Volume Information", "$env:SystemDrive\Recovery") +
    @(Get-UserProfiles | ForEach-Object { "$_\AppData" }) | Where-Object { $_ }
}

function Find-LargeFiles {
    param([string]$Path, [int]$MinSizeMB = 500, [int]$UnusedDays = 0, [int]$Max = 500, [switch]$IncludeSystem, $State)
    Initialize-Native
    if (-not $State) { $State = New-Object CleanIT.ScanState }
    $since = [datetime]::MaxValue
    if ($UnusedDays -gt 0) { $since = (Get-Date).AddDays(-$UnusedDays) }
    $ex = @(); if (-not $IncludeSystem) { $ex = Get-DefaultDiskExcludes }
    [CleanIT.Disk]::FindLarge($Path, [long]$MinSizeMB * 1MB, $since, $Max, [string[]]$ex, $State)
}

function Find-DuplicateFiles {
    param([string]$Path, [int]$MinSizeMB = 1, [switch]$IncludeSystem, $State)
    Initialize-Native
    if (-not $State) { $State = New-Object CleanIT.ScanState }
    $ex = @(); if (-not $IncludeSystem) { $ex = Get-DefaultDiskExcludes }
    [CleanIT.Disk]::FindDuplicates($Path, [long]$MinSizeMB * 1MB, [string[]]$ex, $State)
}

# ---------------------------------------------------------------------------
# Scheduling, notifications, install, migration
# ---------------------------------------------------------------------------
function Test-Schedule { [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) }

function Protect-DataDir {
    # Scripts here run as SYSTEM - only admins/SYSTEM may change them, users may read.
    & icacls.exe $script:DataDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q 2>&1 | Out-Null
}

function Copy-AppFiles {
    param([string]$SourceDir)
    $files = @('CleanIT.ps1', 'CleanIT.Core.ps1', 'Run-CleanIT.bat')
    foreach ($f in $files) {
        $src = Join-Path $SourceDir $f
        $dst = Join-Path $script:DataDir $f
        if ((Test-Path -LiteralPath $src) -and ($src -ne $dst)) { Copy-Item -LiteralPath $src -Destination $dst -Force }
        if (Test-Path -LiteralPath $dst) { Unblock-File -LiteralPath $dst -ErrorAction SilentlyContinue }
    }
    Protect-DataDir
    Join-Path $script:DataDir 'CleanIT.ps1'
}

function Install-Schedule {
    param([string]$SourceDir = (Split-Path -Parent $script:CorePath))
    $s = Get-Settings
    $dest = Copy-AppFiles $SourceDir
    $extra = ''; if ($s.ScheduleUpdates) { $extra = ' -Updates' }
    $at = [datetime]::ParseExact([string]$s.ScheduleTime, 'HH:mm', $null)
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                   -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`" -Clean -Silent -NoRestorePoint -Scheduled$extra"
    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $s.ScheduleDay -At $at
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'CleanIT weekly silent clean (default categories).' -Force | Out-Null

    # Companion task that shows "CleanIT freed X" to whoever is signed in (SYSTEM cannot show notifications).
    $nAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`" -Notify"
    $nPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $nSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $script:NotifyTaskName -Action $nAction -Principal $nPrincipal -Settings $nSettings `
        -Description 'Shows the CleanIT weekly clean result.' -Force | Out-Null

    if (Test-Schedule) { Write-Log "Scheduled '$($script:TaskName)': $($s.ScheduleDay)s $($s.ScheduleTime) (catches up if the PC was off)." 'OK' }
    else { Write-Log 'Could not create the scheduled task.' 'ERROR' }
}

function Remove-Schedule {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:NotifyTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Removed scheduled task '$($script:TaskName)'." 'OK'
}

function Invoke-Migration {
    # v1 was called "PC Cleanup" - swap its weekly task for the CleanIT one.
    if (Get-ScheduledTask -TaskName $script:OldTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:OldTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Removed old '$($script:OldTaskName)' task (PC Cleanup is now CleanIT)." 'OK'
        if (-not (Test-Schedule)) { Install-Schedule }
    }
}

function Get-CleanITIconBitmap {
    param([int]$Size = 64)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $teal = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(13, 148, 136))
    $g.FillEllipse($teal, 1, 1, $Size - 2, $Size - 2)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single]($Size * 0.12))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $m = [single]($Size * 0.24); $w = [single]($Size - 2 * $m)
    $g.DrawArc($pen, $m, $m, $w, $w, 45, 270)
    $spark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(253, 224, 71))
    $c = [single]($Size * 0.74); $r = [single]($Size * 0.1)
    $pts = @(
        (New-Object System.Drawing.PointF $c, ($c - $r)), (New-Object System.Drawing.PointF ($c + $r * 0.3), ($c - $r * 0.3)),
        (New-Object System.Drawing.PointF ($c + $r), $c), (New-Object System.Drawing.PointF ($c + $r * 0.3), ($c + $r * 0.3)),
        (New-Object System.Drawing.PointF $c, ($c + $r)), (New-Object System.Drawing.PointF ($c - $r * 0.3), ($c + $r * 0.3)),
        (New-Object System.Drawing.PointF ($c - $r), $c), (New-Object System.Drawing.PointF ($c - $r * 0.3), ($c - $r * 0.3)))
    $g.FillPolygon($spark, [System.Drawing.PointF[]]$pts)
    $g.Dispose()
    $bmp
}

function Save-CleanITIco {
    param([string]$Path)
    $bmp = Get-CleanITIconBitmap 256
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $fs = [IO.File]::Create($Path)
    $bw = New-Object IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)                 # ICONDIR
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)   # 256x256, no palette
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png)
    $bw.Close()
}

function Show-Notification {
    param([string]$Title, [string]$Text)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.Icon]::FromHandle((Get-CleanITIconBitmap 32).GetHicon())
    $ni.Text = 'CleanIT'
    $ni.Visible = $true
    $ni.ShowBalloonTip(10000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 8
    $ni.Dispose()
}

function Install-CleanITApp {
    param([string]$SourceDir)
    $main = Copy-AppFiles $SourceDir
    $ico = Join-Path $script:DataDir 'CleanIT.ico'
    Save-CleanITIco $ico
    $shell = New-Object -ComObject WScript.Shell
    $targets = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\CleanIT.lnk'),
        (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'CleanIT.lnk'))
    foreach ($t in $targets) {
        $lnk = $shell.CreateShortcut($t)
        $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$main`""
        $lnk.IconLocation = "$ico,0"
        $lnk.Description = 'CleanIT - clean, speed up and secure this PC'
        $lnk.WorkingDirectory = $script:DataDir
        $lnk.Save()
    }
    Write-Log "Installed to $($script:DataDir) with Start menu and desktop shortcuts." 'OK'
}

function Uninstall-CleanITApp {
    Remove-Schedule
    foreach ($t in @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\CleanIT.lnk'),
                     (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'CleanIT.lnk'))) {
        Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Shortcuts and scheduled tasks removed. Settings/logs/backups are kept in $($script:DataDir)." 'OK'
}
