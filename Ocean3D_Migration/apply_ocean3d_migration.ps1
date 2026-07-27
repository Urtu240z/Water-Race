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
    $relativePath = [System.Uri]::UnescapeDataString($relativeUri.ToString())

    return $relativePath.Replace('/', [string]$separator)
}


function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$ProjectFile = Join-Path $ProjectRoot 'project.godot'
if (-not (Test-Path -LiteralPath $ProjectFile)) {
    throw "No se encuentra project.godot en: $ProjectRoot"
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupRoot = Join-Path $ProjectRoot ".ocean3d_backup_$timestamp"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

$Changed = [System.Collections.Generic.List[string]]::new()

function Backup-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $relative = (Get-CompatibleRelativePath $ProjectRoot $Path)
    $destination = Join-Path $BackupRoot $relative
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $destination -Force
}

function Set-ProjectFile([string]$RelativePath, [string]$Content) {
    $path = Join-Path $ProjectRoot $RelativePath
    Backup-File $path
    Write-Utf8NoBom $path $Content
    $Changed.Add($RelativePath)
}

function Patch-Literal([string]$RelativePath, [hashtable]$Replacements) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) { return }
    $before = Read-Text $path
    $after = $before
    foreach ($key in $Replacements.Keys) {
        $after = $after.Replace([string]$key, [string]$Replacements[$key])
    }
    if ($after -ne $before) {
        Backup-File $path
        Write-Utf8NoBom $path $after
        $Changed.Add($RelativePath)
    }
}

function Patch-Regex([string]$RelativePath, [string]$Pattern, [string]$Replacement) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) { return }
    $before = Read-Text $path
    $after = [regex]::Replace($before, $Pattern, $Replacement)
    if ($after -ne $before) {
        Backup-File $path
        Write-Utf8NoBom $path $after
        $Changed.Add($RelativePath)
    }
}

Write-Host "Ocean3D migration v1.1 (PowerShell 5.1 compatible)" -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot"
Write-Host "Backup:  $BackupRoot"

# Required current files.
$required = @(
    'scripts/water/pixel_ocean_water_3d.gd',
    'scripts/water/ocean_clipmap_3d.gd',
    'scenes/water/pixel_ocean_system_3d.tscn',
    'scenes/water/ocean_clipmap_3d.tscn',
    'shaders/pixel_ocean_water.gdshader'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative))) {
        throw "Falta el archivo requerido: $relative"
    }
}

# 1. Main Ocean3D script and bootstrap replacement.
Set-ProjectFile 'scripts/water/ocean_3d.gd' (Read-Text (Join-Path $PSScriptRoot 'templates/ocean_3d.gd'))
Set-ProjectFile 'scripts/levels/island_test_blender_bootstrap.gd' (Read-Text (Join-Path $PSScriptRoot 'templates/island_test_blender_bootstrap.gd'))

# 2. Derive OceanSurface3D from the complete current clipmap implementation.
$surfaceSource = Read-Text (Join-Path $ProjectRoot 'scripts/water/ocean_clipmap_3d.gd')
$surfaceSource = $surfaceSource.Replace('class_name OceanClipmap3D', 'class_name OceanSurface3D')
$surfaceSource = $surfaceSource.Replace('OceanClipmap3D', 'OceanSurface3D')
$surfaceSource = $surfaceSource.Replace('WaterBody3D', 'Ocean3D')
$surfaceSource = $surfaceSource.Replace('physical_water', 'ocean')
$surfaceSource = $surfaceSource.Replace('legacy_visual_water_material', 'ocean_material')
$surfaceSource = $surfaceSource.Replace('_registered_physical_water', '_registered_ocean')
$surfaceSource = $surfaceSource.Replace('base_height', 'water_level')
$surfaceSource = $surfaceSource.Replace('ocean_clipmap_enabled', 'ocean_surface_enabled')
$surfaceSource = $surfaceSource.Replace('persistent visual ShaderMaterial', 'persistent ocean ShaderMaterial')
Set-ProjectFile 'scripts/water/ocean_surface_3d.gd' $surfaceSource

