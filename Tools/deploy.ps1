<#
.SYNOPSIS
    Copies this repository into a live World of Warcraft install.

.DESCRIPTION
    The repository is the source. The deployed copies are deployments of it, and
    nothing should ever be edited there - this script is what makes that a
    one-command habit rather than something to remember.

    Two destinations, because the two halves are installed differently:

        CombatSession/                    ->  <wow>/Interface/AddOns/CombatSession/
        CombatSessionViewer/              ->  <wow>/Interface/AddOns/CombatSessionViewer/
        CombatSessionApp/Binary/*.exe     ->  <app>/Binary/

    The application used to be deployed into the AddOns tree as well, under
    CombatSession/App/. It no longer is: an executable inside a folder the game
    scans for addons was always odd, and it put a second copy of the C++ source
    somewhere nobody would edit it. Only the built executable is deployed now,
    and only to the folder the application actually runs from.

    settings.json and Raw/ live beside the deployed executable and have no
    counterpart in the repository, so deploying adds the new executable beside
    them and leaves both alone. Your settings and your archive survive.

.PARAMETER WowPath
    The flavor folder, the one containing Logs and Interface. Detected from the
    usual locations when omitted.

.PARAMETER AppPath
    The folder the application runs from - the one containing Binary/. Defaults
    to C:\Games\WowCombatSession.

.PARAMETER SkipApp
    Deploy the addons only, leaving the executable alone.

.PARAMETER WhatIf
    Report what would be copied without copying it.

.EXAMPLE
    .\Tools\deploy.ps1
    .\Tools\deploy.ps1 -WowPath "D:\Games\World of Warcraft\_retail_"
    .\Tools\deploy.ps1 -SkipApp
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $WowPath,
    [string] $AppPath = 'C:\Games\WowCombatSession',
    [switch] $SkipApp
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot

#-------------------------------------------------------------------------------
# Where the game is
#-------------------------------------------------------------------------------

function Test-Flavor([string] $path) {
    if (-not $path) { return $false }
    return (Test-Path (Join-Path $path 'Logs')) -and
           (Test-Path (Join-Path $path 'Interface\AddOns'))
}

if (-not $WowPath) {
    # Same candidates the application probes, so the script and the app agree
    # about where World of Warcraft usually lives.
    $candidates = @(
        'C:\Program Files (x86)\World of Warcraft\_retail_',
        'C:\Program Files\World of Warcraft\_retail_',
        'C:\Games\World of Warcraft\_retail_',
        'D:\Games\World of Warcraft\_retail_'
    )
    $WowPath = $candidates | Where-Object { Test-Flavor $_ } | Select-Object -First 1
}

if (-not (Test-Flavor $WowPath)) {
    throw "No World of Warcraft flavor folder found. Pass -WowPath ""<path to _retail_>""."
}

$addons = Join-Path $WowPath 'Interface\AddOns'
Write-Host "Deploying addons to $addons" -ForegroundColor Cyan

#-------------------------------------------------------------------------------
# The addons
#-------------------------------------------------------------------------------

$map = @(
    @{ From = 'CombatSession';       To = 'CombatSession' }
    @{ From = 'CombatSessionViewer'; To = 'CombatSessionViewer' }
)

$copied  = 0
$same    = 0
$skipped = 0

foreach ($entry in $map) {
    $source = Join-Path $repo $entry.From
    $target = Join-Path $addons $entry.To

    if (-not (Test-Path $source)) { throw "Missing source folder: $source" }

    foreach ($file in Get-ChildItem $source -Recurse -File) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\')
        $destination = Join-Path $target $relative

        # Compared by hash rather than by timestamp: a file copied back and
        # forth has a misleading write time, and this runs on a few dozen small
        # files where the difference does not matter.
        if (Test-Path $destination) {
            $a = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
            $b = (Get-FileHash $destination   -Algorithm SHA256).Hash
            if ($a -eq $b) { $same++; continue }
        }

        if ($PSCmdlet.ShouldProcess($destination, 'Copy')) {
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path $parent)) {
                New-Item -ItemType Directory -Force $parent | Out-Null
            }
            Copy-Item $file.FullName $destination -Force
        }
        Write-Host "  $($entry.To)\$relative"
        $copied++
    }
}

#-------------------------------------------------------------------------------
# The executable
#
# Done last, and reported separately, because it is the one copy that can fail
# for a reason the user has to do something about: Windows holds a lock on a
# running executable. Failing here after the addons are already in place is the
# right order - the Lua is what a /reload picks up, and it should not be held
# back by the application being open.
#-------------------------------------------------------------------------------

if (-not $SkipApp) {
    $built = Join-Path $repo 'CombatSessionApp\Binary\CombatSession.exe'

    if (-not (Test-Path $built)) {
        Write-Host ""
        Write-Host "No built executable at $built - build it, or pass -SkipApp." -ForegroundColor Yellow
    } else {
        $appBinary = Join-Path $AppPath 'Binary'
        $destination = Join-Path $appBinary 'CombatSession.exe'

        $current = $null
        if (Test-Path $destination) {
            $current = (Get-FileHash $destination -Algorithm SHA256).Hash
        }
        $fresh = (Get-FileHash $built -Algorithm SHA256).Hash

        if ($current -eq $fresh) {
            $same++
        } else {
            Write-Host ""
            Write-Host "Deploying application to $appBinary" -ForegroundColor Cyan

            if ($PSCmdlet.ShouldProcess($destination, 'Copy')) {
                if (-not (Test-Path $appBinary)) {
                    New-Item -ItemType Directory -Force $appBinary | Out-Null
                }

                # Attempted rather than predicted. Asking whether a process
                # named CombatSession is running answers a different question:
                # it would refuse a deploy to a folder other than the one that
                # process is running from, and it would still be guessing about
                # the lock. Letting the copy fail asks the filesystem.
                try {
                    Copy-Item $built $destination -Force
                    Write-Host "  Binary\CombatSession.exe"
                    $copied++
                } catch [System.IO.IOException] {
                    $running = @(Get-Process -Name CombatSession -ErrorAction SilentlyContinue |
                                 Where-Object { $_.Path -eq $destination })
                    Write-Host "  Could not replace CombatSession.exe - it is in use." -ForegroundColor Yellow
                    if ($running) {
                        Write-Host "  Running as pid $($running.Id -join ', '). Quit it from its window or tray icon and run this again." -ForegroundColor Yellow
                    } else {
                        Write-Host "  Close whatever is holding it and run this again." -ForegroundColor Yellow
                    }
                }
            }
        }
    }
}

#-------------------------------------------------------------------------------

Write-Host ""
if ($copied -eq 0) {
    Write-Host "Already up to date ($same files)." -ForegroundColor Green
} else {
    Write-Host "$copied file(s) copied, $same unchanged." -ForegroundColor Green
    Write-Host "Reload the game to pick up addon changes." -ForegroundColor DarkGray
}
