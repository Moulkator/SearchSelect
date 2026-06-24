var script_class = "tool"
var filter_button: BaseButton
var search_button: BaseButton
var search_dialog: AcceptDialog
var search_input: LineEdit
var select_tool = null
var select_tool_panel = null
var input_listener = null

var filter_button_enabled = false

func _on_search_confirmed() -> void:
	search_and_select_all()

func start() -> void:
	# Register with _lib if available (active le verificateur de mise a jour)
	if Engine.has_signal("_lib_register_mod"):
		Engine.emit_signal("_lib_register_mod", self)
		if "API" in Global and Global.API.has("UpdateChecker"):
			var uc = Global.API.UpdateChecker
			uc.register(uc.builder()\
				.fetcher(uc.github_fetcher("Moulkator", "SearchSelect"))\
				.downloader(uc.github_downloader("Moulkator", "SearchSelect"))\
				.build())

	select_tool_panel = Global.Editor.Toolset.GetToolPanel("SelectTool")
	select_tool = Global.Editor.Tools["SelectTool"]
   
	search_button = select_tool_panel.CreateButton("Search & Select", "res://ui/icons/misc/search.png")
	search_button.connect("pressed", self, "show_search_dialog")
	
	# Create search dialog
	create_search_dialog()

	# Install a dedicated input listener (a tool script's own _input is
	# never called by DD, so we attach a Node with set_process_input(true)).
	_install_input_listener()


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "SearchSelectListener"
	var listener_script = GDScript.new()
	listener_script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -90
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	var tree = Global.Editor.get_tree()
	if tree and tree.root:
		tree.root.call_deferred("add_child", input_listener)


func _on_input(event: InputEvent) -> void:
	if not (event is InputEventKey): return
	if not event.pressed or event.echo: return
	if event.scancode != KEY_F or not event.control: return

	# Only trigger when the Select Tool is the active tool
	if not Global.Editor.Toolset.ToolPanels["SelectTool"].visible: return

	# Don't re-open if the dialog is already visible
	if search_dialog != null and search_dialog.visible: return

	show_search_dialog()
	input_listener.get_tree().set_input_as_handled()


func create_search_dialog() -> void:
	search_dialog = AcceptDialog.new()
	search_dialog.window_title = "Search and Select Assets"
	search_dialog.set_size(Vector2(350, 120))

	# Connexion du signal "confirmed" (clique sur "OK")
	search_dialog.connect("confirmed", self, "_on_search_confirmed")
	
	# Connect popup_hide signal to reset focus flag
	search_dialog.connect("popup_hide", self, "_on_search_dialog_closed")
	
	var vbox = VBoxContainer.new()
	search_dialog.add_child(vbox)
	
	var label = Label.new()
	label.text = "Enter search term (e.g., 'crystal', 'door', 'tree'):"
	vbox.add_child(label)
	
	search_input = LineEdit.new()
	search_input.placeholder_text = "Search term..."
	vbox.add_child(search_input)
	
	# Connexion de la touche Entree
	search_input.connect("text_entered", self, "_on_search_entered")
	
	# Connect focus signals to manage SearchHasFocus flag
	search_input.connect("focus_entered", self, "_on_search_input_focus_entered")
	search_input.connect("focus_exited", self, "_on_search_input_focus_exited")

	# Ajout à la scène
	Global.Editor.add_child(search_dialog)

func show_search_dialog() -> void:
	search_dialog.popup_centered()
	search_input.grab_focus()
	# Set the flag when dialog is shown
	Global.Editor.SearchHasFocus = true

func _on_search_dialog_closed() -> void:
	# Reset the flag when dialog is closed
	Global.Editor.SearchHasFocus = false

func _on_search_input_focus_entered() -> void:
	# Set the flag when search input gains focus
	Global.Editor.SearchHasFocus = true

func _on_search_input_focus_exited() -> void:
	# Reset the flag when search input loses focus
	Global.Editor.SearchHasFocus = false

func _on_search_entered(text: String) -> void:
	search_and_select_all()


func update(delta: float) -> void:
	if not (fmod(delta, 10.0)): return
	if Global.Editor.Toolset.ToolPanels["SelectTool"].visible:

		var selected = select_tool.Selected

		if selected.size() >= 1:
			filter_button.visible = true
		else:
			filter_button.visible = false
		
		# Search button is always visible when the select tool is active
		search_button.visible = true
		return
	
	filter_button.visible = false
	search_button.visible = false


