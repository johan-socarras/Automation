# Duplicate Finder -- local web app.
# Starts a tiny local server (no internet, no external dependencies) and opens a page in your
# browser where you choose what to scan, search for a specific file/folder elsewhere on the
# computer, and delete selected duplicates (moved to the Recycle Bin, never permanent).
#
# Keep this PowerShell window open while using the page -- it's the engine behind it.
# Close the window (or press Ctrl+C) to stop the server.

Add-Type -AssemblyName System.Web

$ExcludeDirNames = @('node_modules', '.git', '__pycache__', 'venv', '.venv')

# ---------- Shared helpers (main thread) ----------

function Get-Presets {
    $userHome = $env:USERPROFILE
    $oneDrive = $env:OneDrive
    if (-not $oneDrive) { $oneDrive = Join-Path $userHome 'OneDrive' }

    # Prefer the local copy of each known folder. Only fall back to the OneDrive-redirected
    # path when there is no local folder at all (e.g. Desktop, which some setups redirect
    # entirely) -- so OneDrive is never offered as a second, duplicate option.
    $names = @('Desktop', 'Downloads', 'Documents', 'Pictures', 'Music', 'Videos')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $out = New-Object System.Collections.Generic.List[object]

    foreach ($name in $names) {
        $local = Join-Path $userHome $name
        $cloud = Join-Path $oneDrive $name
        $p = if (Test-Path -LiteralPath $local) { $local } elseif (Test-Path -LiteralPath $cloud) { $cloud } else { $null }
        if ($p -and $seen.Add((Resolve-Path -LiteralPath $p).ProviderPath)) {
            $out.Add([pscustomobject]@{ label = $name; path = $p; kind = 'preset' })
        }
    }

    return $out
}

function Get-BrowseListing {
    param([string]$Path, [bool]$IncludeFiles)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -in @('Fixed', 'Removable') }
        $dirs = @($drives | ForEach-Object { [pscustomobject]@{ name = $_.Name; path = $_.RootDirectory.FullName } })
        return [pscustomobject]@{ path = ''; parent = $null; dirs = $dirs; files = @(); error = $null }
    }

    try {
        $dirNames = [System.IO.Directory]::GetDirectories($Path)
    } catch {
        return [pscustomobject]@{ path = $Path; parent = (Split-Path $Path -Parent); dirs = @(); files = @(); error = $_.Exception.Message }
    }

    $dirs = @($dirNames | Sort-Object | ForEach-Object { [pscustomobject]@{ name = (Split-Path $_ -Leaf); path = $_ } })

    $files = @()
    if ($IncludeFiles) {
        try {
            $files = @([System.IO.Directory]::GetFiles($Path) | Sort-Object | ForEach-Object {
                [pscustomobject]@{ name = (Split-Path $_ -Leaf); path = $_ }
            })
        } catch { }
    }

    $parent = Split-Path $Path -Parent
    return [pscustomobject]@{ path = $Path; parent = $parent; dirs = $dirs; files = $files; error = $null }
}

# ---------- Background worker: full duplicate scan ----------

