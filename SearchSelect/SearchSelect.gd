var script_class = "tool"

const GREY_TEXT = Color(0.62, 0.65, 0.69)
const PANEL_BUTTON_INDEX = 12
var filter_button: BaseButton
var search_button: BaseButton
var search_dialog: AcceptDialog
var search_input: LineEdit
var select_tool = null
var select_tool_panel = null
var input_listener = null

var filter_button_enabled = false

# --- Select Similar (search by selected asset) ---
var tabs: Tabs
var keyword_box: VBoxContainer
var similar_box: VBoxContainer
var add_selection_check: CheckBox
var exact_check: CheckBox
var variants_check: CheckBox
var color_check: CheckBox
var similar_hint: Label
var _updating_checks = false
var _variation_regex: RegEx = null
var _dialog_positioned = false
var _last_ref_sig = ""

func _on_search_confirmed() -> void:
	if tabs != null and tabs.current_tab == 1:
		run_select_similar()
	else:
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

	# Custom icon shipped with the mod (Button draws its icon left of the text)
	var search_icon = _load_mod_icon("icons/search.png")
	if search_icon != null:
		search_button.icon = search_icon

	# CreateButton appends at the very end of the panel, after the (hidden)
	# selection-dependent sections; once something is selected those sections
	# become visible and the button ends up isolated at the bottom. Move it
	# up, just before the first hidden section, to keep it docked with the
	# always-visible buttons.
	_dock_button_with_main_group(search_button)
	
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

	# Escape closes the dialog (it is shown non-modal, so the built-in
	# modal Escape handling does not apply)
	if event.scancode == KEY_ESCAPE and search_dialog != null and search_dialog.visible:
		search_dialog.hide()
		input_listener.get_tree().set_input_as_handled()
		return

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
	# Keep the dialog open after a search; it is closed via the Close
	# button, the X, or Escape
	search_dialog.dialog_hide_on_ok = false
	search_dialog.get_ok().text = "Search"
	var close_btn = search_dialog.add_button("Close", true)
	close_btn.connect("pressed", search_dialog, "hide")
	_style_dialog_buttons()

	# Connexion du signal "confirmed" (clique sur "OK")
	search_dialog.connect("confirmed", self, "_on_search_confirmed")
	
	# Connect popup_hide signal to reset focus flag
	search_dialog.connect("popup_hide", self, "_on_search_dialog_closed")
	
	# Manual tabs: a Tabs bar + two content boxes swapped by visibility.
	# Unlike TabContainer, a VBoxContainer ignores hidden children in its
	# minimum size, so each tab gets its own compact height.
	var root_box = VBoxContainer.new()
	root_box.rect_min_size = Vector2(340, 0)
	search_dialog.add_child(root_box)

	tabs = Tabs.new()
	tabs.add_tab("Search Keyword")
	tabs.add_tab("Select Similar")
	tabs.connect("tab_changed", self, "_on_tab_changed")
	root_box.add_child(tabs)

	# --- Tab 1: keyword search ---
	keyword_box = VBoxContainer.new()
	root_box.add_child(keyword_box)
	
	var label = Label.new()
	label.text = "Enter search term (e.g., 'crystal', 'door', 'tree'):"
	label.add_color_override("font_color", GREY_TEXT)
	keyword_box.add_child(label)
	
	search_input = LineEdit.new()
	search_input.placeholder_text = "Search term..."
	keyword_box.add_child(search_input)

	# --- Tab 2: select similar to the current selection ---
	similar_box = VBoxContainer.new()
	similar_box.visible = false
	root_box.add_child(similar_box)

	similar_hint = Label.new()
	similar_hint.text = "Click an asset on the map to use it as reference."
	similar_hint.clip_text = true
	similar_hint.rect_min_size = Vector2(320, 0)
	similar_hint.add_color_override("font_color", GREY_TEXT)
	similar_box.add_child(similar_hint)

	exact_check = CheckBox.new()
	exact_check.text = "Exact Name"
	exact_check.pressed = true
	exact_check.connect("toggled", self, "_on_exact_toggled")
	similar_box.add_child(exact_check)

	variants_check = CheckBox.new()
	variants_check.text = "Name Variants (01, 02, A, B...)"
	variants_check.connect("toggled", self, "_on_variants_toggled")
	similar_box.add_child(variants_check)

	color_check = CheckBox.new()
	color_check.text = "Same Custom Color"
	similar_box.add_child(color_check)

	# Shared option (below both tabs, single state for both modes)
	add_selection_check = CheckBox.new()
	add_selection_check.text = "Add to current selection"
	root_box.add_child(add_selection_check)
	
	# Connexion de la touche Entree
	search_input.connect("text_entered", self, "_on_search_entered")
	
	# Connect focus signals to manage SearchHasFocus flag
	search_input.connect("focus_entered", self, "_on_search_input_focus_entered")
	search_input.connect("focus_exited", self, "_on_search_input_focus_exited")

	# Ajout à la scène
	Global.Editor.add_child(search_dialog)