func search_and_select_all() -> void:
	var search_term = search_input.text.strip_edges().to_lower()
	if search_term.empty():
		return
	
	
	var currentLevel = Global.World.levels[Global.World.CurrentLevelId]
	var matching_objects = []
	
	# Clear current selection
	select_tool.DeselectAll()
	
	# Search through all object types, respecting filters
	if is_type_filter_enabled("Objects"):
		search_in_objects(currentLevel.Objects, search_term, matching_objects)
	
	if is_type_filter_enabled("Portals"):
		search_in_portals(currentLevel.Portals, search_term, matching_objects)
	
	if is_type_filter_enabled("Walls"):
		search_in_walls(currentLevel.Walls, search_term, matching_objects)
	
	if is_type_filter_enabled("Paths"):
		search_in_paths(currentLevel.Pathways, search_term, matching_objects)
	
	if is_type_filter_enabled("Lights"):
		search_in_lights(currentLevel.Lights, search_term, matching_objects)
	
	if is_type_filter_enabled("Roofs"):
		search_in_roofs(currentLevel.Roofs, search_term, matching_objects)
	
	if is_type_filter_enabled("Patterns"):
		# Try to search pattern shapes if they exist
		if currentLevel.has_method("PatternShapes") or currentLevel.has_node("PatternShapes"):
			search_in_pattern_shapes(currentLevel.PatternShapes, search_term, matching_objects)
	
	# Select all matching objects
	for item in matching_objects:
		select_tool.SelectThing(item, true)
	
	if matching_objects.size() > 0:
		Global.Editor.Tools["SelectTool"].OnFinishSelection()
		select_tool_panel.OnSelect(get_selected_selectable_type())
		print("Found and selected ", matching_objects.size(), " objects matching '", search_term, "'")
	else:
		print("No objects found matching '", search_term, "'")
	
	search_dialog.hide()


# Get the selectable type of the selected nodes
func get_selected_selectable_type() -> int:

	if select_tool.RawSelectables.size() == 0: return 0

	for selectable in select_tool.RawSelectables:
		if selectable.Type != select_tool.RawSelectables[0].Type:
			return 0

	return select_tool.RawSelectables[0].Type

# Vérifie si le nom correspond au terme recherché.
# - Les underscores sont traités comme des espaces (DD affiche "vine_green"
#   comme "vine green"), donc la recherche fonctionne dans les deux sens.
# - L'ordre des termes n'a pas d'importance : "vine green" == "green vine".
#   Tous les mots du terme doivent être présents dans le nom.
func _name_matches(obj_name: String, search_term: String) -> bool:
	var normalized_name = obj_name.replace("_", " ")
	var normalized_term = search_term.replace("_", " ")
	var words = normalized_term.split(" ", false)
	if words.size() == 0:
		return false
	for word in words:
		if normalized_name.find(word) == -1:
			return false
	return true


# Fonction pour vérifier si un type d'objet est activé dans le filtre
func is_type_filter_enabled(type_name: String) -> bool:

	# Si le filtre n'existe pas ou s'il est activé (true), on inclut ce type
	return not select_tool.Filter.has(type_name) or select_tool.Filter[type_name]


# Fonction pour vérifier si un objet passe le filtre de calque
func passes_layer_filter(obj: Node2D) -> bool:
	
	# Essayer d'abord la fonction intégrée
	if select_tool.has_method("IsObjectLayerFiltered"):
		return not select_tool.IsObjectLayerFiltered(obj)
	
	# Sinon, implémenter manuellement la vérification
	var obj_layer = null
	
	# Chercher la propriété layer (peut être "layer", "Layer", etc.)
	var layer_properties = ["layer", "Layer", "LayerID", "layer_id"]
	for prop_name in layer_properties:
		if obj.has_property(prop_name):
			obj_layer = obj.get(prop_name)
			break
	
	# Si on ne trouve pas de propriété layer, inclure l'objet par défaut
	if obj_layer == null:
		return true
	
	# Vérifier si ce calque est activé dans le LayerFilter
	# Si le LayerFilter est vide ou ne contient pas cette clé, on inclut l'objet
	if select_tool.LayerFilter.empty() or not select_tool.LayerFilter.has(obj_layer):
		return true
	
	# Retourner l'état du filtre pour ce calque
	return select_tool.LayerFilter[obj_layer]


func search_in_objects(container: Node, search_term: String, matching_objects: Array) -> void:
	print("Searching in Objects container, found ", container.get_child_count(), " objects")
	for obj in container.get_children():
		var obj_name = get_object_name(obj).to_lower()
		print("  Checking object: '", obj_name, "'")
		
		# Vérifier le filtre de calque
		if not passes_layer_filter(obj):
			print("    Filtered out by layer filter")
			continue
			
		if _name_matches(obj_name, search_term):
			print("    MATCH found!")
			matching_objects.push_back(obj)


func search_in_portals(container: Node, search_term: String, matching_objects: Array) -> void:
	print("Searching in Portals container, found ", container.get_child_count(), " portals")
	for portal in container.get_children():
		var portal_name = get_object_name(portal).to_lower()
		print("  Checking portal: '", portal_name, "'")
		
		# Vérifier le filtre de calque
		if not passes_layer_filter(portal):
			print("    Filtered out by layer filter")
			continue
			
		if _name_matches(portal_name, search_term):
			print("    MATCH found!")
			matching_objects.push_back(portal)


