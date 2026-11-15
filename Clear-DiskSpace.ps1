#Requires -Version 5.1
<#
.SYNOPSIS
    Reclaims disk space on Windows by clearing safe, regenerable caches and junk.

.DESCRIPTION
    Clear-DiskSpace scans well-known space hogs (temp files, crash dumps, leftover
    driver installers, GPU shader caches, old app versions, package-manager and build
    caches, browser caches, Windows Update leftovers) and removes only data that the
    system or your tools recreate on demand. Nothing in your documents, projects, or
    installed programs is touched.

    Claude / Claude Code data is never touched: any path with a folder named
    claude*, .claude* or anthropic* is protected, even inside a folder being cleared.

    By default it runs in DRY-RUN mode and only reports what *would* be freed.
    Re-run with -Execute to actually delete.

.PARAMETER Execute
    Actually delete. Without this switch the script only previews (dry run).

.PARAMETER IncludeDevCaches
    Also clear developer build/package caches (Gradle, npm, pnpm, Yarn, pip, uv, Deno,
    NuGet, node-gyp, TypeScript). These are safe but will make your next build/install
    slower while they rebuild.

.PARAMETER IncludeBrowserCaches
    Also clear browser and app web caches: Chrome, Edge (all profiles), Firefox (all
    profiles), Discord, Steam. Not history, passwords, or cookies. Close those apps
    first; a cache whose app is running is skipped.

.PARAMETER RunDism
    Also run DISM component-store cleanup (/StartComponentCleanup). Requires admin
    and can take 10-30 minutes. Skipped automatically if not elevated.

.PARAMETER Yes
    Skip the confirmation prompt before deleting.

.EXAMPLE
    .\Clear-DiskSpace.ps1
    Preview everything that would be cleaned (safe, no changes).

.EXAMPLE
    .\Clear-DiskSpace.ps1 -Execute
    Clean the default safe targets.

.EXAMPLE
    .\Clear-DiskSpace.ps1 -Execute -IncludeDevCaches -IncludeBrowserCaches
    Full cleanup including developer and browser caches.

.NOTES
    Run an elevated (Administrator) session to also reach system-level targets
    such as C:\Windows\Temp and the Windows Update download cache.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$IncludeDevCaches,
    [switch]$IncludeBrowserCaches,
    [switch]$RunDism,
    [switch]$Yes
)

$ErrorActionPreference = 'SilentlyContinue'
$script:Drive = 'C'

$userLocal = $env:LOCALAPPDATA
$userRoaming = $env:APPDATA
$userProfile = $env:USERPROFILE

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeBytes { (Get-PSDrive $script:Drive).Free }

function Format-GB { param([double]$Bytes) '{0,8:N2} GB' -f ($Bytes / 1GB) }