func show_search_dialog() -> void:
	if search_dialog.visible:
		return
	# show() instead of popup_centered(): a modal popup would swallow map
	# clicks, which the Select Similar tab needs to pick a reference asset
	search_dialog.show()
	search_dialog.set_as_minsize()
	if not _dialog_positioned:
		var vp = search_dialog.get_viewport_rect().size
		search_dialog.rect_position = ((vp - search_dialog.rect_size) * 0.5).floor()
		_dialog_positioned = true
	_last_ref_sig = "-"
	if tabs.current_tab == 0:
		search_input.grab_focus()
		# Set the flag when the keyword input takes focus
		Global.Editor.SearchHasFocus = true


func _on_tab_changed(tab: int) -> void:
	keyword_box.visible = tab == 0
	similar_box.visible = tab == 1
	if tab == 0:
		if search_dialog.visible:
			search_input.grab_focus()
	else:
		if search_input.has_focus():
			search_input.release_focus()
		Global.Editor.SearchHasFocus = false
		_last_ref_sig = "-"
	# Shrink-wrap the dialog around the newly visible tab
	search_dialog.call_deferred("set_as_minsize")

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

		if filter_button != null:
			filter_button.visible = selected.size() >= 1
		
		# Search button is always visible when the select tool is active
		search_button.visible = true
		# Keep it docked above UP's Free Transform / Rotation slider inserts
		_dock_button_with_main_group(search_button)

		if search_dialog.visible:
			# Live hint on the Select Similar tab (refreshed on selection change)
			if tabs.current_tab == 1:
				_refresh_similar_hint(selected)
			# Shrink-wrap the dialog whenever its content min size changes
			var want = search_dialog.get_combined_minimum_size()
			if search_dialog.rect_size != want:
				search_dialog.rect_size = want
		return
	
	if filter_button != null:
		filter_button.visible = false
	search_button.visible = false
	if search_dialog != null and search_dialog.visible:
		search_dialog.hide()


func search_and_select_all() -> void:
	var search_term = search_input.text.strip_edges().to_lower()
	if search_term.empty():
		return
	
	
	var currentLevel = Global.World.levels[Global.World.CurrentLevelId]
	var matching_objects = []
	
	# Clear current selection unless additive mode is enabled
	if not add_selection_check.pressed:
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
	
	# Select all matching objects (skip the ones already selected)
	var already = {}
	for thing in select_tool.Selected:
		already[thing.get_instance_id()] = true
	for item in matching_objects:
		if already.has(item.get_instance_id()):
			continue
		select_tool.SelectThing(item, true)
	
	if matching_objects.size() > 0:
		Global.Editor.Tools["SelectTool"].OnFinishSelection()
		select_tool_panel.OnSelect(get_selected_selectable_type())
		print("Found and selected ", matching_objects.size(), " objects matching '", search_term, "'")
	else:
		print("No objects found matching '", search_term, "'")


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

# =====================================================================
# Select Similar: second search mode based on the current selection.
# The currently selected asset(s) act as the reference. Criteria:
#   - Exact Name:        every placed asset with the exact same name
#   - Name Variants:     same base name, ignoring suffixes (01, 02, A, B...)
#   - Same Custom Color: colorable objects sharing the same custom color
# Exact Name and Name Variants are mutually exclusive. When Same Custom
# Color is combined with a name criterion, both must match (AND).
# =====================================================================

func _refresh_similar_hint(selected: Array) -> void:
	var sig = str(selected.size())
	if selected.size() > 0 and is_instance_valid(selected[0]):
		sig += "_" + str(selected[0].get_instance_id())
	if sig == _last_ref_sig:
		return
	_last_ref_sig = sig

	if selected.size() == 0:
		similar_hint.text = "Click an asset on the map to use it as reference."
	else:
		var ref_name = ""
		if is_instance_valid(selected[0]):
			ref_name = _get_thing_name(selected[0])
		if selected.size() > 1:
			similar_hint.text = "Reference: %s (+%d more)" % [ref_name, selected.size() - 1]
		else:
			similar_hint.text = "Reference: %s" % ref_name