# 3. Derive the shader from the current tuned shader, but remove provisional names.
$shaderSource = Read-Text (Join-Path $ProjectRoot 'shaders/pixel_ocean_water.gdshader')
$shaderSource = $shaderSource.Replace('// Pixel Ocean for Water Race.', '// Texture-driven ocean surface.')
$shaderSource = $shaderSource.Replace('pixel water shader', 'texture-driven water shader')
$shaderSource = $shaderSource.Replace('pixel_ocean_enabled', 'ocean_enabled')
$shaderSource = $shaderSource.Replace('base_height', 'water_level')
$shaderSource = $shaderSource.Replace('ocean_clipmap_enabled', 'ocean_surface_enabled')
Set-ProjectFile 'shaders/ocean_water.gdshader' $shaderSource

# 4. Derive the internal surface scene. Remove inherited UIDs from renamed resources.
$surfaceScene = Read-Text (Join-Path $ProjectRoot 'scenes/water/ocean_clipmap_3d.tscn')
$surfaceScene = [regex]::Replace($surfaceScene, ' uid="[^"]+"', '', 1)
$surfaceScene = $surfaceScene.Replace('res://scripts/water/ocean_clipmap_3d.gd', 'res://scripts/water/ocean_surface_3d.gd')
$surfaceScene = $surfaceScene.Replace('OceanClipmap3D', 'OceanSurface3D')
$surfaceScene = $surfaceScene.Replace('legacy_visual_water_material', 'ocean_material')
$surfaceScene = $surfaceScene.Replace('water_transparent_legacy.gdshader', 'ocean_water.gdshader')
$surfaceScene = $surfaceScene.Replace('base_height', 'water_level')
$surfaceScene = $surfaceScene.Replace('ocean_clipmap_enabled', 'ocean_surface_enabled')
Set-ProjectFile 'scenes/water/ocean_surface_3d.tscn' $surfaceScene

# 5. Build the single public ocean scene from the CURRENT tuned system scene.
$oldScenePath = Join-Path $ProjectRoot 'scenes/water/pixel_ocean_system_3d.tscn'
$oceanScene = (Read-Text $oldScenePath).Replace("`r`n", "`n")

# Renamed resource paths and neutral naming.
$oceanScene = $oceanScene.Replace('res://scripts/water/pixel_ocean_system_3d.gd', 'res://scripts/water/ocean_3d.gd')
$oceanScene = $oceanScene.Replace('res://scenes/water/ocean_clipmap_3d.tscn', 'res://scenes/water/ocean_surface_3d.tscn')
$oceanScene = $oceanScene.Replace('res://shaders/pixel_ocean_water.gdshader', 'res://shaders/ocean_water.gdshader')
$oceanScene = $oceanScene.Replace('PixelOceanSystem3D', 'Ocean3D')
$oceanScene = $oceanScene.Replace('PixelOceanWater3D', 'Ocean3D')
$oceanScene = $oceanScene.Replace('OceanClipmap3D', 'OceanSurface3D')
$oceanScene = $oceanScene.Replace('pixel_ocean_material', 'ocean_material')
$oceanScene = $oceanScene.Replace('pixel_ocean_enabled', 'ocean_enabled')
$oceanScene = $oceanScene.Replace('base_height', 'water_level')
$oceanScene = $oceanScene.Replace('physical_water', 'ocean')
$oceanScene = $oceanScene.Replace('legacy_visual_water_material', 'ocean_material')
$oceanScene = $oceanScene.Replace('ocean_clipmap_enabled', 'ocean_surface_enabled')

# New file must not reuse the old scene UID.
$oceanScene = [regex]::Replace(
    $oceanScene,
    '^\[gd_scene([^\]]*?)\s+uid="[^"]+"([^\]]*)\]',
    '[gd_scene$1$2]',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)

# Remove the obsolete physics script ext_resource line.
$oceanScene = [regex]::Replace(
    $oceanScene,
    '^\[ext_resource[^\n]*pixel_ocean_water_3d\.gd[^\n]*\]\n',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)

# Strip UIDs from renamed ext_resource lines so Godot assigns correct ones.
$oceanScene = [regex]::Replace(
    $oceanScene,
    '(?m)^\[ext_resource([^\n]*?(?:ocean_3d\.gd|ocean_surface_3d\.tscn|ocean_water\.gdshader)[^\n]*?)\s+uid="[^"]+"([^\n]*)\]$',
    '[ext_resource$1$2]'
)

