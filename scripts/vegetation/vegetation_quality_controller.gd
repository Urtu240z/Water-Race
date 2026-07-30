class_name VegetationQualityController
extends Node

@export_node_path("Node3D") var sector_root_path := NodePath(
	"../Atrezzo/PalmsMultiMesh"
)
@export_node_path("Node3D") var atrezzo_root_path := NodePath("../Atrezzo")
@export_node_path("Node3D") var terrain_root_path := NodePath("../TerrainRoot")
@export_node_path("Node3D") var player_path := NodePath("../Gameplay/JetSki")

var _sector_root: Node3D
var _atrezzo_root: Node3D
var _terrain_root: Node3D
var _player: Node3D
var _sectors: Array[Node3D] = []
var _sector_meshes: Array[MultiMeshInstance3D] = []
var _impostors: Array[GeometryInstance3D] = []
var _ground_shadows: Array[GeometryInstance3D] = []
var _standalone_palm_visuals: Array[GeometryInstance3D] = []
var _full_3d_range: float = 4000.0
var _impostor_range: float = 4000.0
var _ground_shadow_range: float = 4000.0
var _ground_shadows_enabled: bool = true
var _real_shadows_enabled: bool = true
var _update_interval: float = 1.0 / 12.0
var _future_density_ratio: float = 1.0
var _quality_level: int = 2
var _elapsed: float = 0.0
var _last_player_position := Vector3(INF, INF, INF)
var _force_update: bool = true
var _visible_sector_count: int = 0
var _visible_impostor_count: int = 0
var _visible_ground_shadow_count: int = 0
var _stored_instance_count: int = 0
var _visible_instance_count: int = 0


func _ready() -> void:
	_resolve_references()
	_scan_vegetation()
	if (
		is_instance_valid(_player)
		and _player.has_signal(&"world_rebased")
		and not _player.world_rebased.is_connected(_on_world_rebased)
	):
		_player.world_rebased.connect(_on_world_rebased)
	set_process(true)
	_update_visibility(true)


func _process(delta: float) -> void:
	_elapsed += maxf(delta, 0.0)
	if not _force_update and _elapsed < _update_interval:
		return
	_elapsed = 0.0
	_update_visibility(false)


func set_graphics_quality(
	level: int,
	profile: GraphicsQualityProfile
) -> void:
	if profile == null:
		return
	_quality_level = clampi(level, 0, 2)
	_full_3d_range = profile.vegetation_full_3d_range
	_impostor_range = profile.vegetation_impostor_range
	_ground_shadow_range = profile.vegetation_ground_shadow_range
	_ground_shadows_enabled = profile.vegetation_ground_shadows_enabled
	_real_shadows_enabled = profile.vegetation_real_shadows_enabled
	_update_interval = 1.0 / maxf(
		profile.vegetation_update_rate_hz,
		1.0
	)
	_future_density_ratio = profile.vegetation_future_density_ratio
	_apply_geometry_ranges()
	_force_update = true
	if is_node_ready():
		_update_visibility(true)


func get_graphics_quality_debug_status() -> Dictionary:
	return {
		"sector_count": _sectors.size(),
		"visible_sector_count": _visible_sector_count,
		"multimesh_count": _sector_meshes.size(),
		"stored_instance_count": _stored_instance_count,
		"total_palm_instances": _stored_instance_count,
		"visible_palm_instances": _visible_instance_count,
		"visible_palm_sectors": _visible_sector_count,
		"full_3d_palm_sectors": _visible_sector_count,
		"impostor_palm_sectors": _visible_impostor_count,
		"ground_shadow_sectors": _visible_ground_shadow_count,
		"visible_impostor_count": _visible_impostor_count,
		"visible_ground_shadow_count": _visible_ground_shadow_count,
		"full_3d_range": _full_3d_range,
		"impostor_range": _impostor_range,
		"ground_shadow_range": _ground_shadow_range,
		"update_rate_hz": 1.0 / _update_interval,
		"future_density_ratio_not_applied": _future_density_ratio,
	}


func _resolve_references() -> void:
	_sector_root = get_node_or_null(sector_root_path) as Node3D
	_atrezzo_root = get_node_or_null(atrezzo_root_path) as Node3D
	_terrain_root = get_node_or_null(terrain_root_path) as Node3D
	_player = get_node_or_null(player_path) as Node3D