func _on_exact_toggled(pressed: bool) -> void:
	if _updating_checks: return
	if pressed:
		_updating_checks = true
		variants_check.pressed = false
		_updating_checks = false


func _on_variants_toggled(pressed: bool) -> void:
	if _updating_checks: return
	if pressed:
		_updating_checks = true
		exact_check.pressed = false
		_updating_checks = false


func run_select_similar() -> void:
	var use_exact = exact_check.pressed
	var use_variants = variants_check.pressed
	var use_color = color_check.pressed
	if not (use_exact or use_variants or use_color):
		print("Select Similar: no criterion checked")
		return

	# Capture the references BEFORE touching the selection
	var refs = []
	for thing in select_tool.Selected:
		if is_instance_valid(thing):
			refs.push_back(thing)
	if refs.empty():
		print("Select Similar: select at least one reference asset first")
		return

	# Reference names (exact or base names)
	var ref_names = {}
	if use_exact or use_variants:
		for r in refs:
			var n = _normalize_name(_get_thing_name(r))
			if n.empty():
				continue
			if use_variants:
				n = _get_base_name(n)
			ref_names[n] = true
		if ref_names.empty():
			print("Select Similar: could not resolve the name of the selected asset(s)")
			return

	# Reference colors
	var ref_colors = {}
	if use_color:
		for r in refs:
			var c = _get_reference_color_html(r)
			if not c.empty():
				ref_colors[c] = true
		if ref_colors.empty():
			print("Select Similar: no color found on the selected asset(s)")
			return

	var matching = []
	for thing in _collect_candidates():
		if use_exact or use_variants:
			var n = _normalize_name(_get_thing_name(thing))
			if use_variants:
				n = _get_base_name(n)
			if not ref_names.has(n):
				continue
		if use_color:
			# Only colorable objects can match the color criterion
			if not thing.get("hasCustomColor"):
				continue
			var c = thing.get("customColor")
			if c == null or not ref_colors.has(c.to_html()):
				continue
		matching.push_back(thing)

	# Keep the original references in the selection as well (dedup by instance)
	var final_set = {}
	for r in refs:
		final_set[r.get_instance_id()] = r
	for m in matching:
		final_set[m.get_instance_id()] = m

	# Clear current selection unless additive mode is enabled
	if not add_selection_check.pressed:
		select_tool.DeselectAll()
	var already = {}
	for thing in select_tool.Selected:
		already[thing.get_instance_id()] = true
	for item in final_set.values():
		if already.has(item.get_instance_id()):
			continue
		select_tool.SelectThing(item, true)

	select_tool.OnFinishSelection()
	select_tool_panel.OnSelect(get_selected_selectable_type())
	print("Select Similar: selected ", final_set.size(), " thing(s)")


# --- Name helpers ------------------------------------------------------

# Normalizes a name for comparison: lowercase, underscores as spaces
func _normalize_name(obj_name: String) -> String:
	return obj_name.to_lower().replace("_", " ").strip_edges()


# Strips trailing variation suffixes: "tree 01" / "tree01" / "tree a" -> "tree".
# A single trailing letter is only stripped when preceded by a separator, so
# names like "villa" are left untouched. Strips up to 2 suffixes so
# "bed a 01" and "bed b 02" share the base "bed".
func _get_base_name(normalized_name: String) -> String:
	if _variation_regex == null:
		_variation_regex = RegEx.new()
		_variation_regex.compile("^(.+?)(?:[ \\-]+(?:\\d+|[a-z])|\\d+)$")
	var base = normalized_name
	for _i in range(2):
		var res = _variation_regex.search(base)
		if res == null:
			break
		base = res.get_string(1).strip_edges()
	return base


# --- Color helper -------------------------------------------------------

func _get_reference_color_html(thing) -> String:
	if thing.get("hasCustomColor"):
		var c = thing.get("customColor")
		if c != null:
			return c.to_html()
	var col = thing.get("Color")
	if col != null and typeof(col) == TYPE_COLOR:
		return col.to_html()
	return ""


# --- Candidate collection (respects type and layer filters) -----------

