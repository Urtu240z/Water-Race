## Congela el billboard de los tree impostors mientras el jugador
## permanezca dentro de esta zona.
##
## El root es un Area3D. Al entrar el jugador, los MultiMeshInstance3D
## objetivo dejan de actualizar su orientación hacia la cámara congelando
## la referencia de cámara usada en el shader (`tree_impostor.gdshader`).
##
## Soporta varias zonas sobre el mismo MultiMesh mediante un registro
## estático compartido por instancia: solo se descongela cuando el contador
## de zonas activas vuelve a cero.
class_name TreeImpostorFrozen
extends Area3D


# ============================================================
# TARGETS
# ============================================================

@export_group("Targets")

# Manual prioritario. Puede apuntar a uno o varios MultiMeshInstance3D.
#
# Vacío -> se busca automáticamente (una sola vez) el MultiMeshInstance3D
# más cercano a esta zona.
@export var target_multimeshes: Array[NodePath] = []

# Si está activo y el array está vacío, busca el MultiMesh más cercano.
@export var auto_find_if_empty: bool = true

# Límite de distancia para la búsqueda automática (0 = sin límite).
@export_range(0.0, 500.0, 1.0)
var max_auto_search_distance: float = 150.0


# ============================================================
# BEHAVIOUR
# ============================================================

@export_group("Behaviour")

# Transición suave al descongelar (el billboard rota de vuelta a la cámara).
@export var smooth_unfreeze: bool = true

# Duración de la transición de descongelado.
@export_range(0.05, 2.0, 0.05)
var unfreeze_duration: float = 0.4


# ============================================================
# INTERNAL - SHARED REGISTRY (per MultiMeshInstance)
# ============================================================
#
# Clave: get_instance_id() del MultiMeshInstance3D.
#
# state = {
#   "count":      int     zonas activas que lo controlan
#   "orig_pos":   Vector3 posición de cámara capturada al congelar
#   "unfreeze_t": float   -1 sin transición; 1->0 durante el descongelado
#   "owner":      Object  zona que inició la transición (evita doble decay)
# }

static var _registry: Dictionary = {}


# ============================================================
# INTERNAL - PER ZONE
# ============================================================

var _resolved: bool = false

var _multimeshes: Array[MultiMeshInstance3D] = []

var _private_materials: Dictionary = {}

var _player_inside: bool = false


# ============================================================
# READY
# ============================================================

func _ready() -> void:

	# En el editor solo interesa editar la escena, no ejecutar la lógica.
	if Engine.is_editor_hint():
		return

	_resolve_targets()

	if _multimeshes.is_empty():
		return

	_prepare_private_materials()

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

	set_process(false)


# ============================================================
# RESOLVE TARGETS
# ============================================================

func _resolve_targets() -> void:

	if _resolved:
		return

	_resolved = true

	_multimeshes.clear()

	# --------------------------------------------------------
	# 1) Manual (prioritario)
	# --------------------------------------------------------

	if not target_multimeshes.is_empty():

		for target_path: NodePath in target_multimeshes:

			if target_path == NodePath(""):
				continue

			var target_node: Node = get_node_or_null(target_path)

			if target_node is MultiMeshInstance3D:

				_multimeshes.append(
					target_node as MultiMeshInstance3D
				)

			else:

				push_warning(
					"TreeImpostorFrozen %s: target %s not a MultiMeshInstance3D."
					% [name, target_path]
				)

		return

	# --------------------------------------------------------
	# 2) Fallback automático (solo una vez, al iniciar)
	# --------------------------------------------------------

	if auto_find_if_empty:

		var nearest: MultiMeshInstance3D = _find_nearest_multimesh()

		if nearest != null:

			_multimeshes.append(nearest)


func _find_nearest_multimesh() -> MultiMeshInstance3D:

	var candidates: Array[MultiMeshInstance3D] = []

	# 1) Grupo de vegetación (si los MultiMeshes llegaran a etiquetarse).
	for candidate: Node in get_tree().get_nodes_in_group(&"vegetation"):

		if candidate is MultiMeshInstance3D:

			candidates.append(
				candidate as MultiMeshInstance3D
			)

	# 2) Fallback: escaneo único de todo el árbol de la escena.
	if candidates.is_empty():

		_collect_multimeshes(
			get_tree().current_scene,
			candidates
		)

	return _pick_nearest(candidates)


func _collect_multimeshes(
	node: Node,
	collected: Array[MultiMeshInstance3D]
) -> void:

	if node == null:
		return

	if node is MultiMeshInstance3D:

		collected.append(
			node as MultiMeshInstance3D
		)

	for child: Node in node.get_children():

		_collect_multimeshes(
			child,
			collected
		)


func _pick_nearest(
	candidates: Array[MultiMeshInstance3D]
) -> MultiMeshInstance3D:

	if candidates.is_empty():
		return null

	var space_position: Vector3 = global_position

	var max_distance_squared: float = (
		INF
		if max_auto_search_distance <= 0.0
		else max_auto_search_distance * max_auto_search_distance
	)

	var best: MultiMeshInstance3D = null

	var best_distance_squared: float = max_distance_squared

	for candidate_mm: MultiMeshInstance3D in candidates:

		var distance_squared: float = (
			candidate_mm.global_position
				.distance_squared_to(space_position)
		)

		if distance_squared < best_distance_squared:

			best_distance_squared = distance_squared

			best = candidate_mm

	return best