# ---------------------------------------------------------------------------
# Protection: Claude desktop and Claude Code keep their sessions, settings, VM and
# running binaries in folders named claude*/.claude*/anthropic* (for example
# %LOCALAPPDATA%\Temp\claude holds the output of tasks that are running right now).
# Nothing at or below such a folder is deleted, and neither is any folder that
# contains one, no matter which task asks.
# ---------------------------------------------------------------------------
$script:ProtectedName = '^\.?(claude|anthropic)'
$script:ProtectedRoots = @(
    foreach ($dir in $userProfile, $userRoaming, $userLocal, "$userLocal\Temp",
                     "$userLocal\Programs", "$userLocal\Packages") {
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $script:ProtectedName } |
            ForEach-Object { $_.FullName.TrimEnd('\') }
    }
)

# True if deleting $Path would touch protected data. With -ContentsOnly the folder
# itself is kept (only its children are deleted, and each child is checked on its
# own), so it only counts as protected if it is *inside* a protected folder - e.g.
# %LOCALAPPDATA%\Temp may be emptied, but its 'claude' child is skipped.
function Test-Protected {
    param([string]$Path, [switch]$ContentsOnly)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Split('\') | Where-Object { $_ -match $script:ProtectedName }) { return $true }
    if ($ContentsOnly) { return $false }
    foreach ($root in $script:ProtectedRoots) {
        # $full is the protected item itself or an ancestor of it.
        if ($root -ieq $full -or $root.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $false
}

# Expand wildcard patterns to the files/folders that actually exist.
function Resolve-Existing {
    param([string[]]$Patterns)
    foreach ($p in $Patterns) {
        Get-Item -Path $p -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
}

# Fast-ish recursive size of files/folders; tolerant of locked/inaccessible files.
function Get-PathSize {
    param([string[]]$Paths)
    $total = 0L
    foreach ($p in $Paths) {
        if ($p -and (Test-Path -LiteralPath $p) -and -not (Test-Protected $p -ContentsOnly)) {
            $total += (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-Protected $_.FullName -ContentsOnly) } |
                Measure-Object -Property Length -Sum).Sum
        }
    }
    [long]$total
}

# Delete the *contents* of one or more folders, leaving the folders themselves.
function Clear-FolderContents {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p) -or (Test-Protected $p -ContentsOnly)) { continue }
        Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Protected $_.FullName) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Delete the files/folders themselves.
function Remove-Targets {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path -LiteralPath $p) -and -not (Test-Protected $p)) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Chromium-based apps (Chrome, Edge, Steam's web view) keep one HTTP/code/GPU cache per
# profile. Only these cache folders are returned - never Cookies, Local Storage, etc.
function Get-ChromiumCacheDirs {
    param([string]$UserData)
    $cacheNames = 'Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache'
    Get-ChildItem -LiteralPath $UserData -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' } |
        ForEach-Object {
            foreach ($c in $cacheNames) {
                $d = Join-Path $_.FullName $c
                if (Test-Path -LiteralPath $d) { $d }
            }
        }
}

# Apps installed by Squirrel (Discord, Figma, GitHub Desktop, Postman, ...) keep the
# previous app-x.y.z folder after each update. Returns the folders that are safe to
# remove: every version except the newest, and never one a running process uses.
# An app with any oddly-named app-* folder is skipped entirely rather than guessed at.
function Get-StaleAppVersions {
    $runningPaths = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path } |
        ForEach-Object { $_.Path })
    Get-ChildItem -LiteralPath $userLocal -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'Update.exe')) -and
                       -not (Test-Protected $_.FullName) } |
        ForEach-Object {
            $versions = @(Get-ChildItem -LiteralPath $_.FullName -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)
            if ($versions.Count -lt 2) { return }
            if ($versions | Where-Object { $_.Name -notmatch '^app-\d+(\.\d+){1,3}$' }) { return }
            $versions | Sort-Object { [version]$_.Name.Substring(4) } -Descending |
                Select-Object -Skip 1 |
                Where-Object {
                    $prefix = $_.FullName + '\'
                    -not ($runningPaths | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
                } |
                ForEach-Object { $_.FullName }
        }
}

# Names of any listed processes that are running right now.
function Get-RunningBlockers {
    param([string[]]$Names)
    if (-not $Names) { return @() }
    @(Get-Process -Name $Names -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } |
        Sort-Object -Unique)
}

$isAdmin = Test-Admin