$ScanWorkerScript = {
    param($Folders, $State)

    $ExcludeDirNames = @('node_modules', '.git', '__pycache__', 'venv', '.venv')
    $FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000
    $FILE_ATTRIBUTE_OFFLINE = 0x00001000
    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase

    function Test-IsCloudOnly {
        param($Attributes)
        $raw = [int]$Attributes
        return (($raw -band $FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) -ne 0) -or (($raw -band $FILE_ATTRIBUTE_OFFLINE) -ne 0)
    }

    function Invoke-Walk {
        param([string]$RootPath, $AllDirs, $AllFiles)
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($RootPath)
        $AllDirs.Add($RootPath)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try { $dirs = [System.IO.Directory]::GetDirectories($current) } catch { $dirs = @() }
            foreach ($d in $dirs) {
                $name = Split-Path $d -Leaf
                if ($ExcludeDirNames -notcontains $name) {
                    $AllDirs.Add($d)
                    $stack.Push($d)
                }
            }
            try { $files = [System.IO.Directory]::GetFiles($current) } catch { $files = @() }
            foreach ($f in $files) { $AllFiles.Add($f) }
        }
    }

    function Get-Md5Hash {
        param([string]$Path)
        try {
            $md5 = [System.Security.Cryptography.MD5]::Create()
            try {
                $stream = [System.IO.File]::OpenRead($Path)
                try { $bytes = $md5.ComputeHash($stream) } finally { $stream.Dispose() }
            } finally { $md5.Dispose() }
            return [System.BitConverter]::ToString($bytes).Replace('-', '')
        } catch {
            return $null
        }
    }

    try {
        $State.Phase = 'walking'
        $allDirs = New-Object System.Collections.Generic.List[string]
        $allFiles = New-Object System.Collections.Generic.List[string]
        foreach ($folder in $Folders) {
            if (Test-Path -LiteralPath $folder) {
                Invoke-Walk -RootPath $folder -AllDirs $allDirs -AllFiles $allFiles
                $State.FilesFound = $allFiles.Count
            }
        }

        $State.Phase = 'reading-sizes'
        $fileSize = New-Object 'System.Collections.Generic.Dictionary[string,int64]' $ignoreCase
        $sizeMap = @{}
        $totalFiles = 0
        $skippedCloudOnly = 0

        foreach ($file in $allFiles) {
            try { $item = Get-Item -LiteralPath $file -ErrorAction Stop } catch { continue }
            if (Test-IsCloudOnly -Attributes $item.Attributes) { $skippedCloudOnly++; continue }
            $fileSize[$file] = $item.Length
            if (-not $sizeMap.ContainsKey($item.Length)) { $sizeMap[$item.Length] = New-Object System.Collections.Generic.List[string] }
            $sizeMap[$item.Length].Add($file)
            $totalFiles++
            $State.FilesRead = $totalFiles
        }
        $State.SkippedCloudOnly = $skippedCloudOnly

        $candidateGroups = @($sizeMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
        $candidateCount = 0
        foreach ($g in $candidateGroups) { $candidateCount += $g.Value.Count }
        $State.HashTotal = $candidateCount

        $State.Phase = 'hashing'
        $hashMap = @{}
        $hashedSoFar = 0
        foreach ($group in $candidateGroups) {
            foreach ($path in $group.Value) {
                $hash = Get-Md5Hash -Path $path
                $hashedSoFar++
                $State.Hashed = $hashedSoFar
                if ($hash) {
                    if (-not $hashMap.ContainsKey($hash)) { $hashMap[$hash] = New-Object System.Collections.Generic.List[string] }
                    $hashMap[$hash].Add($path)
                }
            }
        }

        $duplicateHashGroups = @($hashMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })

        $State.Phase = 'folder-matching'
        $fileToDupHash = New-Object 'System.Collections.Generic.Dictionary[string,string]' $ignoreCase
        foreach ($group in $duplicateHashGroups) {
            foreach ($path in $group.Value) { $fileToDupHash[$path] = $group.Key }
        }

        $filesByParent = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' $ignoreCase
        foreach ($f in $allFiles) {
            $parent = Split-Path $f -Parent
            if (-not $filesByParent.ContainsKey($parent)) { $filesByParent[$parent] = New-Object System.Collections.Generic.List[string] }
            $filesByParent[$parent].Add($f)
        }

        $dirsByParent = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' $ignoreCase
        foreach ($d in $allDirs) {
            $parent = Split-Path $d -Parent
            if ($parent) {
                if (-not $dirsByParent.ContainsKey($parent)) { $dirsByParent[$parent] = New-Object System.Collections.Generic.List[string] }
                $dirsByParent[$parent].Add($d)
            }
        }

        $dirSignature = New-Object 'System.Collections.Generic.Dictionary[string,string]' $ignoreCase
        foreach ($dir in ($allDirs | Sort-Object Length -Descending)) {
            $matched = $true
            $parts = New-Object System.Collections.Generic.List[string]

            if ($filesByParent.ContainsKey($dir)) {
                foreach ($f in $filesByParent[$dir]) {
                    if ($fileToDupHash.ContainsKey($f)) {
                        $parts.Add("F:" + (Split-Path $f -Leaf) + ":" + $fileToDupHash[$f])
                    } else {
                        $matched = $false
                    }
                }
            }

            if ($matched -and $dirsByParent.ContainsKey($dir)) {
                foreach ($sd in $dirsByParent[$dir]) {
                    if ($dirSignature.ContainsKey($sd)) {
                        $parts.Add("D:" + (Split-Path $sd -Leaf) + ":" + $dirSignature[$sd])
                    } else {
                        $matched = $false
                    }
                }
            }

            if ($matched -and $parts.Count -gt 0) {
                $dirSignature[$dir] = (($parts | Sort-Object) -join "|")
            }
        }

        $allDupDirs = New-Object 'System.Collections.Generic.HashSet[string]' $ignoreCase
        $sigGroups = $dirSignature.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 }
        foreach ($g in $sigGroups) { foreach ($entry in $g.Group) { [void]$allDupDirs.Add($entry.Key) } }

        function Get-FolderTotalSize {
            param([string]$Dir)
            $total = 0L
            if ($filesByParent.ContainsKey($Dir)) {
                foreach ($f in $filesByParent[$Dir]) { if ($fileSize.ContainsKey($f)) { $total += $fileSize[$f] } }
            }
            if ($dirsByParent.ContainsKey($Dir)) {
                foreach ($sd in $dirsByParent[$Dir]) { $total += (Get-FolderTotalSize -Dir $sd) }
            }
            return $total
        }

        $folderResults = New-Object System.Collections.Generic.List[object]
        foreach ($g in $sigGroups) {
            $topMembers = @($g.Group | Where-Object {
                $parent = Split-Path $_.Key -Parent
                -not $allDupDirs.Contains($parent)
            } | ForEach-Object { $_.Key })

            if ($topMembers.Count -ge 2) {
                $sizeEach = Get-FolderTotalSize -Dir $topMembers[0]
                $folderResults.Add([pscustomobject]@{
                    type   = 'Folder'
                    paths  = $topMembers
                    size   = $sizeEach
                    wasted = $sizeEach * ($topMembers.Count - 1)
                })
            }
        }

        $coveredPrefixes = @($folderResults | ForEach-Object { $_.paths } | ForEach-Object { $_ + '\' })
        function Test-UnderCoveredFolder {
            param([string]$Path)
            foreach ($prefix in $coveredPrefixes) {
                if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
        }

        $fileResults = New-Object System.Collections.Generic.List[object]
        foreach ($group in $duplicateHashGroups) {
            $remaining = @($group.Value | Where-Object { -not (Test-UnderCoveredFolder -Path $_) })
            if ($remaining.Count -ge 2) {
                $size = $fileSize[$remaining[0]]
                $fileResults.Add([pscustomobject]@{
                    type   = 'File'
                    paths  = $remaining
                    size   = $size
                    wasted = $size * ($remaining.Count - 1)
                })
            }
        }

        $allResults = @(@($folderResults + $fileResults) | Sort-Object -Property wasted -Descending)
        $totalWasted = ($allResults | Measure-Object -Property wasted -Sum).Sum
        if (-not $totalWasted) { $totalWasted = 0 }

        $State.Result = [pscustomobject]@{
            totalWasted  = $totalWasted
            folderCount  = $folderResults.Count
            fileCount    = $fileResults.Count
            items        = $allResults
        }
        $State.Phase = 'done'
        $State.Status = 'done'
    } catch {
        $State.Status = 'error'
        $State.Error = "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    }
}

# ---------- Background worker: search one specific file/folder elsewhere ----------

$SearchWorkerScript = {
    param($TargetPath, $ScopeFolders, $State)

    $ExcludeDirNames = @('node_modules', '.git', '__pycache__', 'venv', '.venv')
    $FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000
    $FILE_ATTRIBUTE_OFFLINE = 0x00001000
    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase

    function Test-IsCloudOnly {
        param($Attributes)
        $raw = [int]$Attributes
        return (($raw -band $FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) -ne 0) -or (($raw -band $FILE_ATTRIBUTE_OFFLINE) -ne 0)
    }

    function Invoke-Walk {
        param([string]$RootPath, $AllFiles)
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($RootPath)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try { $dirs = [System.IO.Directory]::GetDirectories($current) } catch { $dirs = @() }
            foreach ($d in $dirs) {
                $name = Split-Path $d -Leaf
                if ($ExcludeDirNames -notcontains $name) { $stack.Push($d) }
            }
            try { $files = [System.IO.Directory]::GetFiles($current) } catch { $files = @() }
            foreach ($f in $files) { $AllFiles.Add($f) }
        }
    }

    function Get-Md5Hash {
        param([string]$Path)
        try {
            $md5 = [System.Security.Cryptography.MD5]::Create()
            try {
                $stream = [System.IO.File]::OpenRead($Path)
                try { $bytes = $md5.ComputeHash($stream) } finally { $stream.Dispose() }
            } finally { $md5.Dispose() }
            return [System.BitConverter]::ToString($bytes).Replace('-', '')
        } catch {
            return $null
        }
    }

    try {
        $State.Phase = 'hashing-target'
        $isFolder = Test-Path -LiteralPath $TargetPath -PathType Container
        $targetFiles = New-Object System.Collections.Generic.List[string]
        if ($isFolder) {
            Invoke-Walk -RootPath $TargetPath -AllFiles $targetFiles
        } else {
            $targetFiles.Add($TargetPath)
        }
        $State.TargetFileCount = $targetFiles.Count

        # hash -> list of relative labels (in case of internal dupes within the target itself)
        $targetHashes = @{}
        $targetPrefix = $TargetPath.TrimEnd('\') + '\'
        foreach ($f in $targetFiles) {
            try { $item = Get-Item -LiteralPath $f -ErrorAction Stop } catch { continue }
            if (Test-IsCloudOnly -Attributes $item.Attributes) { continue }
            $hash = Get-Md5Hash -Path $f
            if (-not $hash) { continue }
            $relLabel = if ($isFolder -and $f.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $f.Substring($targetPrefix.Length)
            } else {
                Split-Path $f -Leaf
            }
            if (-not $targetHashes.ContainsKey($hash)) {
                $targetHashes[$hash] = [pscustomobject]@{ label = $relLabel; size = $item.Length; matches = New-Object System.Collections.Generic.List[string] }
            }
        }

        $State.Phase = 'scanning-scope'
        $scopeFiles = New-Object System.Collections.Generic.List[string]
        foreach ($folder in $ScopeFolders) {
            if (Test-Path -LiteralPath $folder) { Invoke-Walk -RootPath $folder -AllFiles $scopeFiles }
        }
        $State.ScopeFileCount = $scopeFiles.Count

        $scanned = 0
        foreach ($f in $scopeFiles) {
            $scanned++
            $State.ScannedCount = $scanned
            if ($f.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or ($f -ieq $TargetPath)) { continue }
            try { $item = Get-Item -LiteralPath $f -ErrorAction Stop } catch { continue }
            if (Test-IsCloudOnly -Attributes $item.Attributes) { continue }

            foreach ($kv in $targetHashes.GetEnumerator()) {
                if ($kv.Value.size -ne $item.Length) { continue }
            }
            $sizeMatches = @($targetHashes.GetEnumerator() | Where-Object { $_.Value.size -eq $item.Length })
            if ($sizeMatches.Count -eq 0) { continue }

            $hash = Get-Md5Hash -Path $f
            if (-not $hash) { continue }
            if ($targetHashes.ContainsKey($hash)) {
                $targetHashes[$hash].matches.Add($f)
            }
        }

        $items = New-Object System.Collections.Generic.List[object]
        foreach ($kv in $targetHashes.GetEnumerator()) {
            if ($kv.Value.matches.Count -gt 0) {
                $items.Add([pscustomobject]@{
                    targetLabel = $kv.Value.label
                    size        = $kv.Value.size
                    matches     = $kv.Value.matches.ToArray()
                })
            }
        }

        $State.Result = [pscustomobject]@{
            targetPath = $TargetPath
            isFolder   = $isFolder
            items      = $items.ToArray()
            totalMatches = ($items | Measure-Object).Count
        }
        $State.Phase = 'done'
        $State.Status = 'done'
    } catch {
        $State.Status = 'error'
        $State.Error = "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    }
}

# ---------- HTTP plumbing ----------

function Write-JsonResponse {
    param($Response, $Data, [int]$StatusCode = 200)
    # -InputObject (not a pipe) so a single-element collection isn't unwrapped to a bare object.
    $json = ConvertTo-Json -InputObject $Data -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-HtmlResponse {
    param($Response, [string]$Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Response.ContentType = 'text/html; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-JsonBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $text = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

$Global:Jobs = [hashtable]::Synchronized(@{})
$Global:JobHandles = @{}
$Global:JobCounter = 0

function New-BackgroundJob {
    param([scriptblock]$Script, [object[]]$ArgList)
    $Global:JobCounter++
    $id = "job$($Global:JobCounter)"
    $state = [hashtable]::Synchronized(@{ Status = 'running'; Phase = 'starting'; Error = $null; Result = $null })
    $Global:Jobs[$id] = $state

    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    [void]$ps.AddArgument($state)
    $handle = $ps.BeginInvoke()
    $Global:JobHandles[$id] = @{ PS = $ps; Handle = $handle }
    return $id
}

# ---------- Front-end (single page app) ----------

$Html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Duplicate Finder</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f5f6f8; --card: #ffffff; --text: #1a1d23; --muted: #6b7280;
    --border: #e3e5e8; --accent: #2f6feb; --accent-bg: #eaf0ff; --danger: #d64545; --danger-bg: #fdecec;
    --folder-badge: #eef2ff; --folder-text: #4338ca;
    --file-badge: #f0fdf4; --file-text: #15803d;
    --ok-bg: #f0fdf4; --ok-text: #15803d;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14161a; --card: #1d2026; --text: #e8eaed; --muted: #9aa0a6;
      --border: #2c2f36; --accent: #6c9bff; --accent-bg: #1c2540; --danger: #ff6b6b; --danger-bg: #3a1f1f;
      --folder-badge: #26264a; --folder-text: #a5b4fc;
      --file-badge: #1c3324; --file-text: #86efac;
      --ok-bg: #1c3324; --ok-text: #86efac;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; background: var(--bg); color: var(--text); padding-bottom: 70px; }
  header { position: sticky; top: 0; background: var(--bg); z-index: 10; padding: 16px 24px 10px; border-bottom: 1px solid var(--border); }
  h1 { font-size: 20px; margin: 0 0 2px; }
  .subtitle { font-size: 12px; color: var(--muted); }
  main { padding: 16px 24px 24px; max-width: 1100px; margin: 0 auto; }
  .tabs { display: flex; gap: 8px; margin: 14px 0; }
  .tab { padding: 8px 14px; border-radius: 8px; border: 1px solid var(--border); background: var(--card); cursor: pointer; font-size: 13px; }
  .tab.active { background: var(--accent); color: white; border-color: var(--accent); }
  .view { display: none; }
  .view.active { display: block; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 16px; margin-bottom: 14px; }
  .card h2 { font-size: 14px; margin: 0 0 10px; }
  .chips { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 10px; }
  .chip { background: var(--accent-bg); color: var(--accent); border-radius: 20px; padding: 6px 12px; font-size: 13px; display: flex; align-items: center; gap: 8px; }
  .chip button { border: none; background: none; color: inherit; cursor: pointer; font-weight: bold; padding: 0; }
  label.preset { display: inline-flex; align-items: center; gap: 6px; margin: 4px 10px 4px 0; font-size: 13px; }
  .browser { border: 1px solid var(--border); border-radius: 8px; padding: 10px; margin-top: 8px; }
  .browser .path-bar { display: flex; gap: 8px; margin-bottom: 8px; }
  .browser .path-bar input { flex: 1; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--border); background: var(--bg); color: var(--text); font-size: 13px; }
  .browser .entries { max-height: 260px; overflow-y: auto; }
  .entry-row { display: flex; align-items: center; gap: 8px; padding: 6px 4px; font-size: 13px; border-radius: 6px; }
  .entry-row:hover { background: var(--bg); }
  .entry-row .name { flex: 1; cursor: pointer; }
  .entry-row.file .name { color: var(--muted); }
  input[type=text] { padding: 9px 12px; border-radius: 8px; border: 1px solid var(--border); background: var(--card); color: var(--text); font-size: 14px; }
  select, button { padding: 9px 12px; border-radius: 8px; border: 1px solid var(--border); background: var(--card); color: var(--text); font-size: 14px; cursor: pointer; }
  button.primary { background: var(--accent); color: white; border: none; }
  button.danger { background: var(--danger-bg); color: var(--danger); border: 1px solid var(--danger); }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  button.small { padding: 4px 10px; font-size: 12px; }
  .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  .progress-box { text-align: center; padding: 40px 0; }
  .progress-box .phase { font-size: 16px; margin-bottom: 10px; }
  .progress-box .counts { color: var(--muted); font-size: 13px; }
  .stats { display: flex; gap: 24px; flex-wrap: wrap; margin: 12px 0; }
  .stat { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 10px 16px; min-width: 140px; }
  .stat .num { font-size: 22px; font-weight: 700; }
  .stat .label { font-size: 12px; color: var(--muted); }
  .controls { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin: 10px 0; }
  .controls input[type=text] { flex: 1; min-width: 220px; }
  .group { background: var(--card); border: 1px solid var(--border); border-radius: 10px; margin-bottom: 10px; overflow: hidden; }
  .group-head { display: flex; align-items: center; gap: 12px; padding: 12px 16px; cursor: pointer; }
  .badge { font-size: 11px; font-weight: 700; padding: 3px 8px; border-radius: 6px; text-transform: uppercase; letter-spacing: .03em; }
  .badge.folder { background: var(--folder-badge); color: var(--folder-text); }
  .badge.file { background: var(--file-badge); color: var(--file-text); }
  .wasted { font-weight: 700; white-space: nowrap; }
  .copies { color: var(--muted); font-size: 13px; white-space: nowrap; }
  .first-path { color: var(--muted); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; }
  .chevron { transition: transform .15s; color: var(--muted); }
  .group.open .chevron { transform: rotate(90deg); }
  .paths { display: none; }
  .group.open .paths { display: block; }
  .path-row { display: flex; align-items: center; gap: 10px; padding: 9px 16px; font-family: Consolas, monospace; font-size: 13px; border-top: 1px solid var(--border); }
  .path-row span.p { flex: 1; word-break: break-all; }
  .path-row button { padding: 4px 10px; font-size: 12px; }
  .keep-tag { font-size: 11px; color: var(--muted); border: 1px solid var(--border); border-radius: 6px; padding: 2px 6px; white-space: nowrap; }
  .status-tag { font-size: 11px; border-radius: 6px; padding: 2px 6px; white-space: nowrap; }
  .status-tag.ok { background: var(--ok-bg); color: var(--ok-text); }
  .status-tag.fail { background: var(--danger-bg); color: var(--danger); }
  footer.bar { position: fixed; bottom: 0; left: 0; right: 0; background: var(--card); border-top: 1px solid var(--border); padding: 12px 24px; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
  .note { font-size: 12px; color: var(--muted); max-width: 560px; }
  .empty { text-align: center; color: var(--muted); padding: 40px; }
</style>
</head>
<body>
<header>
  <h1>Duplicate Finder</h1>
  <div class="subtitle">Keep this window's PowerShell process running while you use the page.</div>
  <div class="tabs">
    <div class="tab active" data-tab="scan">Scan for duplicates</div>
    <div class="tab" data-tab="find">Find a specific file/folder</div>
  </div>
</header>
<main>

  <div class="view active" id="view-setup">
    <div class="card" id="scan-setup">
      <h2>Locations to scan</h2>
      <div id="presetList"></div>
      <div class="chips" id="scanChips"></div>
      <div id="scanBrowser"></div>
      <div class="row" style="margin-top:12px;">
        <button class="primary" id="startScanBtn" disabled>Start scan</button>
      </div>
    </div>

    <div class="card" id="find-setup" style="display:none;">
      <h2>1. Pick the file or folder to check</h2>
      <div id="targetChip"></div>
      <div id="targetBrowser"></div>
      <h2 style="margin-top:16px;">2. Where should I look for copies of it?</h2>
      <div id="presetList2"></div>
      <div class="chips" id="scopeChips"></div>
      <div id="scopeBrowser"></div>
      <div class="row" style="margin-top:12px;">
        <button class="primary" id="startFindBtn" disabled>Search</button>
      </div>
    </div>
  </div>

  <div class="view" id="view-progress">
    <div class="progress-box">
      <div class="phase" id="progressPhase">Working...</div>
      <div class="counts" id="progressCounts"></div>
    </div>
  </div>

  <div class="view" id="view-results">
    <div class="stats" id="resultStats"></div>
    <div class="controls">
      <input type="text" id="search" placeholder="Filter by path...">
      <select id="sortBy">
        <option value="wasted">Sort: space wasted</option>
        <option value="count">Sort: number of copies</option>
        <option value="path">Sort: path (A-Z)</option>
      </select>
      <select id="typeFilter">
        <option value="">All types</option>
        <option value="Folder">Folders only</option>
        <option value="File">Files only</option>
      </select>
      <button id="backBtn">&larr; New search</button>
    </div>
    <div id="list"></div>
  </div>

</main>
<footer class="bar">
  <div class="note">Checking a box only marks it here. Nothing is deleted until you click the button and confirm. Deleted items go to the Recycle Bin (not permanently deleted).</div>
  <button class="danger" id="deleteBtn" disabled>Delete selected (0)</button>
</footer>
<script>
let currentData = [];
let selected = new Set();
let scanFolders = new Set();
let scopeFolders = new Set();
let targetPath = null;
let activeJobId = null;
let activeJobKind = null;

function fmtBytes(b) {
  const units = ['B','KB','MB','GB','TB'];
  let i = 0;
  while (b >= 1024 && i < units.length - 1) { b /= 1024; i++; }
  return b.toFixed(2) + ' ' + units[i];
}

function showView(id) {
  document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
  document.getElementById(id).classList.add('active');
}

document.querySelectorAll('.tab').forEach(tab => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    tab.classList.add('active');
    document.getElementById('scan-setup').style.display = tab.dataset.tab === 'scan' ? '' : 'none';
    document.getElementById('find-setup').style.display = tab.dataset.tab === 'find' ? '' : 'none';
    showView('view-setup');
  });
});

// ---------- Presets ----------

async function loadPresets() {
  const res = await fetch('/api/presets');
  const presets = await res.json();
  const render = (containerId, set, chipContainerId) => {
    const container = document.getElementById(containerId);
    container.innerHTML = presets.map((p, i) => `
      <label class="preset"><input type="checkbox" data-path="${encodeURIComponent(p.path)}" onchange="onPresetToggle(this, '${chipContainerId}')"> ${p.label} <span style="color:var(--muted);font-size:11px;">${p.path}</span></label>
    `).join('');
  };
  render('presetList', scanFolders, 'scanChips');
  render('presetList2', scopeFolders, 'scopeChips');
}

function onPresetToggle(cb, chipContainerId) {
  const path = decodeURIComponent(cb.getAttribute('data-path'));
  const set = chipContainerId === 'scanChips' ? scanFolders : scopeFolders;
  if (cb.checked) set.add(path); else set.delete(path);
  renderChips(chipContainerId, set);
}

function renderChips(containerId, set) {
  const container = document.getElementById(containerId);
  container.innerHTML = Array.from(set).map(p => `
    <span class="chip">${p} <button onclick="removeFromSet('${containerId}', '${encodeURIComponent(p)}')">&times;</button></span>
  `).join('');
  document.getElementById('startScanBtn').disabled = scanFolders.size === 0;
  document.getElementById('startFindBtn').disabled = !(targetPath && scopeFolders.size > 0);
}

function removeFromSet(containerId, encPath) {
  const path = decodeURIComponent(encPath);
  const set = containerId === 'scanChips' ? scanFolders : scopeFolders;
  set.delete(path);
  renderChips(containerId, set);
  document.querySelectorAll(`#presetList input, #presetList2 input`).forEach(cb => {
    if (decodeURIComponent(cb.getAttribute('data-path')) === path) cb.checked = false;
  });
}

// ---------- Folder/file browser ----------

function makeBrowser(containerId, opts) {
  const container = document.getElementById(containerId);
  let currentPath = '';

  async function load(path) {
    currentPath = path;
    const filesParam = opts.includeFiles ? '&files=1' : '';
    const res = await fetch('/api/browse?path=' + encodeURIComponent(path || '') + filesParam);
    const data = await res.json();
    container.innerHTML = `
      <div class="browser">
        <div class="path-bar">
          <input type="text" value="${data.path || ''}" placeholder="Type a path and press Enter..." id="${containerId}-input">
          ${data.parent ? `<button class="small" id="${containerId}-up">Up</button>` : ''}
          <button class="small primary" id="${containerId}-add">${opts.addLabel}</button>
        </div>
        <div class="entries" id="${containerId}-entries">
          ${data.error ? `<div class="note">Can't list this folder: ${data.error}</div>` : ''}
          ${(data.dirs || []).map(d => `<div class="entry-row dir"><span>&#128193;</span><span class="name" data-path="${encodeURIComponent(d.path)}">${d.name}</span></div>`).join('')}
          ${opts.includeFiles ? (data.files || []).map(f => `
            <div class="entry-row file">
              <span>&#128196;</span><span class="name">${f.name}</span>
              <button class="small" data-path="${encodeURIComponent(f.path)}" data-pickfile="1">Select file</button>
            </div>`).join('') : ''}
        </div>
      </div>
    `;
    container.querySelectorAll('.entry-row.dir .name').forEach(el => {
      el.addEventListener('click', () => load(decodeURIComponent(el.getAttribute('data-path'))));
    });
    container.querySelectorAll('[data-pickfile]').forEach(btn => {
      btn.addEventListener('click', () => opts.onPickFile(decodeURIComponent(btn.getAttribute('data-path'))));
    });
    const upBtn = document.getElementById(containerId + '-up');
    if (upBtn) upBtn.addEventListener('click', () => load(data.parent));
    document.getElementById(containerId + '-add').addEventListener('click', () => opts.onAddFolder(currentPath));
    const input = document.getElementById(containerId + '-input');
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') load(input.value); });
  }

  load('');
}

makeBrowser('scanBrowser', {
  addLabel: 'Add this folder',
  includeFiles: false,
  onAddFolder: (path) => { if (path) { scanFolders.add(path); renderChips('scanChips', scanFolders); } }
});

makeBrowser('scopeBrowser', {
  addLabel: 'Add this folder',
  includeFiles: false,
  onAddFolder: (path) => { if (path) { scopeFolders.add(path); renderChips('scopeChips', scopeFolders); } }
});

makeBrowser('targetBrowser', {
  addLabel: 'Use this folder as the target',
  includeFiles: true,
  onAddFolder: (path) => { if (path) setTarget(path); },
  onPickFile: (path) => setTarget(path)
});

function setTarget(path) {
  targetPath = path;
  document.getElementById('targetChip').innerHTML = `<span class="chip">${path}</span>`;
  document.getElementById('startFindBtn').disabled = !(targetPath && scopeFolders.size > 0);
}

// ---------- Start scan / find ----------

document.getElementById('startScanBtn').addEventListener('click', async () => {
  const res = await fetch('/api/scan/start', {
    method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ folders: Array.from(scanFolders) })
  });
  const data = await res.json();
  activeJobId = data.id;
  activeJobKind = 'scan';
  showView('view-progress');
  pollProgress();
});

document.getElementById('startFindBtn').addEventListener('click', async () => {
  const res = await fetch('/api/search-item/start', {
    method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ target: targetPath, scopeFolders: Array.from(scopeFolders) })
  });
  const data = await res.json();
  activeJobId = data.id;
  activeJobKind = 'find';
  showView('view-progress');
  pollProgress();
});

async function pollProgress() {
  const res = await fetch('/api/job/progress?id=' + encodeURIComponent(activeJobId));
  const s = await res.json();

  if (activeJobKind === 'scan') {
    const phaseLabel = { walking: 'Scanning folders...', 'reading-sizes': 'Reading file sizes...', hashing: 'Comparing file contents...', 'folder-matching': 'Looking for duplicated folders...', done: 'Done' }[s.phase] || s.phase;
    document.getElementById('progressPhase').textContent = phaseLabel;
    let counts = `${s.filesFound || 0} files found`;
    if (s.filesRead) counts += ` &middot; ${s.filesRead} read`;
    if (s.hashTotal) counts += ` &middot; hashed ${s.hashed || 0}/${s.hashTotal}`;
    document.getElementById('progressCounts').innerHTML = counts;
  } else {
    const phaseLabel = { 'hashing-target': 'Reading your target...', 'scanning-scope': 'Searching the locations you picked...', done: 'Done' }[s.phase] || s.phase;
    document.getElementById('progressPhase').textContent = phaseLabel;
    let counts = '';
    if (s.targetFileCount) counts += `${s.targetFileCount} target file(s)`;
    if (s.scopeFileCount) counts += ` &middot; scanning ${s.scannedCount || 0}/${s.scopeFileCount}`;
    document.getElementById('progressCounts').innerHTML = counts;
  }

  if (s.status === 'error') {
    document.getElementById('progressPhase').textContent = 'Something went wrong: ' + s.error;
    return;
  }
  if (s.status === 'done') {
    if (activeJobKind === 'scan') {
      showScanResults(s.result);
    } else {
      showFindResults(s.result);
    }
    return;
  }
  setTimeout(pollProgress, 700);
}

document.getElementById('backBtn').addEventListener('click', () => { showView('view-setup'); selected.clear(); updateFooter(); });

// ---------- Results (shared renderer for scan + find) ----------

function showScanResults(result) {
  currentData = (result.items || []).map(it => ({ type: it.type, size: it.size, wasted: it.wasted, paths: it.paths }));
  document.getElementById('resultStats').innerHTML = `
    <div class="stat"><div class="num">${fmtBytes(result.totalWasted || 0)}</div><div class="label">Space you could free</div></div>
    <div class="stat"><div class="num">${result.folderCount || 0}</div><div class="label">Duplicate folder sets</div></div>
    <div class="stat"><div class="num">${result.fileCount || 0}</div><div class="label">Duplicate file sets</div></div>
  `;
  document.getElementById('typeFilter').style.display = '';
  selected.clear();
  showView('view-results');
  render();
}

function showFindResults(result) {
  currentData = (result.items || []).map(it => ({ type: 'Match', size: it.size, wasted: it.size * it.matches.length, paths: [result.targetPath, ...it.matches], targetLabel: it.targetLabel }));
  document.getElementById('resultStats').innerHTML = `
    <div class="stat"><div class="num">${result.totalMatches || 0}</div><div class="label">Item(s) with copies found</div></div>
  `;
  document.getElementById('typeFilter').style.display = 'none';
  selected.clear();
  showView('view-results');
  render();
}

function render() {
  const q = document.getElementById('search').value.toLowerCase();
  const sortBy = document.getElementById('sortBy').value;
  const typeFilter = document.getElementById('typeFilter').value;

  let items = currentData.filter(d => {
    if (typeFilter && d.type !== typeFilter) return false;
    if (!q) return true;
    return d.paths.some(p => p.toLowerCase().includes(q));
  });

  items = items.slice().sort((a, b) => {
    if (sortBy === 'wasted') return b.wasted - a.wasted;
    if (sortBy === 'count') return b.paths.length - a.paths.length;
    if (sortBy === 'path') return a.paths[0].localeCompare(b.paths[0]);
    return 0;
  });

  const list = document.getElementById('list');
  list.innerHTML = '';

  if (items.length === 0) {
    list.innerHTML = '<div class="empty">No matches.</div>';
    return;
  }

  items.forEach(d => {
    const div = document.createElement('div');
    div.className = 'group';
    const badgeLabel = d.type === 'Match' ? (d.targetLabel || 'Match') : d.type;
    const badgeClass = d.type === 'Folder' ? 'folder' : 'file';
    div.innerHTML = `
      <div class="group-head">
        <span class="chevron">&#9656;</span>
        <span class="badge ${badgeClass}">${badgeLabel}</span>
        <span class="wasted">${fmtBytes(d.wasted)} wasted</span>
        <span class="copies">${d.paths.length} location(s)</span>
        <span class="first-path">${d.paths[0]}</span>
      </div>
      <div class="paths">
        ${d.paths.map((p, i) => `
          <div class="path-row" data-path="${encodeURIComponent(p)}">
            <input type="checkbox" data-path="${encodeURIComponent(p)}" onclick="toggleSelect(this)">
            <span class="p">${p}</span>
            <button onclick="revealPath(event, '${encodeURIComponent(p)}')">Show in Explorer</button>
          </div>
        `).join('')}
      </div>
    `;
    div.querySelector('.group-head').addEventListener('click', () => div.classList.toggle('open'));
    list.appendChild(div);
  });
}

function toggleSelect(cb) {
  const path = decodeURIComponent(cb.getAttribute('data-path'));
  const groupEl = cb.closest('.paths');
  const boxes = Array.from(groupEl.querySelectorAll('input[type=checkbox]'));
  const checkedCount = boxes.filter(b => b.checked).length;
  if (cb.checked && checkedCount === boxes.length) {
    cb.checked = false;
    alert('At least one copy has to stay -- uncheck another one in this group first.');
    return;
  }
  if (cb.checked) selected.add(path); else selected.delete(path);
  updateFooter();
}

function revealPath(ev, encPath) {
  ev.stopPropagation();
  const path = decodeURIComponent(encPath);
  const btn = ev.target;
  const old = btn.textContent;
  fetch('/api/reveal', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ path }) })
    .then(r => r.json())
    .then(data => {
      if (!data.ok) {
        btn.textContent = data.error || 'Not found';
        setTimeout(() => { btn.textContent = old; }, 1500);
      }
    })
    .catch(() => {
      btn.textContent = 'Failed';
      setTimeout(() => { btn.textContent = old; }, 1500);
    });
}

function updateFooter() {
  const btn = document.getElementById('deleteBtn');
  btn.textContent = 'Delete selected (' + selected.size + ')';
  btn.disabled = selected.size === 0;
}

document.getElementById('deleteBtn').addEventListener('click', async () => {
  const paths = Array.from(selected);
  if (paths.length === 0) return;
  if (!confirm(`Move ${paths.length} item(s) to the Recycle Bin?\n\nThis can be undone from the Recycle Bin, but review the list before continuing.`)) return;

  const res = await fetch('/api/delete', {
    method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ paths })
  });
  const data = await res.json();

  data.results.forEach(r => {
    const row = document.querySelector(`.path-row[data-path="${encodeURIComponent(r.path)}"]`);
    if (row) {
      const tag = document.createElement('span');
      tag.className = 'status-tag ' + (r.ok ? 'ok' : 'fail');
      tag.textContent = r.ok ? 'Recycled' : ('Failed: ' + r.error);
      row.appendChild(tag);
      if (r.ok) {
        const cb = row.querySelector('input[type=checkbox]');
        cb.disabled = true;
        cb.checked = false;
        selected.delete(r.path);
      }
    }
  });
  updateFooter();
});

document.getElementById('search').addEventListener('input', render);
document.getElementById('sortBy').addEventListener('change', render);
document.getElementById('typeFilter').addEventListener('change', render);

loadPresets();
</script>
</body>
</html>
'@

# ---------- Server loop ----------

$port = 8791
$listener = $null
for ($p = $port; $p -lt $port + 10; $p++) {
    try {
        $candidate = New-Object System.Net.HttpListener
        $candidate.Prefixes.Add("http://localhost:$p/")
        $candidate.Start()
        $listener = $candidate
        $port = $p
        break
    } catch {
        continue
    }
}

if (-not $listener) {
    Write-Host "Could not start the local server (no free port found)."
    exit 1
}

Write-Host "Duplicate Finder running at http://localhost:$port/"
Write-Host "Keep this window open while you use the page. Press Ctrl+C to stop."
Start-Process "http://localhost:$port/"

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod

        if ($method -eq 'GET' -and $path -eq '/') {
            Write-HtmlResponse -Response $response -Html $Html
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/presets') {
            Write-JsonResponse -Response $response -Data (Get-Presets)
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/browse') {
            $qs = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $reqPath = $qs['path']
            $includeFiles = $qs['files'] -eq '1'
            Write-JsonResponse -Response $response -Data (Get-BrowseListing -Path $reqPath -IncludeFiles $includeFiles)
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/scan/start') {
            $body = Read-JsonBody -Request $request
            $folders = @($body.folders)
            $id = New-BackgroundJob -Script $ScanWorkerScript -ArgList @(, $folders)
            Write-JsonResponse -Response $response -Data @{ id = $id }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/search-item/start') {
            $body = Read-JsonBody -Request $request
            $scope = @($body.scopeFolders)
            $id = New-BackgroundJob -Script $SearchWorkerScript -ArgList @($body.target, $scope)
            Write-JsonResponse -Response $response -Data @{ id = $id }
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/job/progress') {
            $qs = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $id = $qs['id']
            if ($Global:Jobs.ContainsKey($id)) {
                $state = $Global:Jobs[$id]
                $data = @{
                    status = $state.Status; phase = $state.Phase; error = $state.Error
                    filesFound = $state.FilesFound; filesRead = $state.FilesRead
                    hashTotal = $state.HashTotal; hashed = $state.Hashed
                    targetFileCount = $state.TargetFileCount; scopeFileCount = $state.ScopeFileCount; scannedCount = $state.ScannedCount
                    result = $state.Result
                }
                Write-JsonResponse -Response $response -Data $data
                if ($state.Status -in @('done', 'error') -and $Global:JobHandles.ContainsKey($id)) {
                    try {
                        $j = $Global:JobHandles[$id]
                        $j.PS.EndInvoke($j.Handle) | Out-Null
                        $j.PS.Dispose()
                    } catch { }
                    $Global:JobHandles.Remove($id)
                }
            } else {
                Write-JsonResponse -Response $response -Data @{ status = 'unknown' } -StatusCode 404
            }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/delete') {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $body = Read-JsonBody -Request $request
            $results = New-Object System.Collections.Generic.List[object]
            foreach ($p in @($body.paths)) {
                try {
                    if (-not (Test-Path -LiteralPath $p)) {
                        $results.Add(@{ path = $p; ok = $false; error = 'Not found' })
                        continue
                    }
                    if (Test-Path -LiteralPath $p -PathType Container) {
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
                    } else {
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
                    }
                    $results.Add(@{ path = $p; ok = $true; error = $null })
                } catch {
                    $results.Add(@{ path = $p; ok = $false; error = $_.Exception.Message })
                }
            }
            Write-JsonResponse -Response $response -Data @{ results = $results }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/reveal') {
            $body = Read-JsonBody -Request $request
            $p = $body.path
            if (-not (Test-Path -LiteralPath $p)) {
                Write-JsonResponse -Response $response -Data @{ ok = $false; error = 'Not found' }
            } else {
                try {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$p`""
                    Write-JsonResponse -Response $response -Data @{ ok = $true }
                } catch {
                    Write-JsonResponse -Response $response -Data @{ ok = $false; error = $_.Exception.Message }
                }
            }
        }
        else {
            $response.StatusCode = 404
            Write-JsonResponse -Response $response -Data @{ error = 'not found' } -StatusCode 404
        }
    } catch {
        try {
            $response.StatusCode = 500
            Write-JsonResponse -Response $response -Data @{ error = $_.Exception.Message } -StatusCode 500
        } catch { }
    } finally {
        $response.OutputStream.Close()
    }
}
