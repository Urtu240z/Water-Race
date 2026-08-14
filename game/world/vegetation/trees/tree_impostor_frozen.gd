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
@tool
class_name TreeImpostorFrozen
extends Area3D


# ============================================================
# AREA - TRIGGER SIZE FROM ROOT
# ============================================================

@export_group("Area")

# Tamaño físico real del trigger. Controla internamente
# CollisionShape3D.shape.size (BoxShape3D).
#
# El root debe mantener Scale = (1,1,1): todo el dimensionado se hace con
# este export, no con non-uniform scale del Area3D (Godot desaconseja
# escalar CollisionShape3D). Compatible con @tool: al cambiar aquí se
# actualiza el BoxShape3D al instante, sin Editable Children.
@export var area_size: Vector3 = Vector3(20, 20, 20):
	set(value):
		if area_size == value:
			return
		area_size = value
		_update_collision_shape()


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
@export var smooth_unfreeze: bool = false

# Duración de la transición de descongelado.
@export_range(0.05, 2.0, 0.05)
var unfreeze_duration: float = 0.4


# ============================================================
# DIAGNOSTICS
# ============================================================

@export_group("Diagnostics")

# Instrumentación temporal: imprime entradas/salidas de body, counts y
# freeze_billboard en runtime para diagnosticar detección/premanencia.
@export var debug_events: bool = false


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

# Ids capturados al resolver (válidos aunque el nodo se libere después).
var _multimesh_ids: Array[int] = []

# Contribución de ESTA zona a cada MultiMesh controlado (id -> entero).
#
# Solo se usa para poder retirar la contribución propia si la zona se
# destruye o si un MultiMesh deja de ser válido, sin tocar otras zonas.
var _zone_contributions: Dictionary = {}

var _player_inside: bool = false


# ============================================================
# READY
# ============================================================

func _ready() -> void:

	# Sincroniza el BoxShape3D con area_size (también en editor). Robusto:
	# no falla si el hijo o su shape aún no están disponibles en la carga.
	_update_collision_shape()

	# En el editor solo interesa editar la escena, no ejecutar la lógica.
	if Engine.is_editor_hint():
		return

	_resolve_targets()

	if _multimeshes.is_empty():
		return

	_multimesh_ids.clear()

	for multi_mesh: MultiMeshInstance3D in _multimeshes:

		_multimesh_ids.append(
			multi_mesh.get_instance_id()
		)

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

	set_process(false)


# ============================================================
# AREA - COLLISION SHAPE SYNC
# ============================================================

# Aplica area_size al BoxShape3D del CollisionShape3D hijo, permitiendo
# dimensionar el trigger desde el root de la instancia sin Editable
# Children. Cada instancia tiene su propio BoxShape3D (resource_local_to_scene).
func _update_collision_shape() -> void:

	var shape_node: CollisionShape3D = (
		get_node_or_null("CollisionShape3D") as CollisionShape3D
	)

	if shape_node == null:
		return

	var shape := shape_node.shape as BoxShape3D

	if shape == null:
		return

	if shape.size == area_size:
		return

	shape.size = area_size


# ============================================================
# EXIT TREE - CLEANUP
# ============================================================

func _exit_tree() -> void:

	# En el editor no hay lógica activa.
	if Engine.is_editor_hint():
		return

	# La zona desaparece: retira SOLO su propia contribución a cada
	# MultiMesh, sin resetear zonas que sigan activas.
	for instance_id: int in _zone_contributions:

		var contribution: int = int(_zone_contributions[instance_id])

		if contribution > 0:

			_release_contribution(instance_id)

			continue

		# La contribución de esta zona ya es 0, pero puede que siga siendo
		# owner de una transición de descongelado en curso (edge case:
		# el jugador salió de la última zona con smooth_unfreeze y la zona
		# se destruye a mitad de la transición). Cancelarla y restaurar
		# freeze_billboard = 0.
		_cancel_own_transition(instance_id)


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

			if not target_node is MultiMeshInstance3D:

				push_warning(
					"TreeImpostorFrozen "
					+ name
					+ ": target "
					+ String(target_path)
					+ " is not a MultiMeshInstance3D."
				)

				continue

			var target_mm: MultiMeshInstance3D = (
				target_node as MultiMeshInstance3D
			)

			if not _is_compatible_multimesh(target_mm):

				# Un target no compatible (p. ej. TreeShadows) se ignora con
				# warning, pero NO interrumpe el resto de targets del array.
				push_warning(
					"TreeImpostorFrozen "
					+ name
					+ ": target "
					+ String(target_path)
					+ " is not a compatible tree impostor "
					+ "(tree_impostor.gdshader with freeze_billboard)."
				)

				continue

			_multimeshes.append(target_mm)

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

		if not candidate is MultiMeshInstance3D:
			continue

		var candidate_mm: MultiMeshInstance3D = (
			candidate as MultiMeshInstance3D
		)

		if _is_compatible_multimesh(candidate_mm):

			candidates.append(candidate_mm)

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

		var candidate_mm: MultiMeshInstance3D = (
			node as MultiMeshInstance3D
		)

		if _is_compatible_multimesh(candidate_mm):

			collected.append(candidate_mm)

	for child: Node in node.get_children():

		_collect_multimeshes(
			child,
			collected
		)


