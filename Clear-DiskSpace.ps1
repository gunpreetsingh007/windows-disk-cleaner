#Requires -Version 5.1
<#
.SYNOPSIS
    Reclaims disk space on Windows by clearing safe, regenerable caches and junk.

.DESCRIPTION
    Clear-DiskSpace scans well-known space hogs (temp files, crash dumps, leftover
    driver installers, package-manager and build caches, browser caches, Windows
    Update leftovers) and removes only data that the system or your tools recreate
    on demand. Nothing in your documents, projects, or installed programs is touched.

    By default it runs in DRY-RUN mode and only reports what *would* be freed.
    Re-run with -Execute to actually delete.

.PARAMETER Execute
    Actually delete. Without this switch the script only previews (dry run).

.PARAMETER IncludeDevCaches
    Also clear developer build/package caches (Gradle, npm, pnpm, yarn, pip, NuGet).
    These are safe but will make your next build/install slower while they rebuild.

.PARAMETER IncludeBrowserCaches
    Also clear Chrome/Edge HTTP caches (not history, passwords, or cookies).
    Close the browser first for best results.

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

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeBytes { (Get-PSDrive $script:Drive).Free }

function Format-GB { param([double]$Bytes) '{0,8:N2} GB' -f ($Bytes / 1GB) }

# Fast-ish recursive size of a path; tolerant of locked/inaccessible files.
function Get-PathSize {
    param([string[]]$Paths)
    $total = 0L
    foreach ($p in $Paths) {
        if (Test-Path $p) {
            $total += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        }
    }
    [long]$total
}