func _collect_candidates() -> Array:
	var currentLevel = Global.World.levels[Global.World.CurrentLevelId]
	var out = []

	if is_type_filter_enabled("Objects"):
		for obj in currentLevel.Objects.get_children():
			if passes_layer_filter(obj):
				out.push_back(obj)

	if is_type_filter_enabled("Portals"):
		for portal in currentLevel.Portals.get_children():
			if passes_layer_filter(portal):
				out.push_back(portal)

	if is_type_filter_enabled("Walls") or is_type_filter_enabled("Portals"):
		for wall in currentLevel.Walls.get_children():
			if is_type_filter_enabled("Walls") and passes_layer_filter(wall):
				out.push_back(wall)
			# Portals anchored on walls live as wall children
			if is_type_filter_enabled("Portals"):
				for portal in wall.get_children():
					if passes_layer_filter(portal):
						out.push_back(portal)

	if is_type_filter_enabled("Paths"):
		for path in currentLevel.Pathways.get_children():
			if passes_layer_filter(path):
				out.push_back(path)

	if is_type_filter_enabled("Lights"):
		for light in currentLevel.Lights.get_children():
			if passes_layer_filter(light):
				out.push_back(light)

	if is_type_filter_enabled("Roofs"):
		for roof in currentLevel.Roofs.get_children():
			if passes_layer_filter(roof):
				out.push_back(roof)

	if is_type_filter_enabled("Patterns"):
		var shapes = []
		if currentLevel.PatternShapes.has_method("GetShapes"):
			shapes = currentLevel.PatternShapes.GetShapes()
		else:
			shapes = currentLevel.PatternShapes.get_children()
		for shape in shapes:
			if passes_layer_filter(shape):
				out.push_back(shape)

	return out


# Quiet version of get_object_name() (no debug spam) used by Select Similar
func _get_thing_name(obj: Node) -> String:
	var texture_properties = ["Texture", "texture", "_Texture", "TilesTexture"]
	for prop_name in texture_properties:
		var texture_value = obj.get(prop_name)
		if texture_value == null:
			continue
		if typeof(texture_value) == TYPE_STRING:
			return texture_value.get_file().get_basename()
		if texture_value is Resource and texture_value.resource_path != "":
			return texture_value.resource_path.get_file().get_basename()
		if texture_value.has_method("get_path"):
			var path = texture_value.get_path()
			if path != "":
				return path.get_file().get_basename()
	return obj.name


# --- Panel layout / icon helpers ---------------------------------------

# Loads a texture from the mod folder (res:// only works for DD's own assets)
func _load_mod_icon(icon_path: String) -> ImageTexture:
	var image = Image.new()
	if image.load(Global.Root + icon_path) != OK:
		print("SearchSelect: could not load icon ", Global.Root + icon_path)
		return null
	# Keep the icon at a reasonable button size
	if image.get_height() > 28:
		var scale = 28.0 / image.get_height()
		image.resize(int(image.get_width() * scale), 28, Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


# Keeps the button right after the native controls of the Select Tool panel
# (index 12 in the Align container — the same anchor the Unofficial Patch
# uses for its Free Transform group). Enforced every frame: UP inserts its
# Free Transform group and Rotation slider at indices 12-14 as one-shot
# moves, so re-asserting our index keeps Search & Select above them without
# depending on mod load order.
func _dock_button_with_main_group(btn: Control) -> void:
	var parent = btn.get_parent()
	if parent == null:
		return
	var target_idx = int(min(PANEL_BUTTON_INDEX, parent.get_child_count() - 1))
	if btn.get_index() != target_idx:
		parent.move_child(btn, target_idx)


# --- Dialog button styling ----------------------------------------------

# Search / Close share the bottom row 50/50, with a 1 px grey outline and
# 3 px rounded corners
func _style_dialog_buttons() -> void:
	var ok = search_dialog.get_ok()
	var row = ok.get_parent()
	if row == null:
		return
	# AcceptDialog surrounds its buttons with stretch spacers; hide them so
	# the buttons themselves share the full row width
	for i in range(row.get_child_count()):
		var child = row.get_child(i)
		if child is Button:
			child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			child.size_flags_stretch_ratio = 1.0
			_apply_button_style(child)
		else:
			child.visible = false
	row.add_constant_override("separation", 10)


func _apply_button_style(btn: Button) -> void:
	var bg_by_state = {
		"normal": Color(1, 1, 1, 0.04),
		"hover": Color(1, 1, 1, 0.10),
		"pressed": Color(1, 1, 1, 0.16),
		"disabled": Color(1, 1, 1, 0.02)
	}
	for state in bg_by_state:
		var sb = StyleBoxFlat.new()
		sb.bg_color = bg_by_state[state]
		sb.border_color = Color(0.5, 0.5, 0.5)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		btn.add_stylebox_override(state, sb)
	# No extra overlay when the button has keyboard focus
	btn.add_stylebox_override("focus", StyleBoxEmpty.new())
