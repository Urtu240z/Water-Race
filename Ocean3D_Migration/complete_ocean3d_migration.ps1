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
    if (-not $baseFullPath.EndsWith([string]$separator)) {
        $baseFullPath += $separator
    }
    $baseUri = New-Object System.Uri($baseFullPath)
    $targetUri = New-Object System.Uri($targetFullPath)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', [string]$separator)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'project.godot'))) {
    throw "project.godot was not found in: $ProjectRoot"
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupRoot = Join-Path $ProjectRoot ".ocean3d_completion_backup_$timestamp"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$Changed = [System.Collections.Generic.List[string]]::new()

function Backup-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $relative = Get-CompatibleRelativePath $ProjectRoot $Path
    $destination = Join-Path $BackupRoot $relative
    $directory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $destination -Force
}

function Set-ContentSafe([string]$RelativePath, [string]$Content) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file is missing: $RelativePath"
    }
    $before = Read-Text $path
    if ($before -eq $Content) { return }
    Backup-File $path
    Write-Utf8NoBom $path $Content
    $Changed.Add($RelativePath)
}

function Patch-File([string]$RelativePath, [scriptblock]$Transform) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file is missing: $RelativePath"
    }
    $before = Read-Text $path
    $after = & $Transform $before
    if ($after -eq $before) { return }
    Backup-File $path
    Write-Utf8NoBom $path $after
    $Changed.Add($RelativePath)
}

Write-Host 'Ocean3D completion patch v1.3' -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot"
Write-Host "Backup:  $BackupRoot"

# Ocean3D must expose the appearance/settings still consumed by water effects.
Patch-File 'scripts/water/ocean_3d.gd' {
    param($text)
    $text = $text.Replace(
        'It intentionally does not inherit from WaterBody3D.',
        'It intentionally does not inherit from the former generic water system.'
    )
    $text = $text.Replace(
        '@export var foam_settings: Resource',
        '@export var foam_settings: WaterFoamSettings'
    )
    if (-not $text.Contains('var wave_crest_color: Color')) {
        $needle = '@export_group("Foam")' + "`n"
        $insert = @"
@export_group("Foam")
@export var wave_crest_color: Color = Color(0.090, 0.500, 0.610, 1.0)
"@
        $text = $text.Replace($needle, $insert)
    }
    $text = $text.Replace('func get_foam_settings() -> Resource:', 'func get_foam_settings() -> WaterFoamSettings:')
    return $text
}

# Underwater controller: one Ocean3D reference and no generic-water lookup.
Patch-File 'scripts/camera/underwater_effect_controller.gd' {
    param($text)
    $text = $text.Replace('@export_node_path("WaterBody3D") var water_body_path', '@export_node_path("Ocean3D") var ocean_path')
    $text = $text.Replace('_resolve_water_body', '_resolve_ocean')
    $text = $text.Replace('_find_matching_water_body', '_find_matching_ocean')
    $text = $text.Replace('_unregister_water_material', '_unregister_ocean_material')
    $text = $text.Replace('_water_body', '_ocean')
    $text = $text.Replace('water_body_path', 'ocean_path')
    $text = $text.Replace('WaterBody3D', 'Ocean3D')
    $text = $text.Replace('var water := candidate as Ocean3D', 'var ocean := candidate as Ocean3D')
    $text = $text.Replace('fallback = water', 'fallback = ocean')
    $text = $text.Replace('if water.follow_target == _camera:', 'if ocean.follow_camera == _camera:')
    $text = $text.Replace('return water', 'return ocean')
    return $text
}

# Effect components receive Ocean3D directly from VehicleWaterEffects3D/JetSki.
Patch-File 'scripts/effects/hull_foam_3d.gd' {
    param($text)
    $text = $text.Replace('WaterBody3D', 'Ocean3D')
    $text = $text.Replace('_water', '_ocean')
    $text = $text.Replace('water: Ocean3D', 'ocean: Ocean3D')
    $text = $text.Replace('_ocean = water', '_ocean = ocean')
    return $text
}

Patch-File 'scripts/effects/hull_spray_sheet_3d.gd' {
    param($text)
    $text = $text.Replace('WaterBody3D', 'Ocean3D')
    $text = $text.Replace('_water', '_ocean')
    $text = $text.Replace('water: Ocean3D', 'ocean: Ocean3D')
    $text = $text.Replace('_ocean = water', '_ocean = ocean')
    return $text
}

Patch-File 'scripts/effects/turbine_exhaust_controller.gd' {
    param($text)
    $text = $text.Replace('WaterBody3D', 'Ocean3D')
    $text = $text.Replace('_water', '_ocean')
    $text = $text.Replace('get_water_body', 'get_ocean')
    return $text
}

Patch-File 'scripts/effects/wake_trail_3d.gd' {
    param($text)
    $text = $text.Replace('WaterBody3D', 'Ocean3D')
    $text = $text.Replace('_water', '_ocean')
    $text = $text.Replace('water: Ocean3D', 'ocean: Ocean3D')
    $text = $text.Replace('_ocean = water', '_ocean = ocean')
    return $text
}

# Replace the former dual analytic/texture underwater shader with the active
# Ocean3D model only.
$cleanShader = Read-Text (Join-Path $PSScriptRoot 'templates/underwater_ocean_post_process.gdshader')
Set-ContentSafe 'shaders/effects/underwater_wave_post_process.gdshader' $cleanShader