# Delete the *contents* of one or more folders, leaving the folders themselves.
function Clear-FolderContents {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if (Test-Path $p) {
            Get-ChildItem $p -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$isAdmin = Test-Admin
$userLocal = $env:LOCALAPPDATA
$userRoaming = $env:APPDATA
$userProfile = $env:USERPROFILE

# Each task: a friendly name, the paths it targets, whether it needs admin / opt-in,
# and the action that performs the cleanup. Size is estimated from the same paths
# unless a task provides its own estimator.
$tasks = @(
    @{
        Name = 'User temp files'
        Paths = @("$userLocal\Temp")
        Action = { Clear-FolderContents @("$userLocal\Temp") }
    },
    @{
        Name = 'Windows temp files'
        Paths = @('C:\Windows\Temp')
        RequiresAdmin = $true
        Action = { Clear-FolderContents @('C:\Windows\Temp') }
    },
    @{
        Name = 'Crash dumps'
        Paths = @("$userLocal\CrashDumps")
        Action = { Clear-FolderContents @("$userLocal\CrashDumps") }
    },
    @{
        Name = 'Windows Error Reporting'
        Paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                  "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")
        Action = { Clear-FolderContents @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                                          "$env:ProgramData\Microsoft\Windows\WER\ReportArchive") }
    },
    @{
        Name = 'Explorer thumbnail cache'
        Paths = @("$userLocal\Microsoft\Windows\Explorer")
        Action = {
            Get-ChildItem "$userLocal\Microsoft\Windows\Explorer\thumbcache_*.db" -Force `
                -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    },
    @{
        Name = 'NVIDIA leftover driver installers'
        Paths = @("$env:ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts",
                  "$env:ProgramData\NVIDIA Corporation\Downloader")
        Action = { Clear-FolderContents @("$env:ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts",
                                          "$env:ProgramData\NVIDIA Corporation\Downloader") }
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
        Action = { Clear-FolderContents @("$userProfile\.gradle\caches") }
    },
    @{
        Name = 'npm cache'
        OptInDev = $true
        Paths = @("$userLocal\npm-cache", "$userProfile\npm-cache", "$userProfile\.npm")
        Action = { Clear-FolderContents @("$userLocal\npm-cache", "$userProfile\npm-cache", "$userProfile\.npm") }
    },
    @{
        Name = 'pnpm store'
        OptInDev = $true
        Paths = @("$userLocal\pnpm\store", "$userProfile\.pnpm-store")
        Action = { Clear-FolderContents @("$userLocal\pnpm\store", "$userProfile\.pnpm-store") }
    },
    @{
        Name = 'Yarn cache'
        OptInDev = $true
        Paths = @("$userLocal\Yarn\Cache")
        Action = { Clear-FolderContents @("$userLocal\Yarn\Cache") }
    },
    @{
        Name = 'pip cache'
        OptInDev = $true
        Paths = @("$userLocal\pip\Cache")
        Action = { Clear-FolderContents @("$userLocal\pip\Cache") }
    },
    @{
        Name = 'NuGet cache'
        OptInDev = $true
        Paths = @("$userProfile\.nuget\packages")
        Action = { Clear-FolderContents @("$userProfile\.nuget\packages") }
    },

    # ---- Browser caches (opt-in: -IncludeBrowserCaches) ----
    @{
        Name = 'Chrome cache'
        OptInBrowser = $true
        Paths = @("$userLocal\Google\Chrome\User Data\Default\Cache",
                  "$userLocal\Google\Chrome\User Data\Default\Code Cache",
                  "$userLocal\Google\Chrome\User Data\Default\GPUCache")
        Action = { Clear-FolderContents @("$userLocal\Google\Chrome\User Data\Default\Cache",
                                          "$userLocal\Google\Chrome\User Data\Default\Code Cache",
                                          "$userLocal\Google\Chrome\User Data\Default\GPUCache") }
    },
    @{
        Name = 'Edge cache'
        OptInBrowser = $true
        Paths = @("$userLocal\Microsoft\Edge\User Data\Default\Cache",
                  "$userLocal\Microsoft\Edge\User Data\Default\Code Cache",
                  "$userLocal\Microsoft\Edge\User Data\Default\GPUCache")
        Action = { Clear-FolderContents @("$userLocal\Microsoft\Edge\User Data\Default\Cache",
                                          "$userLocal\Microsoft\Edge\User Data\Default\Code Cache",
                                          "$userLocal\Microsoft\Edge\User Data\Default\GPUCache") }
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
# Build the active task list and estimate sizes
# ---------------------------------------------------------------------------
$active = foreach ($t in $tasks) {
    if ($t.RequiresAdmin -and -not $isAdmin) { continue }
    if ($t.OptInDev -and -not $IncludeDevCaches) { continue }
    if ($t.OptInBrowser -and -not $IncludeBrowserCaches) { continue }

    $size = if ($t.SizeOverride) { [long](& $t.SizeOverride) } else { Get-PathSize $t.Paths }
    [PSCustomObject]@{ Name = $t.Name; EstBytes = $size; Action = $t.Action }
}

if (-not $active) {
    Write-Host 'Nothing to clean. You are already tidy!' -ForegroundColor Green
    return
}

Write-Host 'Targets:' -ForegroundColor Cyan
$active | Sort-Object EstBytes -Descending | ForEach-Object {
    Write-Host ('  {0,-34} {1}' -f $_.Name, (Format-GB $_.EstBytes))
}
$estTotal = ($active | Measure-Object EstBytes -Sum).Sum
Write-Host ('  {0,-34} {1}' -f '----------------------------------', '----------')
Write-Host ('  {0,-34} {1}' -f 'Estimated reclaimable', (Format-GB $estTotal)) -ForegroundColor Green
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
    $before = Get-FreeBytes
    Write-Host ('Cleaning {0} ...' -f $t.Name) -NoNewline
    & $t.Action
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
    Write-Host ('  {0,-34} {1}' -f $_.Name, (Format-GB $_.Freed))
}
Write-Host ('  {0,-34} {1}' -f '----------------------------------', '----------')
Write-Host ('  {0,-34} {1}' -f 'TOTAL FREED', (Format-GB $totalFreed)) -ForegroundColor Green
Write-Host ('  {0,-34} {1}' -f 'C: free now', (Format-GB (Get-FreeBytes))) -ForegroundColor Green
Write-Host ''
Write-Host 'Tip: for old Windows Update files in C:\Windows, also run as admin:' -ForegroundColor DarkGray
Write-Host '     Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase' -ForegroundColor DarkGray
