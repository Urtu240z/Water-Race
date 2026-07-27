[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Text([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Backup-File([string]$Path, [string]$BackupRoot) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $projectUri = New-Object System.Uri(
        ([System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\')
    )
    $fileUri = New-Object System.Uri([System.IO.Path]::GetFullPath($Path))
    $relative = [System.Uri]::UnescapeDataString(
        $projectUri.MakeRelativeUri($fileUri).ToString()
    ).Replace('/', '\')

    $destination = Join-Path $BackupRoot $relative
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    Copy-Item -LiteralPath $Path -Destination $destination -Force
}

function Patch-File(
    [string]$RelativePath,
    [scriptblock]$Transform,
    [string]$BackupRoot,
    [System.Collections.Generic.List[string]]$Changed
) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $RelativePath"
    }

    $before = Read-Text $path
    $after = & $Transform $before

    if ($after -ne $before) {
        Backup-File $path $BackupRoot
        Write-Text $path $after
        $Changed.Add($RelativePath)
    }
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'project.godot'))) {
    throw "project.godot was not found in: $ProjectRoot"
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupRoot = Join-Path $ProjectRoot ".ocean3d_identity_backup_$timestamp"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

$Changed = [System.Collections.Generic.List[string]]::new()
$Deleted = [System.Collections.Generic.List[string]]::new()

Write-Host 'Ocean3D resource identity repair v1.4' -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot"
Write-Host "Backup:  $BackupRoot"
Write-Host ''

# -------------------------------------------------------------------------
# 1. Remove template scripts that Godot was parsing as duplicate classes.
# -------------------------------------------------------------------------
$duplicateTemplates = @(
    'Ocean3D_Migration/templates/ocean_3d.gd',
    'Ocean3D_Migration/templates/ocean_3d.gd.uid',
    'Ocean3D_Migration/templates/island_test_blender_bootstrap.gd',
    'Ocean3D_Migration/templates/island_test_blender_bootstrap.gd.uid'
)

foreach ($relative in $duplicateTemplates) {
    $path = Join-Path $ProjectRoot $relative
    if (Test-Path -LiteralPath $path) {
        Backup-File $path $BackupRoot
        Remove-Item -LiteralPath $path -Force
        $Deleted.Add($relative)
    }
}

# -------------------------------------------------------------------------
# 2. Make sure the renamed surface script really declares the new classes.
# -------------------------------------------------------------------------
Patch-File 'scripts/water/ocean_surface_3d.gd' {
    param($text)

    $text = $text.Replace('class_name OceanClipmap3D', 'class_name OceanSurface3D')
    $text = $text.Replace('OceanClipmap3D', 'OceanSurface3D')
    $text = $text.Replace('WaterBody3D', 'Ocean3D')
    $text = $text.Replace('physical_water', 'ocean')
    $text = $text.Replace('legacy_visual_water_material', 'ocean_material')
    $text = $text.Replace('_registered_physical_water', '_registered_ocean')
    $text = $text.Replace('base_height', 'water_level')
    $text = $text.Replace('ocean_clipmap_enabled', 'ocean_surface_enabled')

    return $text
} $BackupRoot $Changed

# -------------------------------------------------------------------------
# 3. Remove stale UIDs from the two generated scenes.
#    Godot will resolve the new resources from their new paths.
# -------------------------------------------------------------------------
Patch-File 'scenes/water/ocean_surface_3d.tscn' {
    param($text)

    $text = $text.Replace(
        'res://scripts/water/ocean_clipmap_3d.gd',
        'res://scripts/water/ocean_surface_3d.gd'
    )
    $text = $text.Replace(
        'res://shaders/water_transparent_legacy.gdshader',
        'res://shaders/ocean_water.gdshader'
    )
    $text = $text.Replace('OceanClipmap3D', 'OceanSurface3D')
    $text = $text.Replace('physical_water', 'ocean')
    $text = $text.Replace('legacy_visual_water_material', 'ocean_material')
    $text = $text.Replace('base_height', 'water_level')
    $text = $text.Replace('ocean_clipmap_enabled', 'ocean_surface_enabled')
    $text = $text.Replace('NodePath("../Physics")', 'NodePath("..")')

    $text = [regex]::Replace(
        $text,
        '(?m)^(\[gd_scene[^\r\n]*?)\s+uid="[^"]+"([^\r\n]*\])$',
        '$1$2'
    )
    $text = [regex]::Replace(
        $text,
        '(?m)^(\[ext_resource[^\r\n]*?)\s+uid="[^"]+"([^\r\n]*\])$',
        '$1$2'
    )

    return $text
} $BackupRoot $Changed

Patch-File 'scenes/water/ocean_3d.tscn' {
    param($text)

    $text = $text.Replace(
        'res://scripts/water/pixel_ocean_system_3d.gd',
        'res://scripts/water/ocean_3d.gd'
    )
    $text = $text.Replace(
        'res://scripts/water/pixel_ocean_water_3d.gd',
        'res://scripts/water/ocean_3d.gd'
    )
    $text = $text.Replace(
        'res://scripts/water/ocean_clipmap_3d.gd',
        'res://scripts/water/ocean_surface_3d.gd'
    )
    $text = $text.Replace(
        'res://scenes/water/ocean_clipmap_3d.tscn',
        'res://scenes/water/ocean_surface_3d.tscn'
    )
    $text = $text.Replace('PixelOceanSystem3D', 'Ocean3D')
    $text = $text.Replace('PixelOceanWater3D', 'Ocean3D')
    $text = $text.Replace('OceanClipmap3D', 'OceanSurface3D')
    $text = $text.Replace('NodePath("../Physics")', 'NodePath("..")')
    $text = $text.Replace('NodePath("Physics")', 'NodePath(".")')

    # Remove any obsolete Physics node block that survived the conversion.
    $text = [regex]::Replace(
        $text,
        '(?ms)^\[node name="Physics"[^\r\n]*\]\r?\n.*?(?=^\[node |\z)',
        ''
    )

    # Remove stale ext_resource declarations for the deleted physics script.
    $text = [regex]::Replace(
        $text,
        '(?m)^\[ext_resource[^\r\n]*pixel_ocean_water_3d\.gd[^\r\n]*\]\r?\n?',
        ''
    )

    $text = [regex]::Replace(
        $text,
        '(?m)^(\[gd_scene[^\r\n]*?)\s+uid="[^"]+"([^\r\n]*\])$',
        '$1$2'
    )
    $text = [regex]::Replace(
        $text,
        '(?m)^(\[ext_resource[^\r\n]*?)\s+uid="[^"]+"([^\r\n]*\])$',
        '$1$2'
    )

    return $text
} $BackupRoot $Changed

# -------------------------------------------------------------------------
# 4. Remove the cached global class list so Godot rebuilds it cleanly.
# -------------------------------------------------------------------------
$classCache = Join-Path $ProjectRoot '.godot/global_script_class_cache.cfg'
if (Test-Path -LiteralPath $classCache) {
    Backup-File $classCache $BackupRoot
    Remove-Item -LiteralPath $classCache -Force
    $Deleted.Add('.godot/global_script_class_cache.cfg')
}

# -------------------------------------------------------------------------
# 5. Validate the files before allowing Godot to reopen.
# -------------------------------------------------------------------------
$errors = [System.Collections.Generic.List[string]]::new()

$surfaceScript = Read-Text (
    Join-Path $ProjectRoot 'scripts/water/ocean_surface_3d.gd'
)
if (-not $surfaceScript.Contains('class_name OceanSurface3D')) {
    $errors.Add('ocean_surface_3d.gd does not declare OceanSurface3D.')
}
if ($surfaceScript.Contains('class_name OceanClipmap3D')) {
    $errors.Add('ocean_surface_3d.gd still declares OceanClipmap3D.')
}
if ($surfaceScript.Contains('WaterBody3D')) {
    $errors.Add('ocean_surface_3d.gd still contains WaterBody3D.')
}

$oceanScene = Read-Text (
    Join-Path $ProjectRoot 'scenes/water/ocean_3d.tscn'
)
if ($oceanScene.Contains('[node name="Physics"')) {
    $errors.Add('ocean_3d.tscn still contains a Physics child.')
}
if ($oceanScene.Contains('NodePath("../Physics")')) {
    $errors.Add('ocean_3d.tscn still points to ../Physics.')
}
if ($oceanScene.Contains('pixel_ocean_system_3d.gd')) {
    $errors.Add('ocean_3d.tscn still references the old wrapper script.')
}
if ($oceanScene.Contains('pixel_ocean_water_3d.gd')) {
    $errors.Add('ocean_3d.tscn still references the old physics script.')
}

$surfaceScene = Read-Text (
    Join-Path $ProjectRoot 'scenes/water/ocean_surface_3d.tscn'
)
if (-not $surfaceScene.Contains('res://scripts/water/ocean_surface_3d.gd')) {
    $errors.Add('ocean_surface_3d.tscn does not reference ocean_surface_3d.gd.')
}
if ($surfaceScene.Contains('ocean_clipmap_3d.gd')) {
    $errors.Add('ocean_surface_3d.tscn still references ocean_clipmap_3d.gd.')
}
if ($surfaceScene.Contains('NodePath("../Physics")')) {
    $errors.Add('ocean_surface_3d.tscn still points to ../Physics.')
}

foreach ($relative in $duplicateTemplates) {
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative)) {
        $errors.Add("Duplicate template still exists: $relative")
    }
}

Write-Host 'Modified:' -ForegroundColor Green
$Changed | Sort-Object -Unique | ForEach-Object {
    Write-Host "  $_"
}

Write-Host ''
Write-Host 'Removed or cleared:' -ForegroundColor Green
$Deleted | Sort-Object -Unique | ForEach-Object {
    Write-Host "  $_"
}

Write-Host ''
if ($errors.Count -gt 0) {
    Write-Host 'Repair validation failed:' -ForegroundColor Red
    $errors | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Red
    }
    Write-Host 'Keep Godot closed and send this output.' -ForegroundColor Yellow
    exit 2
}

Write-Host 'Ocean3D resource identity repair completed successfully.' -ForegroundColor Green
Write-Host 'Now reopen Godot and wait for the filesystem scan.' -ForegroundColor Cyan
Write-Host 'Do not run legacy cleanup yet.' -ForegroundColor Cyan
