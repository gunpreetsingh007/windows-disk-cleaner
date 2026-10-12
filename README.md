# Clear-DiskSpace

A safe, no-nonsense PowerShell script to reclaim disk space on Windows — especially on small `C:` drives that keep filling up.

It clears only **regenerable junk**: temp files, crash dumps, leftover driver installers, package-manager and build caches, browser HTTP caches, and Windows Update leftovers. It never touches your documents, projects, or installed programs.

> Born from a very real "2 GB free on a 120 GB C: drive" emergency. The first run on that machine recovered ~12 GB in seconds, and the deep clean cleared 20+ GB.

## Features

- **Dry-run by default** — see exactly what would be freed before anything is deleted.
- **Accurate reporting** — measures real space freed per category via drive free-space deltas.
- **Safe-by-default** — system and developer caches are opt-in.
- **Admin-aware** — automatically skips system targets (`C:\Windows\Temp`, Windows Update cache) when not elevated, instead of failing.
- **No dependencies** — just PowerShell 5.1+ (built into Windows 10/11).
- **One-click launcher** — double-click `CleanDisk.bat` for a menu; no commands to remember.

## What it cleans

**Default (safe for everyone):**
- User & Windows temp files
- Crash dumps and Windows Error Reporting queues
- Explorer thumbnail cache
- Leftover NVIDIA driver installers (`NVIDIA app` OTA artifacts + Downloader cache)
- Windows Update download cache *(admin)*
- Recycle Bin

**Opt-in with `-IncludeDevCaches`:**
- Gradle, npm, pnpm, Yarn, pip, NuGet caches

> ⚠️ **Close Android Studio and stop Gradle daemons (`gradlew --stop`) before clearing dev caches.** The Gradle cache is stateful — if files are locked by a running daemon/IDE, a partial delete leaves it corrupt (`Could not read workspace metadata from …metadata.bin`) and breaks every build until the whole `~/.gradle/caches` folder is wiped. The script now skips the Gradle cache when a JVM/IDE process is running and warns if it could only clear it partially.

**Opt-in with `-IncludeBrowserCaches`:**
- Chrome & Edge HTTP caches (not history, passwords, or cookies)

**Opt-in with `-RunDism`:**
- DISM component-store cleanup (old Windows Update files; admin, slow)

## Quick start: just double-click

Double-click **`CleanDisk.bat`**. It asks for admin rights (so system caches can be cleaned too; say No to run as a standard user), then shows a menu:

```
   1. Preview       Show what can be freed - deletes nothing
   2. Quick clean   Temp files, crash dumps, Recycle Bin, ...
   3. Full clean    Quick + developer and browser caches
   4. Deep clean    Full + DISM Windows Update cleanup - slow

   S. Create a desktop shortcut to this menu
   Q. Quit
```

Every cleaning option still shows the preview and asks `y/N` before deleting anything. Pick **S** once to put a "Clean Disk" shortcut on your desktop. After that you never need to open this folder again.

> Keep `CleanDisk.bat` in the same folder as `Clear-DiskSpace.ps1`. No execution-policy changes are needed, because the launcher runs the script with `-ExecutionPolicy Bypass` for that run only.

## Usage (PowerShell)

Preview only (recommended first run — changes nothing):

```powershell
.\Clear-DiskSpace.ps1
```

Clean the default safe targets:

```powershell
.\Clear-DiskSpace.ps1 -Execute
```

Full cleanup including developer and browser caches:

```powershell
.\Clear-DiskSpace.ps1 -Execute -IncludeDevCaches -IncludeBrowserCaches
```

For system-level targets (and DISM), run from an **Administrator** PowerShell:

```powershell
.\Clear-DiskSpace.ps1 -Execute -RunDism
```

Skip the confirmation prompt (e.g. for scheduled runs):

```powershell
.\Clear-DiskSpace.ps1 -Execute -Yes
```

### If you get an execution-policy error

Run the script without changing your machine's policy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clear-DiskSpace.ps1
```

## Parameters

| Parameter | Description |
|---|---|
| `-Execute` | Actually delete. Without it, the script only previews (dry run). |
| `-IncludeDevCaches` | Also clear Gradle/npm/pnpm/Yarn/pip/NuGet caches. |
| `-IncludeBrowserCaches` | Also clear Chrome/Edge HTTP caches. |
| `-RunDism` | Also run DISM component-store cleanup (admin, 10–30 min). |
| `-Yes` | Skip the confirmation prompt. |

## Is it safe?

Yes. Everything it removes is data Windows or your tools recreate automatically:
- Temp/cache folders refill as needed.
- Cleared package/build caches just mean the next build/install re-downloads or rebuilds (slower once, then back to normal).
- NVIDIA OTA artifacts are installer leftovers the NVIDIA app re-fetches on demand.
- Browser caches are HTTP caches only — you stay logged in.

It does **not** delete documents, source code, installed applications, or browser logins/history.

## Run it quarterly

Caches refill over time, so a periodic run keeps things tidy. You can schedule it with Task Scheduler, or just run the one-liner whenever you get a low-space warning.

## License

MIT — see [LICENSE](LICENSE).