$physicsMatch = [regex]::Match(
    $oceanScene,
    '(?ms)^\[node name="Physics"[^\n]*\]\n(?<body>.*?)(?=^\[node |\z)'
)
if (-not $physicsMatch.Success) {
    throw 'No se ha encontrado el nodo Physics dentro de pixel_ocean_system_3d.tscn.'
}

$physicsLines = $physicsMatch.Groups['body'].Value -split "`n"
$physicsProperties = [System.Collections.Generic.List[string]]::new()
$skipPrefixes = @(
    'process_priority =',
    'process_physics_priority =',
    'visible =',
    'script =',
    'follow_target =',
    'follow_target_path =',
    'ripple_emitter_target ='
)
foreach ($line in $physicsLines) {
    $trimmed = $line.Trim()
    if (-not $trimmed) { continue }
    $skip = $false
    foreach ($prefix in $skipPrefixes) {
        if ($trimmed.StartsWith($prefix)) { $skip = $true; break }
    }
    if (-not $skip) { $physicsProperties.Add($line) }
}

$rootMatch = [regex]::Match(
    $oceanScene,
    '(?ms)^\[node name="Ocean3D"[^\n]*\]\n(?<body>.*?)(?=^\[node |\z)'
)
if (-not $rootMatch.Success) {
    throw 'No se ha encontrado el nodo raíz Ocean3D tras la conversión.'
}

$rootBlock = $rootMatch.Value.TrimEnd("`n")
foreach ($propertyLine in $physicsProperties) {
    # Avoid duplicate property assignments already present on the wrapper root.
    $propertyName = ($propertyLine -split '=', 2)[0].Trim()
    if ($propertyName -and $rootBlock -match "(?m)^$([regex]::Escape($propertyName))\s*=") {
        continue
    }
    $rootBlock += "`n$propertyLine"
}
$rootBlock += "`n"

$oceanScene = $oceanScene.Remove($rootMatch.Index, $rootMatch.Length).Insert($rootMatch.Index, $rootBlock)
# Re-find after root replacement, then remove Physics.
$physicsMatch = [regex]::Match(
    $oceanScene,
    '(?ms)^\[node name="Physics"[^\n]*\]\n.*?(?=^\[node |\z)'
)
if ($physicsMatch.Success) {
    $oceanScene = $oceanScene.Remove($physicsMatch.Index, $physicsMatch.Length)
}

# Surface now points to its parent Ocean3D instead of ../Physics.
$oceanScene = $oceanScene.Replace('NodePath("../Physics")', 'NodePath("..")')
$oceanScene = $oceanScene.Replace('node_paths=PackedStringArray("ocean")', 'node_paths=PackedStringArray("ocean")')
Set-ProjectFile 'scenes/water/ocean_3d.tscn' $oceanScene

# 6. Patch active consumers with canonical names. Exact files are used to avoid
# blindly rewriting unrelated third-party or archived code.
$canonicalPatches = @{
    'scripts/vehicle/jet_ski_controller.gd' = @{
        '@export_node_path("WaterBody3D") var water_body_path' = '@export_node_path("Ocean3D") var ocean_path'
        '_water_body' = '_ocean'
        'water_body_path' = 'ocean_path'
        'get_water_body' = 'get_ocean'
        'WaterBody3D' = 'Ocean3D'
        'water_body' = 'ocean'
    }
    'scripts/effects/vehicle_water_effects_3d.gd' = @{
        '@export_node_path("WaterBody3D") var water_body_path' = '@export_node_path("Ocean3D") var ocean_path'
        'water_body_path' = 'ocean_path'
        'get_water_body' = 'get_ocean'
        'WaterBody3D' = 'Ocean3D'
        '_water' = '_ocean'
    }
    'scripts/world/world_origin_controller.gd' = @{
        '@export_node_path("WaterBody3D") var water_body_path' = '@export_node_path("Ocean3D") var ocean_path'
        '_water_body' = '_ocean'
        'water_body_path' = 'ocean_path'
        'get_water_body' = 'get_ocean'
        'WaterBody3D' = 'Ocean3D'
        'water_body' = 'ocean'
    }
    'scripts/course/buoy_3d.gd' = @{
        'WaterBody3D' = 'Ocean3D'
        'water_body_path' = 'ocean_path'
        '_water_body' = '_ocean'
        '_resolve_water_body' = '_resolve_ocean'
        '_find_water_body' = '_find_ocean'
        'water body' = 'ocean'
        'WaterBody' = 'Ocean'
    }
    'scripts/wildlife/ambient_wildlife_controller.gd' = @{
        'PixelOceanWater3D' = 'Ocean3D'
        'water_body_path' = 'ocean_path'
        '_water_body' = '_ocean'
        'base_height' = 'water_level'
    }
}
foreach ($relative in $canonicalPatches.Keys) {
    Patch-Literal $relative $canonicalPatches[$relative]
}