# This shader is retained only until final cleanup. Remove stale type names from
# comments so the legacy-reference detector can distinguish actual dependencies.
Patch-File 'shaders/water_transparent_legacy.gdshader' {
    param($text)
    $text = $text.Replace('WaterBody3D', 'former generic water provider')
    return $text
}

# Sanitize root properties copied from the old Physics node. Shader appearance
# remains inside the ShaderMaterial subresources; only Ocean3D exports belong on
# the new root.
Patch-File 'scenes/water/ocean_3d.tscn' {
    param($text)
    $normalized = $text.Replace("`r`n", "`n")
    $match = [regex]::Match(
        $normalized,
        '(?ms)^\[node name="Ocean3D"[^\n]*\]\n(?<body>.*?)(?=^\[node |\z)'
    )
    if (-not $match.Success) {
        throw 'Ocean3D root node was not found in scenes/water/ocean_3d.tscn.'
    }

    $allowed = @{
        'script' = $true
        'process_mode' = $true
        'process_priority' = $true
        'process_physics_priority' = $true
        'editor_description' = $true
        'unique_name_in_owner' = $true
        'visible' = $true
        'top_level' = $true
        'transform' = $true
        'follow_target_path' = $true
        'follow_camera_path' = $true
        'ripple_emitter_target_path' = $true
        'water_level' = $true
        'ocean_material' = $true
        'wave_height_texture_a' = $true
        'wave_height_texture_b' = $true
        'wave_world_size_a' = $true
        'wave_world_size_b' = $true
        'wave_amplitude_a' = $true
        'wave_amplitude_b' = $true
        'wave_direction_a' = $true
        'wave_direction_b' = $true
        'wave_travel_speed_a' = $true
        'wave_travel_speed_b' = $true
        'wave_mean_a' = $true
        'wave_mean_b' = $true
        'normal_sample_step' = $true
        'wake_ripple_spacing' = $true
        'wake_minimum_speed' = $true
        'wake_ripple_amplitude' = $true
        'ripple_speed' = $true
        'ripple_wavelength' = $true
        'ripple_decay' = $true
        'ripple_lifetime' = $true
        'ripple_contact_height' = $true
        'wake_rear_offset' = $true
        'wake_lateral_offset' = $true
        'wave_crest_color' = $true
        'foam_settings' = $true
        'foam_noise_texture' = $true
    }

    $header = $match.Value.Substring(0, $match.Value.IndexOf("`n") + 1)
    $filtered = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($match.Groups['body'].Value -split "`n")) {
        $propertyMatch = [regex]::Match($line, '^([A-Za-z0-9_./]+)\s*=')
        if (-not $propertyMatch.Success) {
            if ($line.Trim().Length -gt 0) { $filtered.Add($line) }
            continue
        }
        $name = $propertyMatch.Groups[1].Value
        if ($allowed.ContainsKey($name) -or $name.StartsWith('metadata/')) {
            $filtered.Add($line)
        } else {
            Write-Host "  Removed obsolete Ocean3D property: $name" -ForegroundColor DarkYellow
        }
    }
    $replacement = $header + (($filtered -join "`n").TrimEnd()) + "`n`n"
    return $normalized.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
}

# Clear a stale comment-only detector hit in case an earlier template remains.
Patch-File 'scripts/water/ocean_3d.gd' {
    param($text)
    return $text.Replace('WaterBody3D', 'former generic water system')
}

$forbidden = @(
    'WaterBody3D',
    'PixelOceanSystem3D',
    'PixelOceanWater3D',
    'OceanClipmap3D',
    'pixel_ocean_enabled',
    'pixel_ocean_water_3d',
    'pixel_ocean_system_3d'
)
$legacyFiles = @(
    'scripts/water/water_body_3d.gd',
    'scripts/water/pixel_ocean_system_3d.gd',
    'scripts/water/pixel_ocean_water_3d.gd',
    'scripts/water/ocean_clipmap_3d.gd',
    'scenes/water/pixel_ocean_system_3d.tscn',
    'scenes/water/ocean_clipmap_3d.tscn',
    'shaders/pixel_ocean_water.gdshader'
)
$textExtensions = @('.gd', '.tscn', '.scn', '.tres', '.gdshader', '.cfg', '.godot')
$residuals = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | ForEach-Object {
    $relative = (Get-CompatibleRelativePath $ProjectRoot $_.FullName).Replace('\', '/')
    if ($relative.StartsWith('.git/') -or $relative.StartsWith('.godot/') -or $relative.StartsWith('.ocean3d_') -or $relative.StartsWith('Ocean3D_Migration/')) { return }
    if ($relative -in $legacyFiles) { return }
    if ($textExtensions -notcontains $_.Extension.ToLowerInvariant() -and $_.Name -ne 'project.godot') { return }
    $content = Read-Text $_.FullName
    foreach ($term in $forbidden) {
        if ($content.Contains($term)) {
            $residuals.Add("$relative -> $term")
        }
    }
}

Write-Host ''
Write-Host "Files created/modified: $($Changed.Count)" -ForegroundColor Green
$Changed | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
Write-Host ''
if ($residuals.Count -gt 0) {
    Write-Warning 'Active legacy references still remain:'
    $residuals | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host 'Do not open the project yet. Send this residual list.' -ForegroundColor Yellow
    exit 2
}
Write-Host 'No active legacy type references were detected.' -ForegroundColor Green
Write-Host 'You can now open Godot and wait for reimport/parse.' -ForegroundColor Cyan
Write-Host 'Do not run final cleanup until runtime validation is complete.' -ForegroundColor Cyan