func _scan_vegetation() -> void:
	_sectors.clear()
	_sector_meshes.clear()
	_impostors.clear()
	_ground_shadows.clear()
	_standalone_palm_visuals.clear()
	_stored_instance_count = 0
	if is_instance_valid(_sector_root):
		for child: Node in _sector_root.get_children():
			var sector := child as Node3D
			if sector == null or not sector.name.begins_with("Sector_"):
				continue
			_sectors.append(sector)
			for candidate: Node in sector.find_children(
				"*",
				"MultiMeshInstance3D",
				true,
				false
			):
				var mesh := candidate as MultiMeshInstance3D
				if mesh == null:
					continue
				_sector_meshes.append(mesh)
				if mesh.multimesh != null:
					_stored_instance_count += mesh.multimesh.instance_count
	if is_instance_valid(_terrain_root):
		for candidate: Node in _terrain_root.find_children(
			"*",
			"GeometryInstance3D",
			true,
			false
		):
			var geometry := candidate as GeometryInstance3D
			if geometry == null:
				continue
			if "_SHADOW" in geometry.name:
				_ground_shadows.append(geometry)
			elif "SM_Palm_Impostor_Zone_" in geometry.name:
				_impostors.append(geometry)
	if is_instance_valid(_atrezzo_root):
		for child: Node in _atrezzo_root.get_children():
			if not child.name.begins_with("Palm_Tree"):
				continue
			var visual := child.get_node_or_null("Palm_VIS") as GeometryInstance3D
			if visual != null:
				_standalone_palm_visuals.append(visual)
	_apply_geometry_ranges()


func _apply_geometry_ranges() -> void:
	var real_shadow_mode := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if _real_shadows_enabled
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	for mesh: MultiMeshInstance3D in _sector_meshes:
		mesh.visibility_range_end = _full_3d_range
		mesh.cast_shadow = real_shadow_mode
	for visual: GeometryInstance3D in _standalone_palm_visuals:
		visual.visibility_range_end = _full_3d_range
		visual.cast_shadow = real_shadow_mode
	for impostor: GeometryInstance3D in _impostors:
		impostor.visibility_range_end = _impostor_range
	for shadow: GeometryInstance3D in _ground_shadows:
		shadow.visibility_range_end = _ground_shadow_range


func _update_visibility(force: bool) -> void:
	_force_update = false
	if not is_instance_valid(_player):
		return
	var player_position := _player.global_position
	if (
		not force
		and player_position.distance_squared_to(_last_player_position) < 25.0
	):
		return
	_last_player_position = player_position
	_visible_sector_count = 0
	_visible_instance_count = 0
	for sector: Node3D in _sectors:
		var visible_now := (
			sector.global_position.distance_to(player_position) <= _full_3d_range
		)
		sector.visible = visible_now
		_visible_sector_count += 1 if visible_now else 0
		if visible_now:
			for candidate: Node in sector.find_children(
				"*",
				"MultiMeshInstance3D",
				true,
				false
			):
				var mesh := candidate as MultiMeshInstance3D
				if mesh != null and mesh.multimesh != null:
					_visible_instance_count += mesh.multimesh.instance_count
	_visible_impostor_count = 0
	for impostor: GeometryInstance3D in _impostors:
		var distance := impostor.global_position.distance_to(player_position)
		var visible_now := (
			distance <= _impostor_range
			and (
				_quality_level == 2
				or distance > _full_3d_range * 0.75
			)
		)
		impostor.visible = visible_now
		_visible_impostor_count += 1 if visible_now else 0
	_visible_ground_shadow_count = 0
	for shadow: GeometryInstance3D in _ground_shadows:
		var visible_now := (
			_ground_shadows_enabled
			and shadow.global_position.distance_to(player_position)
				<= _ground_shadow_range
		)
		shadow.visible = visible_now
		_visible_ground_shadow_count += 1 if visible_now else 0
	for visual: GeometryInstance3D in _standalone_palm_visuals:
		visual.visible = (
			visual.global_position.distance_to(player_position) <= _full_3d_range
		)


func _on_world_rebased(_shift: Vector3) -> void:
	_force_update = true
