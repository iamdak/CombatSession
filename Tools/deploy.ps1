<#
.SYNOPSIS
    Copies this repository into a live World of Warcraft install.

.DESCRIPTION
    The repository is the source. The game folder is a deployment of it, and
    nothing should ever be edited there - this script is what makes that a
    one-command habit rather than something to remember.

    The two trees are shaped differently, which is the whole reason this exists:

        CombatSession/        ->  Interface/AddOns/CombatSession/
        CombatSessionViewer/  ->  Interface/AddOns/CombatSessionViewer/
        CombatSessionApp/     ->  Interface/AddOns/CombatSession/App/

    Copying is additive. Binary/ and Build/ live only in the game tree - the
    compiled executable, its settings and the raw archive - and are never
    touched, so deploying does not cost you your archive or make you rebuild.

.PARAMETER WowPath
    The flavor folder, the one containing Logs and Interface. Detected from the
    usual locations when omitted.

.PARAMETER WhatIf
    Report what would be copied without copying it.

.EXAMPLE
    .\Tools\deploy.ps1
    .\Tools\deploy.ps1 -WowPath "D:\Games\World of Warcraft\_retail_"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $WowPath
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
Write-Host "Deploying to $addons" -ForegroundColor Cyan

#-------------------------------------------------------------------------------
# What goes where
#-------------------------------------------------------------------------------

$map = @(
    @{ From = 'CombatSession';       To = 'CombatSession' }
    @{ From = 'CombatSessionViewer'; To = 'CombatSessionViewer' }
    @{ From = 'CombatSessionApp';    To = 'CombatSession\App' }
)

# Top-level folders that never leave the repository.
#
# Build is the CMake tree. The README tells you to produce it right here -
# `cmake -S . -B Build` from inside CombatSessionApp - so it is the expected
# state of a repository someone has built, and it is 110 files of object code
# and MSBuild logs that have no business in an AddOns folder. Left out of the
# original script only because nothing had been built in-tree yet.
#
# Binary is NOT on this list: it holds the freshly built executable, and putting
# that in the game tree is the point of deploying. The settings file and the raw
# archive live in the game tree's Binary and have no counterpart here, so a copy
# adds the new executable beside them and leaves both alone.
$skip = @('Build', '.git', '.vs', 'out')

$copied = 0
$same   = 0
$skipped = 0

foreach ($entry in $map) {
    $source = Join-Path $repo $entry.From
    $target = Join-Path $addons $entry.To

    if (-not (Test-Path $source)) { throw "Missing source folder: $source" }

    foreach ($file in Get-ChildItem $source -Recurse -File) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\')

        # Matched on the leading path segment, so a file called Build.lua is
        # still copied and everything under Build\ is not.
        if ($skip -contains $relative.Split('\')[0]) { $skipped++; continue }

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

Write-Host ""
if ($copied -eq 0) {
    Write-Host "Already up to date ($same files)." -ForegroundColor Green
} else {
    Write-Host "$copied file(s) copied, $same unchanged, $skipped not deployed." -ForegroundColor Green
    Write-Host "Reload the game to pick up addon changes." -ForegroundColor DarkGray
}