func search_in_walls(container: Node, search_term: String, matching_objects: Array) -> void:
	print("Searching in Walls container, found ", container.get_child_count(), " walls")
	for wall in container.get_children():
		var wall_name = get_object_name(wall).to_lower()
		print("  Checking wall: '", wall_name, "'")
		
		# Vérifier le filtre de calque
		if not passes_layer_filter(wall):
			print("    Filtered out by layer filter")
			continue
			
		if _name_matches(wall_name, search_term):
			print("    MATCH found!")
			matching_objects.push_back(wall)
		
		# Also search portals within walls if portals are enabled
		if is_type_filter_enabled("Portals"):
			for portal in wall.get_children():
				var portal_name = get_object_name(portal).to_lower()
				print("  Checking wall portal: '", portal_name, "'")
				
				# Vérifier le filtre de calque pour les portails
				if not passes_layer_filter(portal):
					print("    Portal filtered out by layer filter")
					continue
					
				if _name_matches(portal_name, search_term):
					print("    MATCH found!")
					matching_objects.push_back(portal)


func search_in_paths(container: Node, search_term: String, matching_objects: Array) -> void:
	print("Searching in Pathways container, found ", container.get_child_count(), " paths")
	for path in container.get_children():
		var path_name = get_object_name(path).to_lower()
		print("  Checking path: '", path_name, "'")
		
		# Vérifier le filtre de calque
		if not passes_layer_filter(path):
			print("    Filtered out by layer filter")
			continue
			
		if _name_matches(path_name, search_term):
			print("    MATCH found!")
			matching_objects.push_back(path)


func search_in_lights(container: Node, search_term: String, matching_objects: Array) -> void:
	print("Searching in Lights container, found ", container.get_child_count(), " lights")
	for light in container.get_children():
		var light_name = get_object_name(light).to_lower()
		print("  Checking light: '", light_name, "'")
		
		# Vérifier le filtre de calque
		if not passes_layer_filter(light):
			print("    Filtered out by layer filter")
			continue
			
		if _name_matches(light_name, search_term):
			print("    MATCH found!")
			matching_objects.push_back(light)


func search_in_roofs(container: Node, search_term: String, matching_objects: Array) -> void:
	print("Searching in Roofs container, found ", container.get_child_count(), " roofs")
	for roof in container.get_children():
		var roof_name = get_object_name(roof).to_lower()
		print("  Checking roof: '", roof_name, "'")
		
		# Vérifier le filtre de calque
		if not passes_layer_filter(roof):
			print("    Filtered out by layer filter")
			continue
			
		if _name_matches(roof_name, search_term):
			print("    MATCH found!")
			matching_objects.push_back(roof)


func search_in_pattern_shapes(container: Node, search_term: String, matching_objects: Array) -> void:
	var shapes = []
	if container.has_method("GetShapes"):
		shapes = container.GetShapes()
	else:
		shapes = container.get_children()
	
	print("Searching in PatternShapes container, found ", shapes.size(), " shapes")
	for shape in shapes:
		var shape_name = get_object_name(shape).to_lower()
		print("  Checking shape: '", shape_name, "'")
		
		# Vérifier le filtre de calque
		if not passes_layer_filter(shape):
			print("    Filtered out by layer filter")
			continue
			
		if _name_matches(shape_name, search_term):
			print("    MATCH found!")
			matching_objects.push_back(shape)


func get_object_name(obj: Node) -> String:
	var obj_name = ""
	
	# Debug: Print object properties
	print("    Object type: ", obj.get_class())
	print("    Object name: ", obj.name)
	
	# Print all properties for debugging
	var property_list = obj.get_property_list()
	for prop in property_list:
		if prop.name in ["Texture", "_Texture", "TilesTexture", "texture"]:
			print("    Found property: ", prop.name, " = ", obj.get(prop.name))
	
	# Try different ways to get the texture path
	var texture_properties = ["Texture", "texture", "_Texture", "TilesTexture"]
	
	for prop_name in texture_properties:
		if obj.get(prop_name) != null:
			var texture_value = obj.get(prop_name)
			print("    Checking property '", prop_name, "': ", texture_value, " (type: ", typeof(texture_value), ")")
			
			if texture_value != null:
				if typeof(texture_value) == TYPE_STRING:
					obj_name = texture_value.get_file().get_basename()
					print("    Extracted from string: '", obj_name, "'")
					break
				elif texture_value.has_method("get_path"):
					var path = texture_value.get_path()
					if path != "":
						obj_name = path.get_file().get_basename()
						print("    Extracted from get_path(): '", obj_name, "'")
						break
				elif texture_value.has_property("resource_path"):
					var path = texture_value.resource_path
					if path != "":
						obj_name = path.get_file().get_basename()
						print("    Extracted from resource_path: '", obj_name, "'")
						break
	
	# If we couldn't get a texture name, use the node name
	if obj_name.empty():
		obj_name = obj.name
		print("    Using node name as fallback: '", obj_name, "'")
	
	print("    Final name: '", obj_name, "'")
	return obj_name