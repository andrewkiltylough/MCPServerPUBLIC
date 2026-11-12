<#
.SYNOPSIS
    Builds the Windows setup .exe for the WallStreetsAhead.ai plugin.

.DESCRIPTION
    Runs the Maven build, which produces the complete plugin folder (manifests,
    skill, jar and the bundled Java runtime), then compiles the Inno Setup
    script against it. The result is one self-contained installer in
    target\installer, ready to upload to the website.

.PARAMETER SkipBuild
    Compile the installer against the plugin folder as it stands, without
    running Maven first. Only useful when iterating on the .iss script.

.EXAMPLE
    .\installer\build.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$pluginDir = Join-Path $repoRoot 'wallstreetsahead-plugin'
$issFile   = Join-Path $PSScriptRoot 'wallstreetsahead-plugin.iss'
$outDir    = Join-Path $repoRoot 'target\installer'

function Find-InnoCompiler {
    $cmd = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # winget installs per-user when it is not elevated, which is the usual case,
    # so LOCALAPPDATA comes first. The wildcard keeps this working across versions.
    $roots = @(
        "$env:LOCALAPPDATA\Programs"
        ${env:ProgramFiles(x86)}
        $env:ProgramFiles
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        $found = Get-ChildItem -Path $root -Filter 'Inno Setup *' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'ISCC.exe' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($found) { return $found }
    }

    throw "Inno Setup was not found. Install it with:`n  winget install --id JRSoftware.InnoSetup --source winget"
}

# The installer version is the project version, so the setup filename, the
# Programs and Features entry and the plugin manifest can never disagree.
function Get-ProjectVersion {
    $pom = Join-Path $repoRoot 'pom.xml'
    $xml = Select-Xml -Path $pom -XPath '/*[local-name()="project"]/*[local-name()="version"]'
    if (-not $xml) { throw "Could not read <version> from $pom" }
    return $xml.Node.InnerText.Trim()
}

$version = Get-ProjectVersion
Write-Host "Building installer for version $version" -ForegroundColor Cyan

if (-not $SkipBuild) {
    Write-Host 'Running mvn package (this builds the jar and jlinks the runtime)...'
    & mvn -B -f (Join-Path $repoRoot 'pom.xml') package
    if ($LASTEXITCODE -ne 0) { throw "mvn package failed with exit code $LASTEXITCODE" }
}

# Fail here rather than shipping a setup that installs a plugin Claude cannot start.
$required = @(
    '.claude-plugin\plugin.json'
    '.claude-plugin\marketplace.json'
    '.mcp.json'
    'INSTALL.md'
    'skills\fetch-market-data\SKILL.md'
    'lib\wallstreetsahead-mcp.jar'
    'runtime\bin\java.exe'
)
$missing = $required | Where-Object { -not (Test-Path (Join-Path $pluginDir $_)) }
if ($missing) {
    throw "The plugin folder is incomplete. Missing:`n  " + ($missing -join "`n  ")
}

$iscc = Find-InnoCompiler
Write-Host "Compiling with $iscc"
& $iscc "/DAppVersion=$version" $issFile
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }

$setup = Join-Path $outDir "wallstreetsahead-plugin-$version-setup.exe"
if (-not (Test-Path $setup)) { throw "Expected $setup but it was not produced" }

$sizeMb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
$hash = (Get-FileHash -Algorithm SHA256 $setup).Hash
Write-Host ''
Write-Host "Installer:    $setup" -ForegroundColor Green
Write-Host "Size:         $sizeMb MB"
Write-Host "SHA-256:      $hash"
Write-Host ''
Write-Host 'Publish the SHA-256 next to the download so people can check what they got.'
Write-Host 'Unsigned setups trigger a SmartScreen warning: see installer\README.md.'