# Scene property names and node paths.
$sceneFiles = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'scenes') -Recurse -File -Include *.tscn,*.scn
foreach ($file in $sceneFiles) {
    $relative = (Get-CompatibleRelativePath $ProjectRoot $file.FullName).Replace('\', '/')
    if ($relative -in @(
        'scenes/water/pixel_ocean_system_3d.tscn',
        'scenes/water/ocean_clipmap_3d.tscn'
    )) { continue }
    Patch-Literal $relative @{
        'res://scenes/water/pixel_ocean_system_3d.tscn' = 'res://scenes/water/ocean_3d.tscn'
        'res://scenes/water/ocean_clipmap_3d.tscn' = 'res://scenes/water/ocean_surface_3d.tscn'
        'PixelOceanSystem/Physics' = 'Ocean'
        'PixelOceanSystem/Surface' = 'Ocean/Surface'
        'PixelOceanSystem' = 'Ocean'
        'water_body_path =' = 'ocean_path ='
        'physical_water_path =' = 'ocean_path ='
        'water_body_path"' = 'ocean_path"'
        'physical_water_path"' = 'ocean_path"'
    }
    Patch-Regex $relative '(?m)^ocean_clipmap_path\s*=.*\r?\n' ''
}

# Main scene node should be named Ocean, and its bootstrap should point to it.
$mainScene = 'scenes/levels/island_test/island_test_BLENDER.tscn'
Patch-Literal $mainScene @{
    '[node name="PixelOceanSystem"' = '[node name="Ocean"'
    'NodePath("WaterIntegration/PixelOceanSystem/Physics")' = 'NodePath("WaterIntegration/Ocean")'
    'NodePath("WaterIntegration/PixelOceanSystem")' = 'NodePath("WaterIntegration/Ocean")'
    'NodePath("../WaterIntegration/PixelOceanSystem/Physics")' = 'NodePath("../WaterIntegration/Ocean")'
    'NodePath("../WaterIntegration/PixelOceanSystem")' = 'NodePath("../WaterIntegration/Ocean")'
}
Patch-Regex $mainScene '(?m)^ocean_clipmap_path\s*=.*\r?\n' ''

# Patch active scripts/scenes that may still refer to renamed classes or paths.
$textExtensions = @('.gd', '.tscn', '.scn', '.tres', '.gdshader', '.cfg', '.godot')
$excludeRelative = @(
    'scripts/water/water_body_3d.gd',
    'scripts/water/pixel_ocean_system_3d.gd',
    'scripts/water/pixel_ocean_water_3d.gd',
    'scripts/water/ocean_clipmap_3d.gd',
    'scenes/water/pixel_ocean_system_3d.tscn',
    'scenes/water/ocean_clipmap_3d.tscn',
    'shaders/pixel_ocean_water.gdshader'
)
Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | ForEach-Object {
    $relative = (Get-CompatibleRelativePath $ProjectRoot $_.FullName).Replace('\', '/')
    if ($relative.StartsWith('.git/') -or $relative.StartsWith('.godot/') -or $relative.StartsWith('.ocean3d_backup_') -or $relative.StartsWith('Ocean3D_Migration/')) { return }
    if ($relative -in $excludeRelative) { return }
    if ($textExtensions -notcontains $_.Extension.ToLowerInvariant() -and $_.Name -ne 'project.godot') { return }
    Patch-Literal $relative @{
        'PixelOceanSystem3D' = 'Ocean3D'
        'PixelOceanWater3D' = 'Ocean3D'
        'OceanClipmap3D' = 'OceanSurface3D'
        'res://scripts/water/pixel_ocean_system_3d.gd' = 'res://scripts/water/ocean_3d.gd'
        'res://scripts/water/pixel_ocean_water_3d.gd' = 'res://scripts/water/ocean_3d.gd'
        'res://scripts/water/ocean_clipmap_3d.gd' = 'res://scripts/water/ocean_surface_3d.gd'
        'res://scenes/water/pixel_ocean_system_3d.tscn' = 'res://scenes/water/ocean_3d.tscn'
        'res://scenes/water/ocean_clipmap_3d.tscn' = 'res://scenes/water/ocean_surface_3d.tscn'
        'res://shaders/pixel_ocean_water.gdshader' = 'res://shaders/ocean_water.gdshader'
        'pixel_ocean_enabled' = 'ocean_enabled'
        'ocean_clipmap_enabled' = 'ocean_surface_enabled'
    }
}

# The replaced bootstrap has one canonical path; ensure the main scene property
# names match it after all broad patches.
Patch-Literal $mainScene @{
    'physical_water_path =' = 'ocean_path ='
    'water_body_path =' = 'ocean_path ='
}
Patch-Regex $mainScene '(?m)^ocean_clipmap_path\s*=.*\r?\n' ''

# 7. Copy macro-wave source assets to a neutral folder. Keep the old folder
# temporarily so the legacy scene remains recoverable until cleanup.
$oldWaveFolder = Join-Path $ProjectRoot 'resources/water/pixel_ocean'
$newWaveFolder = Join-Path $ProjectRoot 'resources/water/ocean'
if (Test-Path -LiteralPath $oldWaveFolder) {
    New-Item -ItemType Directory -Path $newWaveFolder -Force | Out-Null
    Get-ChildItem -LiteralPath $oldWaveFolder -File | Where-Object { $_.Extension -ne '.import' } | ForEach-Object {
        $destination = Join-Path $newWaveFolder $_.Name
        if (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $_.FullName -Destination $destination
            $Changed.Add((Get-CompatibleRelativePath $ProjectRoot $destination).Replace('\', '/'))
        }
    }
    Patch-Literal 'scenes/water/ocean_3d.tscn' @{
        'res://resources/water/pixel_ocean/' = 'res://resources/water/ocean/'
    }
    # Remove stale UID declarations only on the two moved ext_resource lines.
    Patch-Regex 'scenes/water/ocean_3d.tscn' '(?m)^(\[ext_resource[^\n]*res://resources/water/ocean/[^\n]*?)\s+uid="[^"]+"([^\n]*\])$' '$1$2'
}

# 8. Report residual active references. Old source files and backup are excluded.
$forbidden = @(
    'PixelOceanSystem3D',
    'PixelOceanWater3D',
    'OceanClipmap3D',
    'WaterBody3D',
    'pixel_ocean_system_3d',
    'pixel_ocean_water_3d',
    'pixel_ocean_enabled',
    'ocean_clipmap_enabled'
)
$residuals = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | ForEach-Object {
    $relative = (Get-CompatibleRelativePath $ProjectRoot $_.FullName).Replace('\', '/')
    if ($relative.StartsWith('.git/') -or $relative.StartsWith('.godot/') -or $relative.StartsWith('.ocean3d_backup_') -or $relative.StartsWith('Ocean3D_Migration/')) { return }
    if ($relative -in $excludeRelative) { return }
    if ($textExtensions -notcontains $_.Extension.ToLowerInvariant() -and $_.Name -ne 'project.godot') { return }
    $content = Read-Text $_.FullName
    foreach ($term in $forbidden) {
        if ($content.Contains($term)) {
            $residuals.Add("$relative -> $term")
        }
    }
}

Write-Host ""
Write-Host "Archivos creados/modificados: $($Changed.Count)" -ForegroundColor Green
$Changed | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
Write-Host ""
if ($residuals.Count -gt 0) {
    Write-Warning 'Quedan referencias legacy activas. NO ejecutes todavía el script de limpieza:'
    $residuals | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
} else {
    Write-Host 'No se detectan referencias legacy activas fuera de los archivos antiguos.' -ForegroundColor Green
}
Write-Host ""
Write-Host 'Siguiente paso: abre Godot, espera la reimportación y sigue VALIDATION_CHECKLIST.md.' -ForegroundColor Cyan
Write-Host 'No borres todavía los archivos antiguos.' -ForegroundColor Cyan