# ============================================================
# PRIVATE MATERIALS
# ============================================================
#
# Para no congelar bosques de otras zonas que comparten el mismo
# ShaderMaterial, cada MultiMesh controlado recibe una instancia de
# material propia (una sola, reutilizable).

func _prepare_private_materials() -> void:

	_private_materials.clear()

	for multi_mesh: MultiMeshInstance3D in _multimeshes:

		var private_material: ShaderMaterial = (
			_make_private_material(multi_mesh)
		)

		if private_material != null:

			_private_materials[multi_mesh.get_instance_id()] = (
				private_material
			)


func _make_private_material(
	multi_mesh: MultiMeshInstance3D
) -> ShaderMaterial:

	if multi_mesh.multimesh == null:
		return null

	var mesh: Mesh = multi_mesh.multimesh.mesh

	if mesh == null:
		return null

	var material: Material = mesh.material

	if not material is ShaderMaterial:
		return null

	var shader_material: ShaderMaterial = (
		material as ShaderMaterial
	)

	# Ya tiene una copia privada preparada.
	if shader_material.get_meta("tree_impostor_frozen_private", false):
		return shader_material

	# Debe ser un impostor con el shader de billboard congelable.
	if shader_material.get_shader_parameter("freeze_billboard") == null:
		return null

	var private_copy: Material = (
		shader_material.duplicate()
	)

	if not private_copy is ShaderMaterial:
		return null

	var private_shader_material: ShaderMaterial = (
		private_copy as ShaderMaterial
	)

	private_shader_material.set_meta("tree_impostor_frozen_private", true)

	mesh.material = private_shader_material

	return private_shader_material


# ============================================================
# BODY SIGNALS
# ============================================================

func _on_body_entered(body: Node3D) -> void:

	if not _is_player(body):
		return

	_player_inside = true

	for multi_mesh: MultiMeshInstance3D in _multimeshes:

		var state: Dictionary = _get_state(multi_mesh)

		var first_entered: bool = state["count"] == 0

		state["count"] = int(state["count"]) + 1

		if first_entered:

			state["orig_pos"] = _get_camera_position()

			state["unfreeze_t"] = -1.0

			state["owner"] = null

		_apply(multi_mesh, state)


func _on_body_exited(body: Node3D) -> void:

	if not _is_player(body):
		return

	if not _player_inside:
		return

	_player_inside = false

	for multi_mesh: MultiMeshInstance3D in _multimeshes:

		var state: Dictionary = _get_state(multi_mesh)

		state["count"] = maxi(int(state["count"]) - 1, 0)

		# Aún hay otra zona activa -> sigue congelado.
		if int(state["count"]) > 0:

			_apply(multi_mesh, state)

			continue

		# Última zona saliendo -> descongelar.
		if smooth_unfreeze:

			state["unfreeze_t"] = 1.0

			state["owner"] = self

			_apply(multi_mesh, state)

			set_process(true)

		else:

			state["unfreeze_t"] = -1.0

			state["owner"] = null

			_apply(multi_mesh, state)


# ============================================================
# PROCESS - UNFREEZE TRANSITION
# ============================================================

func _process(delta: float) -> void:

	var any_work: bool = false

	var duration: float = maxf(unfreeze_duration, 0.001)

	for multi_mesh: MultiMeshInstance3D in _multimeshes:

		var state: Dictionary = _get_state(multi_mesh)

		# Re-congelado por otra zona durante la transición.
		if int(state["count"]) > 0:

			state["unfreeze_t"] = -1.0

			state["owner"] = null

			_apply(multi_mesh, state)

			continue

		if not state["owner"] == self:

			continue

		if float(state["unfreeze_t"]) < 0.0:

			state["owner"] = null

			continue

		var remaining: float = (
			float(state["unfreeze_t"]) - delta / duration
		)

		if remaining <= 0.0:

			state["unfreeze_t"] = -1.0

			state["owner"] = null

			_apply(multi_mesh, state)

		else:

			state["unfreeze_t"] = remaining

			_apply(multi_mesh, state)

			any_work = true

	set_process(any_work)


# ============================================================
# APPLY UNIFORMS
# ============================================================

func _apply(
	multi_mesh: MultiMeshInstance3D,
	state: Dictionary
) -> void:

	var private_material: ShaderMaterial = (
		_private_materials.get(
			multi_mesh.get_instance_id(),
			null
		)
	)

	if private_material == null:
		return

	var amount: float = 0.0

	if int(state["count"]) > 0:

		amount = 1.0

	elif float(state["unfreeze_t"]) >= 0.0:

		amount = float(state["unfreeze_t"])

	private_material.set_shader_parameter(
		"freeze_billboard",
		amount
	)

	# El shader usa frozen_camera_position con freeze_billboard = 1,
	# y mix() hacia la cámara real mientras freeze_billboard baja a 0.
	private_material.set_shader_parameter(
		"frozen_camera_position",
		state["orig_pos"]
	)


# ============================================================
# STATE HELPERS
# ============================================================

static func _get_state(
	multi_mesh: MultiMeshInstance3D
) -> Dictionary:

	var instance_id: int = multi_mesh.get_instance_id()

	if not _registry.has(instance_id):

		_registry[instance_id] = {
			"count": 0,
			"orig_pos": Vector3.ZERO,
			"unfreeze_t": -1.0,
			"owner": null,
		}

	return _registry[instance_id]


func _is_player(body: Node3D) -> bool:

	return body is JetSkiController


func _get_camera_position() -> Vector3:

	var camera: Camera3D = get_viewport().get_camera_3d()

	if camera != null:

		return camera.global_position

	return global_position