# ============================================================
# COMPATIBILITY
# ============================================================

func _is_compatible_multimesh(
	multi_mesh: MultiMeshInstance3D
) -> bool:

	if not is_instance_valid(multi_mesh):
		return false

	if multi_mesh.multimesh == null:
		return false

	var mesh: Mesh = multi_mesh.multimesh.mesh

	if mesh == null:
		return false

	# El material efectivo de render es material_override si está presente
	# (p. ej. TreeShadows usa override con tree_impostor_shadow.gdshader).
	var material: Material = multi_mesh.material_override

	if material == null:
		material = mesh.material

	if not material is ShaderMaterial:
		return false

	# freezebillboard y frozen_camera_position son INSTANCE UNIFORMS del
	# shader efectivo, no shader_parameter del ShaderMaterial. Detectar su
	# existencia no puede hacerse con get_shader_parameter() (devuelve null
	# incluso en compatibles hasta que se escribe la primera instancia) ni
	# con get_shader_uniform_list() (omite los instance uniforms). Por eso
	# se inspecciona la declaración del shader efectivo.
	var shader_material: ShaderMaterial = (
		material as ShaderMaterial
	)

	if shader_material.shader == null:
		return false

	return _shader_declares_freeze_billboard(shader_material.shader)


# Devuelve true si el shader efectivo declara el instance uniform
# `freeze_billboard` del tree impostor compatible.
static func _shader_declares_freeze_billboard(shader: Shader) -> bool:

	if shader == null:
		return false

	return shader.get_code().contains(
		"instance uniform float freeze_billboard"
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
# BODY SIGNALS
# ============================================================

func _on_body_entered(body: Node3D) -> void:

	if debug_events:
		print(
			"[TreeImpostorFrozen ", name, "] BODY_ENTER body=",
			str(body.get_path()) if body != null else "<null>",
			" isPlayer=", body is JetSkiController,
		)

	if not _is_player(body):
		return

	_player_inside = true

	for multi_mesh: MultiMeshInstance3D in _multimeshes:

		if not is_instance_valid(multi_mesh):
			continue

		var instance_id: int = multi_mesh.get_instance_id()

		# Contribución de esta zona (defensivo ante enter dobles).
		_zone_contributions[instance_id] = (
			int(_zone_contributions.get(instance_id, 0)) + 1
		)

		var state: Dictionary = _get_state(multi_mesh)

		var first_entered: bool = state["count"] == 0

		state["count"] = int(state["count"]) + 1

		if first_entered:

			state["orig_pos"] = _get_camera_position()

			state["unfreeze_t"] = -1.0

			state["owner"] = null

		_apply(multi_mesh, state)

		if debug_events:
			print(
				"[TreeImpostorFrozen ", name, "]   mm=", multi_mesh.name,
				" count=", state["count"],
				" freeze=", multi_mesh.get_instance_shader_parameter("freeze_billboard"),
			)


func _on_body_exited(body: Node3D) -> void:

	if not _is_player(body):
		return

	if not _player_inside:
		return

	_player_inside = false

	for index: int in range(_multimeshes.size()):

		var instance_id: int = _multimesh_ids[index]

		# Solo decrementa si ESTA zona aportó al contador del MultiMesh.
		var my_contribution: int = int(
			_zone_contributions.get(instance_id, 0)
		)

		if my_contribution <= 0:
			continue

		_zone_contributions[instance_id] = my_contribution - 1

		var multi_mesh: MultiMeshInstance3D = _multimeshes[index]

		if not is_instance_valid(multi_mesh):
			continue

		var state: Dictionary = _get_state(multi_mesh)

		var count_before: int = int(state["count"])

		state["count"] = maxi(int(state["count"]) - 1, 0)

		if debug_events:
			print(
				"[TreeImpostorFrozen ", name, "] BODY_EXIT body=",
				str(body.get_path()) if body != null else "<null>",
				" jetski_pos=", body.global_position if body != null else Vector3.ZERO,
				" zone_pos=", global_position,
				" count_before=", count_before,
				" count_after=", state["count"],
			)

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

		if debug_events:
			print(
				"[TreeImpostorFrozen ", name, "]   UNFREEZE mm=",
				multi_mesh.name,
				" freeze=",
				multi_mesh.get_instance_shader_parameter("freeze_billboard"),
			)


# ============================================================
# PROCESS - UNFREEZE TRANSITION
# ============================================================

func _process(delta: float) -> void:

	var any_work: bool = false

	var duration: float = maxf(unfreeze_duration, 0.001)

	for index: int in range(_multimeshes.size()):

		var multi_mesh: MultiMeshInstance3D = _multimeshes[index]

		# MultiMesh dejó de ser válido: retira la contribución de esta zona.
		if not is_instance_valid(multi_mesh):

			_release_contribution(_multimesh_ids[index])

			continue

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

	if not is_instance_valid(multi_mesh):
		return

	var amount: float = 0.0

	if int(state["count"]) > 0:

		amount = 1.0

	elif float(state["unfreeze_t"]) >= 0.0:

		amount = float(state["unfreeze_t"])

	# Instance uniforms: valores por MultiMeshInstance3D, sin duplicar
	# el ShaderMaterial compartido entre bosques.
	multi_mesh.set_instance_shader_parameter(
		"freeze_billboard",
		amount
	)

	# El shader usa frozen_camera_position con freeze_billboard = 1,
	# y mix() hacia la cámara real mientras freeze_billboard baja a 0.
	multi_mesh.set_instance_shader_parameter(
		"frozen_camera_position",
		state["orig_pos"]
	)


# ============================================================
# STATE HELPERS
# ============================================================

static func _get_state(
	multi_mesh: MultiMeshInstance3D
) -> Dictionary:

	return _registry_state(multi_mesh.get_instance_id())


static func _registry_state(instance_id: int) -> Dictionary:

	if not _registry.has(instance_id):

		_registry[instance_id] = {
			"count": 0,
			"orig_pos": Vector3.ZERO,
			"unfreeze_t": -1.0,
			"owner": null,
		}

	return _registry[instance_id]


func _get_multimesh_by_id(instance_id: int) -> MultiMeshInstance3D:

	for index: int in range(_multimeshes.size()):

		if _multimesh_ids[index] == instance_id:

			return _multimeshes[index]

	return null


# ============================================================
# CONTRIBUTION CLEANUP
# ============================================================

func _release_contribution(instance_id: int) -> void:

	var my_contribution: int = int(
		_zone_contributions.get(instance_id, 0)
	)

	if my_contribution <= 0:
		return

	_zone_contributions[instance_id] = 0

	var state: Dictionary = _registry_state(instance_id)

	var remaining: int = maxi(
		int(state["count"]) - my_contribution,
		0
	)

	state["count"] = remaining

	# Si al retirar esta zona ya no queda nadie activo, restaurar freeze.
	if remaining == 0:

		state["unfreeze_t"] = -1.0

		state["owner"] = null

		var multi_mesh: MultiMeshInstance3D = (
			_get_multimesh_by_id(instance_id)
		)

		if multi_mesh != null and is_instance_valid(multi_mesh):

			_apply(multi_mesh, state)


func _is_player(body: Node3D) -> bool:

	return body is JetSkiController


# Cancela la transición de descongelado de un MultiMesh solo si ESTA zona
# es su owner y el contador ya llegó a 0 (edge case de smooth_unfreeze con
# la zona destruida a mitad de transición). Restaura freeze_billboard = 0.
#
# No toca nada si count > 0 (otra zona sigue activa) o si el owner es otra
# zona.
func _cancel_own_transition(instance_id: int) -> void:

	var state: Dictionary = _registry_state(instance_id)

	if int(state["count"]) > 0:
		return

	if not state["owner"] == self:
		return

	if float(state["unfreeze_t"]) < 0.0:
		return

	state["unfreeze_t"] = -1.0

	state["owner"] = null

	var multi_mesh: MultiMeshInstance3D = (
		_get_multimesh_by_id(instance_id)
	)

	if multi_mesh != null and is_instance_valid(multi_mesh):

		_apply(multi_mesh, state)


func _get_camera_position() -> Vector3:

	var camera: Camera3D = get_viewport().get_camera_3d()

	if camera != null:

		return camera.global_position

	return global_position
