extends Control

## Persistent Foam V2 mask painter.
## Rasterizes the CPU-authoritative deposited splats into the mask SubViewport
## as foam COVERAGE. Stored world XZ is never modified here; only the anchor
## mapping, age fade and age growth are applied. Per-splat visual randomness
## (rotation, scale_x, scale_y) is stored ON the splat and reused verbatim on
## every repaint, so old foam never shimmers, crawls or moves.
##
## The ocean shader samples this texture via interpolated_world_xz and supplies
## the final foam appearance (breakup noise, color, roughness, reflection
## suppression), so this canvas only holds coverage data.

const SPLAT_TEXTURE_SIZE := 256
const BRUSH_SEED := 0xB00F55ED

var splats: Array[PersistentFoamSplat] = []
var viewport_time := 0.0
var lifetime := 20.0
var fade_in_ratio := 0.10
var fade_out_start_ratio := 0.70
var size_min := 0.65
var size_max := 1.65
var mask_anchor_xz := Vector2.ZERO
var mask_world_size := 512.0

var _splat_texture: Texture2D


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_splat_texture = _create_splat_texture()


## Deterministic irregular brush, generated ONCE at startup from a fixed seed.
## A union of soft overlapping lobes gives an organic silhouette with a stable
## radial falloff; it never changes between repaints.
func _create_splat_texture() -> Texture2D:
	var image := Image.create(SPLAT_TEXTURE_SIZE, SPLAT_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(float(SPLAT_TEXTURE_SIZE - 1) * 0.5, float(SPLAT_TEXTURE_SIZE - 1) * 0.5)
	var radius_px := SPLAT_TEXTURE_SIZE * 0.42
	var rng := RandomNumberGenerator.new()
	rng.seed = BRUSH_SEED
	var lobes: Array[Dictionary] = []
	for index in 7:
		lobes.append(
			{
				&"offset": Vector2.from_angle(rng.randf_range(0.0, TAU)) * rng.randf_range(0.0, radius_px * 0.34),
				&"radius": radius_px * rng.randf_range(0.52, 0.92),
			}
		)
	for y in SPLAT_TEXTURE_SIZE:
		for x in SPLAT_TEXTURE_SIZE:
			var pixel := Vector2(float(x), float(y))
			var falloff := 0.0
			for lobe in lobes:
				var lobe_center: Vector2 = center + lobe.get(&"offset")
				var lobe_radius: float = lobe.get(&"radius")
				var distance := clampf(
					(pixel - lobe_center).length() / maxf(lobe_radius, 0.001),
					0.0,
					1.05
				)
				falloff = maxf(falloff, 1.0 - smoothstep(0.55, 1.0, distance))
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(falloff, 0.0, 1.0)))
	var texture := ImageTexture.create_from_image(image)
	return texture


func mark_dirty() -> void:
	queue_redraw()


func _draw() -> void:
	if splats.is_empty() or mask_world_size <= 0.001:
		return
	var draw_center := size * 0.5
	var pixels_per_world := size.x / mask_world_size
	var base_disc := SPLAT_TEXTURE_SIZE * 0.5
	var texture_rect := Rect2(-base_disc, -base_disc, base_disc * 2.0, base_disc * 2.0)
	for splat: PersistentFoamSplat in splats:
		var age := viewport_time - splat.birth_time
		if age < 0.0 or age >= lifetime:
			continue
		var coverage := splat.intensity * _life_alpha_for_age(age)
		if coverage <= 0.001:
			continue
		var center_px := (
			(splat.position_xz - mask_anchor_xz) * pixels_per_world
		) + draw_center
		var growth := _growth_for_age(age)
		var base_radius_px := maxf(splat.radius * pixels_per_world, 0.5)
		var visual_radius := base_radius_px * growth
		var half_x := maxf(visual_radius * splat.scale_x, 0.5)
		var half_y := maxf(visual_radius * splat.scale_y, 0.5)
		draw_set_transform(
			center_px,
			splat.rotation,
			Vector2(half_x / base_disc, half_y / base_disc)
		)
		draw_texture_rect(
			_splat_texture,
			texture_rect,
			false,
			Color(1.0, 1.0, 1.0, clampf(coverage, 0.0, 1.0))
		)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func evaluate_life_alpha(age: float) -> float:
	return _life_alpha_for_age(age)


func evaluate_growth(age: float) -> float:
	return _growth_for_age(age)


func _growth_for_age(age: float) -> float:
	var ratio := clampf(age / maxf(lifetime, 0.001), 0.0, 1.0)
	var growth_t := smoothstep(0.0, 1.0, ratio)
	return lerpf(size_min, size_max, growth_t)


func _life_alpha_for_age(age: float) -> float:
	var ratio := age / maxf(lifetime, 0.001)
	if ratio <= 0.0 or ratio >= 1.0:
		return 0.0
	var birth := 1.0
	if fade_in_ratio > 0.0001:
		birth = smoothstep(0.0, fade_in_ratio, ratio)
	var death := 1.0
	if fade_out_start_ratio < 1.0:
		death = 1.0 - smoothstep(fade_out_start_ratio, 1.0, ratio)
	return birth * death


func smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)