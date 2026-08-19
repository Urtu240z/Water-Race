extends Control

## Persistent Foam V2 - HISTORY MAP deposit rasterizer.
##
## Renders only NEW PersistentFoamDepositCommands (submitted since the last
## history update) into the single-use deposit SubViewport. The history manager
## consumes the stamp texture in the same pass and then clears this canvas, so
## no deposit is ever kept on the CPU after consumption; the GPU history
## texture becomes the sole authority.
##
## Deposit texture channels:
##   R = footprint * intensity  (the stamp's full-radius coverage gradient)
##   G = freshness flag (1 inside the stamp)
##   B = 0, A = 1
##
## World/UV mapping must match the history viewports: world XZ is mapped with
## the same anchor and world size so the update shader can combine both.

const SPLAT_TEXTURE_SIZE := 128
const BRUSH_SEED := 0xB00F55ED

var stamps: Array[PersistentFoamDepositCommand] = []
var anchor_xz := Vector2.ZERO
var world_size := 512.0

var _stamp_texture: Texture2D


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_stamp_texture = _create_stamp_texture()


## Deterministic irregular stamp, generated ONCE from a fixed seed. The RED
## channel carries the footprint gradient (1 at center, 0 at the stamp extent)
## and GREEN is hard 1 everywhere so the freshness flag is always set inside a
## stamp even at its very edge.
func _create_stamp_texture() -> Texture2D:
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
					1.0
				)
				falloff = maxf(falloff, 1.0 - smoothstep(0.55, 1.0, distance))
			image.set_pixel(x, y, Color(falloff, 1.0, 0.0, 1.0))
	var texture := ImageTexture.create_from_image(image)
	return texture


func clear_stamps() -> void:
	if stamps.is_empty():
		return
	stamps.clear()
	queue_redraw()


func mark_dirty() -> void:
	queue_redraw()


func _draw() -> void:
	if stamps.is_empty() or world_size <= 0.001:
		return
	var pixels_per_world := size.x / world_size
	if pixels_per_world <= 0.0:
		return
	var base := SPLAT_TEXTURE_SIZE * 0.5
	var texture_rect := Rect2(-base, -base, base * 2.0, base * 2.0)
	for stamp: PersistentFoamDepositCommand in stamps:
		if not stamp.world_xz.is_finite():
			continue
		var center_px := (
			(stamp.world_xz - anchor_xz) * pixels_per_world
		) + size * 0.5
		var base_radius_px := maxf(stamp.radius * pixels_per_world, 0.5)
		var half_x := maxf(base_radius_px * stamp.scale_x, 0.5)
		var half_y := maxf(base_radius_px * stamp.scale_y, 0.5)
		var forward := stamp.forward_xz
		var rotation := 0.0
		if forward.length_squared() > 0.0001:
			## Stamp +Y is the travel direction. Textures draw +Y down, so the
			## on-canvas forward angle is atan2(-forward_x, forward_z).
			rotation = atan2(-forward.x, forward.y)
		draw_set_transform(
			center_px,
			rotation,
			Vector2(half_x / base, half_y / base)
		)
		draw_texture_rect(
			_stamp_texture,
			texture_rect,
			false,
			Color(
				clampf(stamp.intensity, 0.0, 1.0),
				1.0,
				1.0,
				1.0
			)
		)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)