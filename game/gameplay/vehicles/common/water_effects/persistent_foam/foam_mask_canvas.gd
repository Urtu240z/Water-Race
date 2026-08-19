extends Control

## Persistent Foam V2 mask painter.
## Rasterizes the CPU-authoritative deposited splats into the mask SubViewport
## as foam COVERAGE. Stored world XZ is never modified here; only the anchor
## mapping and age fade are applied. The ocean shader samples this texture via
## interpolated_world_xz and supplies the visual foam appearance (breakup noise,
## color, roughness, reflection suppression), so this canvas only holds data.

const SPLAT_TEXTURE_SIZE := 256

var splats: Array[PersistentFoamSplat] = []
var viewport_time := 0.0
var lifetime := 20.0
var fade_start_ratio := 0.70
var mask_anchor_xz := Vector2.ZERO
var mask_world_size := 512.0

var _splat_texture: GradientTexture2D


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_splat_texture = _create_splat_texture()


func _create_splat_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(0.5, 1.0)
	texture.width = SPLAT_TEXTURE_SIZE
	texture.height = SPLAT_TEXTURE_SIZE
	return texture


func mark_dirty() -> void:
	queue_redraw()


func _draw() -> void:
	if splats.is_empty() or mask_world_size <= 0.001:
		return
	var draw_center := size * 0.5
	var pixels_per_world := size.x / mask_world_size
	for splat: PersistentFoamSplat in splats:
		var age := viewport_time - splat.birth_time
		if age < 0.0 or age >= lifetime:
			continue
		var coverage := splat.intensity * _fade_for_age(age)
		if coverage <= 0.001:
			continue
		var center_px := (
			(splat.position_xz - mask_anchor_xz) * pixels_per_world
		) + draw_center
		var radius_px := maxf(splat.radius * pixels_per_world, 0.5)
		draw_texture_rect(
			_splat_texture,
			Rect2(
				center_px.x - radius_px,
				center_px.y - radius_px,
				radius_px * 2.0,
				radius_px * 2.0
			),
			false,
			Color(1.0, 1.0, 1.0, clampf(coverage, 0.0, 1.0))
		)


func _fade_for_age(age: float) -> float:
	var ratio := age / maxf(lifetime, 0.001)
	if ratio >= 1.0:
		return 0.0
	if ratio < fade_start_ratio:
		return 1.0
	var fade_window := 1.0 - fade_start_ratio
	var fade_t := clampf(
		(ratio - fade_start_ratio) / maxf(fade_window, 0.001),
		0.0,
		1.0
	)
	return 1.0 - fade_t * fade_t * (3.0 - 2.0 * fade_t)