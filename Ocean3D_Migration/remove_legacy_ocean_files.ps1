[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-CompatibleRelativePath([string]$BasePath, [string]$TargetPath) {
    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
    $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    if (-not $baseFullPath.EndsWith([string]$separator)) { $baseFullPath += $separator }
    $baseUri = New-Object System.Uri($baseFullPath)
    $targetUri = New-Object System.Uri($targetFullPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [string]$separator)
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'project.godot'))) {
    throw "project.godot was not found in: $ProjectRoot"
}

$legacyFiles = @(
    'scripts/water/water_body_3d.gd',
    'scripts/water/water_body_3d.gd.uid',
    'scripts/water/pixel_ocean_system_3d.gd',
    'scripts/water/pixel_ocean_system_3d.gd.uid',
    'scripts/water/pixel_ocean_water_3d.gd',
    'scripts/water/pixel_ocean_water_3d.gd.uid',
    'scripts/water/ocean_clipmap_3d.gd',
    'scripts/water/ocean_clipmap_3d.gd.uid',
    'scenes/water/pixel_ocean_system_3d.tscn',
    'scenes/water/ocean_clipmap_3d.tscn',
    'shaders/pixel_ocean_water.gdshader',
    'shaders/pixel_ocean_water.gdshader.uid',
    'shaders/water_transparent_legacy.gdshader',
    'shaders/water_transparent_legacy.gdshader.uid'
)
$forbidden = @(
    'WaterBody3D',
    'PixelOceanSystem3D',
    'PixelOceanWater3D',
    'OceanClipmap3D',
    'pixel_ocean_system_3d',
    'pixel_ocean_water_3d',
    'pixel_ocean_enabled',
    'water_transparent_legacy'
)
$textExtensions = @('.gd', '.tscn', '.scn', '.tres', '.gdshader', '.cfg', '.godot')
$residuals = [System.Collections.Generic.List[string]]::new()

Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | ForEach-Object {
    $relative = (Get-CompatibleRelativePath $ProjectRoot $_.FullName).Replace('\', '/')
    if ($relative.StartsWith('.git/') -or $relative.StartsWith('.godot/') -or $relative.StartsWith('.ocean3d_') -or $relative.StartsWith('Ocean3D_Migration/')) { return }
    if ($relative -in $legacyFiles) { return }
    if ($textExtensions -notcontains $_.Extension.ToLowerInvariant() -and $_.Name -ne 'project.godot') { return }
    $content = [System.IO.File]::ReadAllText($_.FullName)
    foreach ($term in $forbidden) {
        if ($content.Contains($term)) { $residuals.Add("$relative -> $term") }
    }
}

if ($residuals.Count -gt 0) {
    Write-Error 'Cleanup cancelled: active legacy references remain.'
    $residuals | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    exit 1
}

$requiredNew = @(
    'scripts/water/ocean_3d.gd',
    'scripts/water/ocean_surface_3d.gd',
    'scenes/water/ocean_3d.tscn',
    'scenes/water/ocean_surface_3d.tscn',
    'shaders/ocean_water.gdshader'
)
foreach ($relative in $requiredNew) {
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative))) {
        throw "Required replacement is missing: $relative"
    }
}

foreach ($relative in $legacyFiles) {
    $path = Join-Path $ProjectRoot $relative
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "Deleted: $relative"
    }
}

$oldWaveFolder = Join-Path $ProjectRoot 'resources/water/pixel_ocean'
$newWaveFolder = Join-Path $ProjectRoot 'resources/water/ocean'
if ((Test-Path -LiteralPath $oldWaveFolder) -and (Test-Path -LiteralPath $newWaveFolder)) {
    Remove-Item -LiteralPath $oldWaveFolder -Recurse -Force
    Write-Host 'Deleted: resources/water/pixel_ocean/'
}

Write-Host ''
Write-Host 'Legacy ocean cleanup completed.' -ForegroundColor Green