# Each task: a friendly name and the paths it targets, plus optional flags:
#   RequiresAdmin / OptInDev / OptInBrowser  - when the task runs
#   RemoveSelf    - delete the paths themselves (default: delete their contents)
#   SkipIfRunning - process names; the task is skipped while any of them runs
#   Action        - custom cleanup instead of the default delete
#   SizeOverride  - custom size estimate instead of measuring Paths
$tasks = @(
    @{
        Name = 'User temp files'
        Paths = @("$userLocal\Temp")
    },
    @{
        Name = 'Windows temp files'
        Paths = @('C:\Windows\Temp')
        RequiresAdmin = $true
    },
    @{
        Name = 'Crash dumps'
        Paths = @("$userLocal\CrashDumps")
    },
    @{
        Name = 'Windows Error Reporting'
        Paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                  "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")
    },
    @{
        Name = 'Explorer thumbnail cache'
        Paths = @(Resolve-Existing "$userLocal\Microsoft\Windows\Explorer\thumbcache_*.db")
        RemoveSelf = $true
    },
    @{
        # DirectX/OpenGL shader caches. Rebuilt automatically; the first launch of a
        # game afterwards may stutter briefly while shaders recompile.
        Name = 'GPU shader caches'
        Paths = @("$userLocal\NVIDIA\DXCache", "$userLocal\NVIDIA\GLCache", "$userLocal\D3DSCache",
                  "$userLocal\AMD\DxCache", "$userLocal\AMD\GLCache", "$userLocal\Intel\ShaderCache")
    },
    @{
        Name = 'Old app versions (Discord, Figma, ...)'
        Paths = @(Get-StaleAppVersions)
        RemoveSelf = $true
    },
    @{
        Name = 'PowerToys old installers'
        Paths = @("$userLocal\Microsoft\PowerToys\Updates")
    },
    @{
        Name = 'NVIDIA leftover driver installers'
        Paths = @("$env:ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts",
                  "$env:ProgramData\NVIDIA Corporation\Downloader")
    },
    @{
        # Downloaded component packages Google's updater keeps after installing them.
        Name = 'Google updater download cache'
        Paths = @("${env:ProgramFiles(x86)}\Google\GoogleUpdater\crx_cache",
                  "$env:ProgramFiles\Google\GoogleUpdater\crx_cache")
        RequiresAdmin = $true
    },
    @{
        # Log of the last Windows Update install; can grow to hundreds of MB. Skipped
        # while an update is being installed.
        Name = 'Windows Update setup logs'
        Paths = @(Resolve-Existing 'C:\Windows\Logs\MoSetup\*.log')
        RemoveSelf = $true
        RequiresAdmin = $true
        SkipIfRunning = @('TiWorker', 'SetupHost')
    },
    @{
        Name = 'Windows Update download cache'
        Paths = @('C:\Windows\SoftwareDistribution\Download')
        RequiresAdmin = $true
        Action = {
            net stop wuauserv | Out-Null
            net stop bits | Out-Null
            Clear-FolderContents @('C:\Windows\SoftwareDistribution\Download')
            net start wuauserv | Out-Null
            net start bits | Out-Null
        }
    },
    @{
        Name = 'Recycle Bin'
        Paths = @()
        SizeOverride = {
            $shell = New-Object -ComObject Shell.Application
            $bin = $shell.Namespace(0xA)
            ($bin.Items() | ForEach-Object { $_.ExtendedProperty('Size') } |
                Measure-Object -Sum).Sum
        }
        Action = { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
    },

    # ---- Developer caches (opt-in: -IncludeDevCaches) ----
    @{
        Name = 'Gradle build cache'
        OptInDev = $true
        Paths = @("$userProfile\.gradle\caches")
        Action = {
            $gradleCache = "$userProfile\.gradle\caches"
            # Gradle's cache is stateful: a PARTIAL delete (e.g. while a daemon or IDE
            # holds file locks) leaves metadata.bin inconsistent and breaks EVERY build
            # until the folder is fully wiped. A fully-empty cache is safe; a half-empty
            # one is corrupt. So refuse to half-clear it, and warn if anything remains.
            if (Get-Process -Name 'java', 'studio64', 'kotlin-compiler-daemon' -ErrorAction SilentlyContinue) {
                Write-Warning ('Skipping Gradle cache: a JVM/IDE process is running and could hold locks. ' +
                    'Close Android Studio and stop Gradle daemons (gradlew --stop), then re-run.')
                return
            }
            Remove-Item $gradleCache -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $gradleCache) {
                Write-Warning ("Gradle cache only PARTIALLY cleared (some files were locked). It is now " +
                    "inconsistent. Close all JVM/IDE processes and delete '$gradleCache' completely, or your " +
                    "next build will fail with 'Could not read workspace metadata'.")
            }
        }
    },
    @{
        Name = 'npm cache'
        OptInDev = $true
        Paths = @("$userLocal\npm-cache", "$userRoaming\npm-cache", "$userProfile\npm-cache", "$userProfile\.npm")
    },
    @{
        # pnpm keeps its content store and its metadata cache in separate folders.
        Name = 'pnpm store and cache'
        OptInDev = $true
        Paths = @("$userLocal\pnpm\store", "$userProfile\.pnpm-store", "$userLocal\pnpm-cache")
    },
    @{
        Name = 'Yarn cache'
        OptInDev = $true
        Paths = @("$userLocal\Yarn\Cache")
    },
    @{
        Name = 'pip cache'
        OptInDev = $true
        Paths = @("$userLocal\pip\Cache")
    },
    @{
        Name = 'uv (Python) cache'
        OptInDev = $true
        Paths = @("$userLocal\uv\cache")
    },
    @{
        # Deno's downloaded npm packages and remote modules (what `deno clean` removes).
        Name = 'Deno cache'
        OptInDev = $true
        Paths = @("$userLocal\deno\npm", "$userLocal\deno\remote", "$userLocal\deno\gen")
    },
    @{
        Name = 'node-gyp headers cache'
        OptInDev = $true
        Paths = @("$userLocal\node-gyp\Cache")
    },
    @{
        # @types packages the TypeScript language server downloads for JS projects.
        Name = 'TypeScript type cache'
        OptInDev = $true
        Paths = @("$userLocal\Microsoft\TypeScript")
    },
    @{
        Name = 'NuGet cache'
        OptInDev = $true
        Paths = @("$userProfile\.nuget\packages")
    },

    # ---- Browser and app web caches (opt-in: -IncludeBrowserCaches) ----
    @{
        Name = 'Chrome cache (all profiles)'
        OptInBrowser = $true
        Paths = @(Get-ChromiumCacheDirs "$userLocal\Google\Chrome\User Data")
    },
    @{
        Name = 'Edge cache (all profiles)'
        OptInBrowser = $true
        Paths = @(Get-ChromiumCacheDirs "$userLocal\Microsoft\Edge\User Data")
    },
    @{
        # Firefox keeps its HTTP cache under Local, separate from the profile data
        # (bookmarks, logins, history) under Roaming, which is not touched.
        Name = 'Firefox cache (all profiles)'
        OptInBrowser = $true
        Paths = @(Resolve-Existing "$userLocal\Mozilla\Firefox\Profiles\*\cache2")
        SkipIfRunning = @('firefox')
    },
    @{
        Name = 'Discord cache'
        OptInBrowser = $true
        Paths = @("$userRoaming\discord\Cache", "$userRoaming\discord\Code Cache", "$userRoaming\discord\GPUCache")
        SkipIfRunning = @('Discord')
    },
    @{
        Name = 'Steam web cache'
        OptInBrowser = $true
        Paths = @(Get-ChromiumCacheDirs "$userLocal\Steam\htmlcache")
        SkipIfRunning = @('steam', 'steamwebhelper')
    }
)

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
$mode = if ($Execute) { 'EXECUTE (will delete)' } else { 'DRY RUN (preview only)' }
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Clear-DiskSpace  -  safe Windows disk cleanup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("  Mode        : {0}" -f $mode) -ForegroundColor $(if ($Execute) { 'Yellow' } else { 'Green' })
Write-Host ("  Elevated    : {0}" -f $(if ($isAdmin) { 'yes' } else { 'no (system targets skipped)' }))
Write-Host ("  Dev caches  : {0}" -f $(if ($IncludeDevCaches) { 'included' } else { 'skipped (-IncludeDevCaches)' }))
Write-Host ("  Browser     : {0}" -f $(if ($IncludeBrowserCaches) { 'included' } else { 'skipped (-IncludeBrowserCaches)' }))
Write-Host ("  C: free now : {0}" -f (Format-GB (Get-FreeBytes)))
Write-Host ''

# ---------------------------------------------------------------------------
# Build the active task list and estimate sizes. Empty targets are left out.
# ---------------------------------------------------------------------------
$active = foreach ($t in $tasks) {
    if ($t.RequiresAdmin -and -not $isAdmin) { continue }
    if ($t.OptInDev -and -not $IncludeDevCaches) { continue }
    if ($t.OptInBrowser -and -not $IncludeBrowserCaches) { continue }

    $size = if ($t.SizeOverride) { [long](& $t.SizeOverride) } else { Get-PathSize $t.Paths }
    if ($size -le 0) { continue }
    [PSCustomObject]@{
        Name = $t.Name; EstBytes = $size; Paths = $t.Paths; Action = $t.Action
        RemoveSelf = [bool]$t.RemoveSelf; SkipIfRunning = $t.SkipIfRunning
    }
}

if (-not $active) {
    Write-Host 'Nothing to clean. You are already tidy!' -ForegroundColor Green
    return
}

Write-Host 'Targets:' -ForegroundColor Cyan
$active | Sort-Object EstBytes -Descending | ForEach-Object {
    $blockers = Get-RunningBlockers $_.SkipIfRunning
    $note = if ($blockers) { "  (close $($blockers -join ', ') first, or it is skipped)" } else { '' }
    Write-Host ('  {0,-40} {1}{2}' -f $_.Name, (Format-GB $_.EstBytes), $note)
}
$estTotal = ($active | Measure-Object EstBytes -Sum).Sum
Write-Host ('  {0,-40} {1}' -f '----------------------------------------', '----------')
Write-Host ('  {0,-40} {1}' -f 'Estimated reclaimable', (Format-GB $estTotal)) -ForegroundColor Green
Write-Host ''

# ---------------------------------------------------------------------------
# Dry run stops here
# ---------------------------------------------------------------------------
if (-not $Execute) {
    Write-Host 'Dry run only - nothing was deleted.' -ForegroundColor Green
    Write-Host 'Re-run with  -Execute  to clean for real.' -ForegroundColor Yellow
    return
}

if (-not $Yes) {
    $reply = Read-Host 'Proceed with deletion? (y/N)'
    if ($reply -notmatch '^[Yy]') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
}

# ---------------------------------------------------------------------------
# Execute, measuring real freed space per task via drive free-space delta
# ---------------------------------------------------------------------------
Write-Host ''
$startFree = Get-FreeBytes
$results = foreach ($t in $active) {
    # Checked again here: the app may have been opened or closed since the preview.
    $blockers = Get-RunningBlockers $t.SkipIfRunning
    if ($blockers) {
        Write-Host ('Skipping {0}: {1} is running. Close it and re-run.' -f $t.Name, ($blockers -join ', ')) -ForegroundColor Yellow
        [PSCustomObject]@{ Name = "$($t.Name) (skipped)"; Freed = 0 }
        continue
    }
    $before = Get-FreeBytes
    Write-Host ('Cleaning {0} ...' -f $t.Name) -NoNewline
    if ($t.Action) { & $t.Action }
    elseif ($t.RemoveSelf) { Remove-Targets $t.Paths }
    else { Clear-FolderContents $t.Paths }
    $freed = (Get-FreeBytes) - $before
    if ($freed -lt 0) { $freed = 0 }
    Write-Host (' done ({0})' -f (Format-GB $freed)) -ForegroundColor Green
    [PSCustomObject]@{ Name = $t.Name; Freed = $freed }
}

# Optional: DISM component-store cleanup (slow, admin-only)
if ($RunDism -and $isAdmin) {
    Write-Host ''
    Write-Host 'Running DISM component-store cleanup (this can take 10-30 min)...' -ForegroundColor Cyan
    $dismBefore = Get-FreeBytes
    Dism /Online /Cleanup-Image /StartComponentCleanup
    $results += [PSCustomObject]@{ Name = 'DISM component store'; Freed = ((Get-FreeBytes) - $dismBefore) }
} elseif ($RunDism -and -not $isAdmin) {
    Write-Host 'Skipped DISM cleanup: requires an elevated (Administrator) session.' -ForegroundColor Yellow
}

$totalFreed = (Get-FreeBytes) - $startFree

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Summary' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
$results | Sort-Object Freed -Descending | ForEach-Object {
    Write-Host ('  {0,-40} {1}' -f $_.Name, (Format-GB $_.Freed))
}
Write-Host ('  {0,-40} {1}' -f '----------------------------------------', '----------')
Write-Host ('  {0,-40} {1}' -f 'TOTAL FREED', (Format-GB $totalFreed)) -ForegroundColor Green
Write-Host ('  {0,-40} {1}' -f 'C: free now', (Format-GB (Get-FreeBytes))) -ForegroundColor Green
Write-Host ''
Write-Host 'Tip: for old Windows Update files in C:\Windows, also run as admin:' -ForegroundColor DarkGray
Write-Host '     Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase' -ForegroundColor DarkGray
