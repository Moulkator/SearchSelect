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
var root_box: VBoxContainer
var keyword_box: VBoxContainer
var similar_box: VBoxContainer
var add_selection_check: CheckBox
var remove_selection_check: CheckBox
var exact_check: CheckBox
var variants_check: CheckBox
var color_check: CheckBox
var tag_check: CheckBox
var shadow_check: CheckBox
var similar_hint: Label
# path -> {tag: true} built lazily from DD's tag database (see _get_tags_index)
var _tags_index = null
var _tags_index_world_id = -1
var _updating_checks = false
var _variation_regex: RegEx = null
var _dialog_positioned = false
var _last_ref_sig = ""

# --- Find in Library (show library assets matching a placed asset's name) ---
const TAB_KEYWORD = 0
const TAB_SIMILAR = 1
const TAB_LIBRARY = 2
var lookup_box: VBoxContainer
var lookup_hint: Label
var lookup_words_grid: GridContainer
var lookup_any_check: CheckBox
var lookup_plural_check: CheckBox
var lookup_count_label: Label
var lookup_strictness: HSlider
# Cached copy of ObjectLibraryPanel.searchEngine (see _get_search_engine)
var _se_cache = {}
var _se_retry_at = 0
# word -> [index keys, similarities], for the current plural option
var _word_sims = {}
# word -> Array of textures, for the current strictness / plural option
var _word_tex_cache = {}
# Debounce: apply a slider change once it stops moving (msec, 0 = none)
var _strict_apply_at = 0
# Strictness to (re)push into DD's slider once the library panel shows up:
# ObjectLibraryPanel.Load() restores its saved strictness one frame after
# the Object tool opens, which would undo the value we set (see
# _maintain_library_strictness). null = nothing pending.
var _pending_dd_strictness = null
var _pending_dd_frames = 0
var _library_was_visible = false
var _warned_no_strictness = false
# Array of [CheckBox, word] for the word picker of the current reference
var _lookup_word_checks = []
var _last_lookup_sig = ""

func _on_search_confirmed() -> void:
	if tabs != null and tabs.current_tab == TAB_LIBRARY:
		run_library_lookup()
	elif tabs != null and tabs.current_tab == TAB_SIMILAR:
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
	root_box = VBoxContainer.new()
	root_box.rect_min_size = Vector2(340, 0)
	search_dialog.add_child(root_box)

	tabs = Tabs.new()
	tabs.add_tab("Search Keyword")
	tabs.add_tab("Select Similar")
	tabs.add_tab("Find in Library")
	# Left-aligned: centered tabs need twice the arrow room to all fit
	tabs.tab_align = Tabs.ALIGN_LEFT
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

	tag_check = CheckBox.new()
	tag_check.text = "Shared Tag (objects only)"
	tag_check.hint_tooltip = "Objects that share at least one library tag with the reference"
	similar_box.add_child(tag_check)

	shadow_check = CheckBox.new()
	shadow_check.text = "Same Soft Shadow"
	shadow_check.hint_tooltip = "Same Soft Shadow mod settings (or both without a soft shadow)"
	similar_box.add_child(shadow_check)

	# --- Tab 3: find the reference's name in the Object Library ---
	lookup_box = VBoxContainer.new()
	lookup_box.visible = false
	root_box.add_child(lookup_box)

	lookup_hint = Label.new()
	lookup_hint.text = "Click an asset on the map to use it as reference."
	lookup_hint.clip_text = true
	lookup_hint.rect_min_size = Vector2(320, 0)
	lookup_hint.add_color_override("font_color", GREY_TEXT)
	lookup_box.add_child(lookup_hint)

	var words_label = Label.new()
	words_label.text = "Words to include in the library search:"
	lookup_box.add_child(words_label)

	# Column count follows the dialog width (see _layout_word_grid)
	lookup_words_grid = GridContainer.new()
	lookup_words_grid.columns = 3
	lookup_words_grid.add_constant_override("hseparation", 12)
	lookup_box.add_child(lookup_words_grid)

	lookup_box.add_child(HSeparator.new())

	lookup_any_check = CheckBox.new()
	lookup_any_check.text = "Match any word (instead of all)"
	lookup_any_check.connect("toggled", self, "_on_lookup_option_toggled")
	lookup_box.add_child(lookup_any_check)

	lookup_plural_check = CheckBox.new()
	lookup_plural_check.text = "Include singular / plural forms"
	lookup_plural_check.pressed = true
	lookup_plural_check.connect("toggled", self, "_on_lookup_plural_toggled")
	lookup_box.add_child(lookup_plural_check)

	# Same scale as the strictness slider of DD's Object Library search
	var strict_row = HBoxContainer.new()
	lookup_box.add_child(strict_row)
	var fuzzy_label = Label.new()
	fuzzy_label.text = "Fuzzy"
	strict_row.add_child(fuzzy_label)
	lookup_strictness = _build_strictness_slider()
	lookup_strictness.connect("value_changed", self, "_on_lookup_strictness_changed")
	strict_row.add_child(lookup_strictness)
	var exact_label = Label.new()
	exact_label.text = "Exact"
	strict_row.add_child(exact_label)

	lookup_count_label = Label.new()
	lookup_count_label.add_color_override("font_color", GREY_TEXT)
	lookup_box.add_child(lookup_count_label)

	# Shared option (below both tabs, single state for both modes)
	add_selection_check = CheckBox.new()
	add_selection_check.text = "Add to current selection"
	add_selection_check.connect("toggled", self, "_on_add_selection_toggled")
	root_box.add_child(add_selection_check)

	# Subtractive mode: matches are removed from the current selection
	# (mutually exclusive with "Add to current selection")
	remove_selection_check = CheckBox.new()
	remove_selection_check.text = "Remove from current selection"
	remove_selection_check.hint_tooltip = "Deselect the matching assets instead of selecting them"
	remove_selection_check.connect("toggled", self, "_on_remove_selection_toggled")
	root_box.add_child(remove_selection_check)
	
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
	# Soft Shadow criterion only makes sense when the Soft Shadow mod is loaded
	shadow_check.visible = _is_soft_shadow_mod_loaded()
	if not shadow_check.visible:
		shadow_check.pressed = false
	search_dialog.show()
	_sync_strictness_from_library()
	_fit_tabs_width()
	search_dialog.set_as_minsize()
	if not _dialog_positioned:
		var vp = search_dialog.get_viewport_rect().size
		search_dialog.rect_position = ((vp - search_dialog.rect_size) * 0.5).floor()
		_dialog_positioned = true
	_last_ref_sig = "-"
	_last_lookup_sig = "-"
	if tabs.current_tab == TAB_KEYWORD:
		search_input.grab_focus()
		# Set the flag when the keyword input takes focus
		Global.Editor.SearchHasFocus = true


# Godot 3's Tabs reports a zero minimum width and falls back to scroll
# arrows when its tabs don't fit: widen the content so every tab shows.
# Computed while in the tree, so DD's theme (and Enlarge UI) is applied.
func _fit_tabs_width() -> void:
	var font = tabs.get_font("font")
	if font == null:
		return
	var sb_fg = tabs.get_stylebox("tab_fg")
	var sb_bg = tabs.get_stylebox("tab_bg")
	var pad = 0.0
	if sb_fg != null:
		pad = sb_fg.get_minimum_size().x
	if sb_bg != null:
		pad = max(pad, sb_bg.get_minimum_size().x)
	var total = 0.0
	for i in range(tabs.get_tab_count()):
		total += font.get_string_size(tabs.get_tab_title(i)).x + pad
	# Tabs subtracts the width of both scroll arrows from the space it
	# gives the tabs, even when the arrows are hidden
	for icon_name in ["increment", "decrement"]:
		var icon = tabs.get_icon(icon_name)
		if icon != null:
			total += icon.get_width()
	root_box.rect_min_size.x = max(root_box.rect_min_size.x, ceil(total) + 16.0)


# Safety net run every frame: if the scroll arrows still show, the tabs
# don't fit yet, so widen a bit more (converges in a few frames, once).
func _ensure_all_tabs_visible() -> void:
	if not tabs.has_method("get_offset_buttons_visible"):
		return
	if not tabs.get_offset_buttons_visible():
		return
	if tabs.has_method("get_tab_offset") and tabs.get_tab_offset() > 0:
		# Scrolled by the arrows earlier: scroll back to the first tab
		tabs.ensure_tab_visible(0)
		return
	if root_box.rect_min_size.x < 1200.0:
		root_box.rect_min_size.x += 8.0


func _on_tab_changed(tab: int) -> void:
	keyword_box.visible = tab == TAB_KEYWORD
	similar_box.visible = tab == TAB_SIMILAR
	lookup_box.visible = tab == TAB_LIBRARY
	# Add / Remove selection options don't apply to the library lookup
	add_selection_check.visible = tab != TAB_LIBRARY
	remove_selection_check.visible = tab != TAB_LIBRARY
	search_dialog.get_ok().text = "Show in Library" if tab == TAB_LIBRARY else "Search"
	if tab == TAB_KEYWORD:
		if search_dialog.visible:
			search_input.grab_focus()
	else:
		if search_input.has_focus():
			search_input.release_focus()
		Global.Editor.SearchHasFocus = false
		_last_ref_sig = "-"
		_last_lookup_sig = "-"
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
	_maintain_library_strictness()
	if Global.Editor.Toolset.ToolPanels["SelectTool"].visible:

		var selected = select_tool.Selected

		if filter_button != null:
			filter_button.visible = selected.size() >= 1
		
		# Search button is always visible when the select tool is active
		search_button.visible = true
		# Keep it docked above UP's Free Transform / Rotation slider inserts
		_dock_button_with_main_group(search_button)

		if search_dialog.visible:
			_ensure_all_tabs_visible()
			# Live hint on the Select Similar tab (refreshed on selection change)
			if tabs.current_tab == TAB_SIMILAR:
				_refresh_similar_hint(selected)
			elif tabs.current_tab == TAB_LIBRARY:
				_refresh_lookup_words(selected)
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

	# Subtractive mode: deselect the selected things matching the term
	if remove_selection_check.pressed:
		var to_remove = {}
		for thing in select_tool.Selected:
			if not is_instance_valid(thing):
				continue
			if _name_matches(_get_thing_name(thing).to_lower(), search_term):
				to_remove[thing.get_instance_id()] = true
		var removed = _remove_from_selection(to_remove)
		print("Removed ", removed, " thing(s) matching '", search_term, "' from the selection")
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
#   - Shared Tag:        objects sharing at least one library tag
#   - Same Soft Shadow:  same Soft Shadow mod settings (or none on both)
# Exact Name and Name Variants are mutually exclusive. All other checked
# criteria must match together (AND).
# =====================================================================

func _refresh_similar_hint(selected: Array) -> void:
	var removing = remove_selection_check.pressed
	var sig = str(selected.size()) + ("r" if removing else "s")
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
		if removing:
			# Subtractive mode only uses the first selected asset as reference
			similar_hint.text = "Reference: %s (first of %d selected)" % [ref_name, selected.size()]
		elif selected.size() > 1:
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


func _on_add_selection_toggled(pressed: bool) -> void:
	if _updating_checks: return
	if pressed:
		_updating_checks = true
		remove_selection_check.pressed = false
		_updating_checks = false
	_last_ref_sig = "-"


func _on_remove_selection_toggled(pressed: bool) -> void:
	if _updating_checks: return
	if pressed:
		_updating_checks = true
		add_selection_check.pressed = false
		_updating_checks = false
	_last_ref_sig = "-"


# Deselects the things whose instance id is a key of to_remove and keeps the
# rest selected. Rebuilds the selection (DeselectAll + reselect) so it does
# not depend on a per-thing deselect method. Returns the removed count.
func _remove_from_selection(to_remove: Dictionary) -> int:
	var keep = []
	var removed = 0
	for thing in select_tool.Selected:
		if not is_instance_valid(thing):
			continue
		if to_remove.has(thing.get_instance_id()):
			removed += 1
		else:
			keep.push_back(thing)
	if removed == 0:
		return 0
	select_tool.DeselectAll()
	for thing in keep:
		select_tool.SelectThing(thing, true)
	if keep.size() > 0:
		select_tool.OnFinishSelection()
		select_tool_panel.OnSelect(get_selected_selectable_type())
	return removed


func run_select_similar() -> void:
	var use_exact = exact_check.pressed
	var use_variants = variants_check.pressed
	var use_color = color_check.pressed
	var use_tags = tag_check.pressed
	var use_shadow = shadow_check.pressed
	if not (use_exact or use_variants or use_color or use_tags or use_shadow):
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

	# Subtractive mode: the first selected asset is the only reference and
	# only the currently selected things can be removed
	var removing = remove_selection_check.pressed
	var candidates = []
	if removing:
		candidates = refs.duplicate()
		refs = [refs[0]]
	else:
		candidates = _collect_candidates()

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

	# Reference tags (union over all references)
	var ref_tags = {}
	if use_tags:
		for r in refs:
			for t in _get_thing_tags(r):
				ref_tags[t] = true
		if ref_tags.empty():
			print("Select Similar: the selected asset(s) carry no tag")
			return

	# Reference soft shadow signatures
	var ref_shadows = {}
	if use_shadow:
		for r in refs:
			ref_shadows[_get_shadow_signature(r)] = true

	var matching = []
	for thing in candidates:
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
		if use_tags:
			var shared = false
			for t in _get_thing_tags(thing):
				if ref_tags.has(t):
					shared = true
					break
			if not shared:
				continue
		if use_shadow:
			if not ref_shadows.has(_get_shadow_signature(thing)):
				continue
		matching.push_back(thing)

	# Keep the original references in the selection as well (dedup by instance)
	var final_set = {}
	for r in refs:
		final_set[r.get_instance_id()] = r
	for m in matching:
		final_set[m.get_instance_id()] = m

	if removing:
		# The reference itself is removed along with its matches
		var removed = _remove_from_selection(final_set)
		print("Select Similar: removed ", removed, " thing(s) from the selection")
		return

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


# --- Tag helpers --------------------------------------------------------

# Resource path of the texture placed on the map (key used by DD's tag DB)
func _get_thing_texture_path(thing) -> String:
	var tex = thing.get("Texture")
	if tex is Resource and tex.resource_path != "":
		return tex.resource_path
	return ""


# Tags of an asset, as an Array of tag names (empty for non-objects)
func _get_thing_tags(thing) -> Array:
	if thing.get_parent() == null or thing.get_parent().name != "Objects":
		return []
	var path = _get_thing_texture_path(thing)
	if path.empty():
		return []
	var index = _get_tags_index()
	if index.has(path):
		return index[path].keys()
	return []


# Builds (and caches per map) a path -> {tag: true} lookup.
# Source 1: DD's live tag database (Global.Tags), which already merges the
# default tags with the user's override tags. Source 2 (fallback if the
# C# collections do not marshal to GDScript): the .dungeondraft_tags files
# of the default assets and of every pack found on the map.
func _get_tags_index() -> Dictionary:
	var world_id = -1
	if Global.World != null and is_instance_valid(Global.World):
		world_id = Global.World.get_instance_id()
	if _tags_index != null and _tags_index_world_id == world_id:
		return _tags_index
	_tags_index = {}
	_tags_index_world_id = world_id

	var live = Global.get("Tags")
	if live is Dictionary:
		for tag_name in live:
			var paths = live[tag_name]
			if paths == null:
				continue
			for p in paths:
				if p is String:
					_add_tag(p, str(tag_name))

	if _tags_index.empty():
		var prefixes = {"res://": true}
		for obj in Global.World.levels[Global.World.CurrentLevelId].Objects.get_children():
			var p = _get_thing_texture_path(obj)
			if p.begins_with("res://packs/"):
				var rest = p.substr(len("res://packs/"))
				var slash = rest.find("/")
				if slash > 0:
					prefixes["res://packs/" + rest.substr(0, slash) + "/"] = true
		for prefix in prefixes:
			_collect_tags_from_file(prefix + "data/default.dungeondraft_tags", prefix)

	print("Select Similar: tag index built for ", _tags_index.size(), " asset path(s)")
	return _tags_index


func _add_tag(path: String, tag_name: String) -> void:
	if not _tags_index.has(path):
		_tags_index[path] = {}
	_tags_index[path][tag_name] = true


func _collect_tags_from_file(tags_path: String, path_prefix: String) -> void:
	var f = File.new()
	if f.open(tags_path, File.READ) != OK:
		return
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var tags = parsed.result.get("tags", {})
	if not (tags is Dictionary):
		return
	for tag_name in tags:
		var arr = tags[tag_name]
		if not (arr is Array):
			continue
		for p in arr:
			if not (p is String) or p.empty():
				continue
			# Default tags store absolute res:// paths, packs store relative ones
			var final_path = p if p.begins_with("res://") else path_prefix + p
			_add_tag(final_path, str(tag_name))


# --- Soft Shadow helper (Soft Shadow mod, ModMapData["DropShadow"]) -----

func _is_soft_shadow_mod_loaded() -> bool:
	if Engine.has_meta("dropshadow_objects_singleton"):
		return true
	var data = Global.ModMapData
	return data != null and (data.has("_dropshadow_refs") or data.has("DropShadow"))


# Comparable signature of an asset's soft shadow: "off" when the mod has no
# enabled config for it, otherwise its config serialized with stable key
# order (UI/performance-only keys are ignored).
func _get_shadow_signature(thing) -> String:
	if not thing.has_meta("node_id"):
		return "off"
	var data = Global.ModMapData
	if data == null or not data.has("DropShadow"):
		return "off"
	var store = data["DropShadow"]
	var node_id = str(thing.get_meta("node_id"))
	if not (store is Dictionary) or not store.has(node_id):
		return "off"
	var cfg = store[node_id]
	if not (cfg is Dictionary) or not cfg.get("enabled", false):
		return "off"
	var keys = cfg.keys()
	keys.sort()
	var parts = []
	for k in keys:
		if k == "enabled" or k == "settings_open" or k == "quality":
			continue
		var v = cfg[k]
		if v is Color:
			v = v.to_html()
		elif v is float:
			v = "%.4f" % v
		parts.push_back(str(k) + "=" + str(v))
	return PoolStringArray(parts).join("|")


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


# =====================================================================
# Find in Library: takes the name of the asset selected on the map,
# splits it into words (spaces, underscores, hyphens, CamelCase, digits)
# and lets the user pick which words to search. Matching assets are
# looked up in the Object Library's own word index (the same table DD's
# search bar uses, with the same similarity test and strictness) and
# shown in the Object Tool. Words that match nothing are never shown.
# =====================================================================

func _get_library_panel():
	if Global.Editor == null or not is_instance_valid(Global.Editor):
		return null
	var panel = Global.Editor.get("ObjectLibraryPanel")
	if panel == null or not is_instance_valid(panel):
		return null
	return panel


# word -> Array of thumbnail textures (ObjectLibraryPanel.searchEngine).
# Reading the C# dictionary converts it in full (thousands of entries), so
# it is read once and cached; while it is still empty (assets not loaded)
# the read is retried at most once per second.
func _get_search_engine() -> Dictionary:
	if not _se_cache.empty():
		return _se_cache
	var now = OS.get_ticks_msec()
	if now < _se_retry_at:
		return _se_cache
	_se_retry_at = now + 1000
	var panel = _get_library_panel()
	if panel == null:
		return _se_cache
	var se = panel.get("searchEngine")
	if se is Dictionary and not se.empty():
		_se_cache = se
	return _se_cache


func _get_library_strictness():
	var panel = _get_library_panel()
	if panel == null:
		return null
	var slider = panel.get("strictness")
	if slider != null and is_instance_valid(slider) and slider is Range:
		return slider
	if not _warned_no_strictness:
		_warned_no_strictness = true
		print("Find in Library: could not reach the Object Library's strictness slider")
	return null


# Our slider is a copy of DD's own (same look, range and step)
func _build_strictness_slider() -> HSlider:
	var slider = null
	var dd_slider = _get_library_strictness()
	if dd_slider != null and dd_slider is HSlider:
		# Flags 0: properties only, no script and no signal connections
		slider = dd_slider.duplicate(0)
	if slider == null or not (slider is HSlider):
		slider = HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.01
		slider.value = 0.5
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.hint_tooltip = "Same strictness as the Object Library's search (both sliders stay in sync)"
	return slider


# DD's slider -> ours (on dialog open, and whenever DD's value changes)
func _sync_strictness_from_library() -> void:
	var slider = _get_library_strictness()
	if slider == null:
		return
	if _pending_dd_strictness != null:
		# Our value wins until DD's panel has taken it for good
		if slider.value != _pending_dd_strictness:
			slider.value = _pending_dd_strictness
		return
	if lookup_strictness.min_value != slider.min_value or lookup_strictness.max_value != slider.max_value:
		lookup_strictness.min_value = slider.min_value
		lookup_strictness.max_value = slider.max_value
		lookup_strictness.step = slider.step
	if lookup_strictness.value != slider.value:
		lookup_strictness.value = slider.value


func _on_lookup_strictness_changed(value: float) -> void:
	# Ours -> DD's, right away, so both sliders always show the same value
	var slider = _get_library_strictness()
	if slider != null and slider.value != value:
		slider.value = value
	_pending_dd_strictness = value
	_word_tex_cache = {}
	# Recount once the slider stops moving (recounting is not free)
	_strict_apply_at = OS.get_ticks_msec() + 150


func _on_lookup_option_toggled(_pressed: bool) -> void:
	_apply_lookup_state()


func _on_lookup_plural_toggled(_pressed: bool) -> void:
	# Similarities were computed against the singular/plural forms
	_word_sims = {}
	_word_tex_cache = {}
	_apply_lookup_state()


func _on_lookup_word_toggled(_pressed: bool) -> void:
	_update_lookup_count()


# Called every frame while the tab is visible: cheap unless the reference
# changed or a slider change is waiting to be applied.
func _refresh_lookup_words(selected: Array) -> void:
	_layout_word_grid()
	_sync_strictness_from_library()
	if _strict_apply_at > 0 and OS.get_ticks_msec() >= _strict_apply_at:
		_strict_apply_at = 0
		_apply_lookup_state()

	var se = _get_search_engine()
	var sig = "ready" if not se.empty() else "wait"
	if selected.size() > 0 and is_instance_valid(selected[0]):
		sig += "_" + str(selected[0].get_instance_id())
	if sig == _last_lookup_sig:
		return
	_last_lookup_sig = sig

	for child in lookup_words_grid.get_children():
		lookup_words_grid.remove_child(child)
		child.queue_free()
	_lookup_word_checks = []

	if selected.size() == 0 or not is_instance_valid(selected[0]):
		lookup_hint.text = "Click an asset on the map to use it as reference."
		lookup_count_label.text = ""
		return

	var ref_name = _get_thing_name(selected[0])
	if selected.size() > 1:
		lookup_hint.text = "Reference: %s (first of %d selected)" % [ref_name, selected.size()]
	else:
		lookup_hint.text = "Reference: %s" % ref_name

	if se.empty():
		lookup_count_label.text = "Library index not ready: open the Object tool once."
		return

	var candidates = _split_name_words(ref_name)
	for c in candidates:
		var w: String = c["word"]
		var check = CheckBox.new()
		check.text = w.substr(0, 1).to_upper() + w.substr(1)
		var default_on = c["default"]
		if c.has("parts"):
			# Compound token ("WoodenTable"): only checked when none of its
			# sub-words find anything on their own
			default_on = true
			for part in c["parts"]:
				if _word_matches_anything(part):
					default_on = false
					break
		check.pressed = default_on
		check.hint_tooltip = "Include \"" + w + "\" in the library search"
		check.connect("toggled", self, "_on_lookup_word_toggled")
		lookup_words_grid.add_child(check)
		_lookup_word_checks.append([check, w])

	_apply_lookup_state()


# Fits as many words per row as the dialog width allows (Godot 3 has no
# flow container): columns sized on the widest visible word
func _layout_word_grid() -> void:
	var widest = 0.0
	var shown = 0
	for entry in _lookup_word_checks:
		var check = entry[0]
		if is_instance_valid(check) and check.visible:
			shown += 1
			widest = max(widest, check.get_combined_minimum_size().x)
	if shown == 0 or widest <= 0.0:
		return
	var sep = float(lookup_words_grid.get_constant("hseparation"))
	var avail = max(lookup_box.rect_size.x, root_box.rect_min_size.x)
	var cols = int(clamp(floor((avail + sep) / (widest + sep)), 1, shown))
	if lookup_words_grid.columns != cols:
		lookup_words_grid.columns = cols


# Shows only the words that find something at the current strictness,
# then updates the count
func _apply_lookup_state() -> void:
	var shown = 0
	for entry in _lookup_word_checks:
		var check = entry[0]
		if not is_instance_valid(check):
			continue
		check.visible = _word_matches_anything(entry[1])
		if check.visible:
			shown += 1
	if _lookup_word_checks.size() > 0 and shown == 0:
		lookup_count_label.text = "No word of this name matches the library."
		return
	_update_lookup_count()


func _checked_lookup_words() -> Array:
	var words = []
	for entry in _lookup_word_checks:
		var check = entry[0]
		if is_instance_valid(check) and check.visible and check.pressed:
			words.append(entry[1])
	return words


func _update_lookup_count() -> void:
	if _lookup_word_checks.size() == 0:
		return
	if _checked_lookup_words().size() == 0:
		lookup_count_label.text = "Check at least one word."
		return
	var n = _compute_lookup_textures().size()
	lookup_count_label.text = "%d matching asset(s) in the library" % n


# Splits an asset name into candidate words, lowercase, in name order.
# Returns Array of {word, default[, parts]}. Single characters are left
# out ("x" of "2x1"); numbers ("01") are offered but unchecked.
func _split_name_words(asset_name: String) -> Array:
	var cleaned = asset_name
	for sep in ["_", "-", ".", ",", "(", ")", "[", "]", "/", "\\"]:
		cleaned = cleaned.replace(sep, " ")
	var out = []
	var seen = {}
	for token in cleaned.split(" ", false):
		var parts = _split_camel(token)
		var lower_parts = []
		for part in parts:
			var w = part.to_lower()
			lower_parts.append(w)
			if w.length() < 2 or seen.has(w):
				continue
			seen[w] = true
			out.append({"word": w, "default": not w.is_valid_integer()})
		# DD may index a CamelCase token whole ("woodentable"): offer it too
		var whole = token.to_lower()
		if parts.size() > 1 and not seen.has(whole):
			seen[whole] = true
			out.append({"word": whole, "default": false, "parts": lower_parts})
	return out


# "WoodenTable01" -> ["Wooden", "Table", "01"], "HTMLLamp" -> ["HTML", "Lamp"]
func _split_camel(token: String) -> Array:
	var parts = []
	var current = ""
	var n = token.length()
	for i in range(n):
		var c = token[i]
		if current != "":
			var prev = token[i - 1]
			var split = false
			if _is_digit(c) != _is_digit(prev):
				split = true
			elif _is_upper(c) and _is_lower(prev):
				split = true
			elif _is_upper(c) and _is_upper(prev) and i + 1 < n and _is_lower(token[i + 1]):
				split = true
			if split:
				parts.append(current)
				current = ""
		current += c
	if current != "":
		parts.append(current)
	return parts


func _is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"


func _is_upper(c: String) -> bool:
	return c != c.to_lower() and c == c.to_upper()


func _is_lower(c: String) -> bool:
	return c != c.to_upper() and c == c.to_lower()


func _word_forms(word: String) -> Array:
	if lookup_plural_check.pressed:
		return _term_variants(word)
	return [word]


func _is_exact_strictness() -> bool:
	return lookup_strictness.value >= lookup_strictness.max_value


# Similarity of every index word to `word` (best over its forms), computed
# ONCE per word and cached: moving the slider then only re-filters these
# numbers instead of re-running thousands of comparisons.
# Returns [keys: Array, sims: PoolRealArray], only keys with similarity > 0.
func _get_word_sims(word: String) -> Array:
	if _word_sims.has(word):
		return _word_sims[word]
	var se = _get_search_engine()
	var forms = _word_forms(word)
	var keys = []
	var sims = PoolRealArray()
	for key in se:
		var best = 0.0
		for form in forms:
			var s = key.similarity(form)
			if s > best:
				best = s
		if best > 0.0:
			keys.append(key)
			sims.append(best)
	var res = [keys, sims]
	_word_sims[word] = res
	return res


# Index words matching `word` at the current strictness. Same test as DD's
# search bar: key.similarity(term) >= strictness (String.similarity is the
# Godot function DD's C# calls).
func _matching_keys(word: String) -> Array:
	var se = _get_search_engine()
	if _is_exact_strictness():
		var exact = []
		for form in _word_forms(word):
			if se.has(form):
				exact.append(form)
		return exact
	var threshold = lookup_strictness.value
	if threshold <= 0.0:
		# Similarity >= 0 is always true: DD matches every index word
		return se.keys()
	var data = _get_word_sims(word)
	var keys: Array = data[0]
	var sims: PoolRealArray = data[1]
	var out = []
	for i in range(keys.size()):
		if sims[i] >= threshold:
			out.append(keys[i])
	return out


func _word_matches_anything(word: String) -> bool:
	return _textures_for_word(word).size() > 0


# Library textures carrying a word at the current strictness, deduplicated
func _textures_for_word(word: String) -> Array:
	if _word_tex_cache.has(word):
		return _word_tex_cache[word]
	var se = _get_search_engine()
	var out = []
	var seen = {}
	for key in _matching_keys(word):
		var arr = se[key]
		if not (arr is Array):
			continue
		for tex in arr:
			if tex == null or seen.has(tex):
				continue
			seen[tex] = true
			out.append(tex)
	_word_tex_cache[word] = out
	return out


# Same plural heuristics as Theme Search: bogus forms never match the index
func _term_variants(term: String) -> Array:
	var variants = [term]
	if term.ends_with("y") and term.length() > 2:
		if "aeiou".find(term[term.length() - 2]) != -1:
			variants.append(term + "s")
		else:
			variants.append(term.substr(0, term.length() - 1) + "ies")
	else:
		variants.append(term + "s")
		variants.append(term + "es")
	if term.ends_with("ies") and term.length() > 4:
		variants.append(term.substr(0, term.length() - 3) + "y")
	elif term.ends_with("es") and term.length() > 3:
		variants.append(term.substr(0, term.length() - 2))
	if term.ends_with("s") and term.length() > 2:
		variants.append(term.substr(0, term.length() - 1))
	if term.ends_with("fe") and term.length() > 3:
		variants.append(term.substr(0, term.length() - 2) + "ves")
	elif term.ends_with("f") and term.length() > 2:
		variants.append(term.substr(0, term.length() - 1) + "ves")
	if term.ends_with("ves") and term.length() > 4:
		variants.append(term.substr(0, term.length() - 3) + "f")
		variants.append(term.substr(0, term.length() - 3) + "fe")
	return variants


# All checked words (AND, like DD's multi-word search) or any of them (OR)
func _compute_lookup_textures() -> Array:
	var words = _checked_lookup_words()
	if words.size() == 0:
		return []
	var result = _textures_for_word(words[0]).duplicate()
	if lookup_any_check.pressed:
		var seen = {}
		for tex in result:
			seen[tex] = true
		for i in range(1, words.size()):
			for tex in _textures_for_word(words[i]):
				if not seen.has(tex):
					seen[tex] = true
					result.append(tex)
		return result
	for i in range(1, words.size()):
		var keep = {}
		for tex in _textures_for_word(words[i]):
			keep[tex] = true
		var filtered = []
		for tex in result:
			if keep.has(tex):
				filtered.append(tex)
		result = filtered
		if result.empty():
			break
	return result


func run_library_lookup() -> void:
	# A slider change still waiting to be applied must be taken into account
	_word_tex_cache = {}
	_strict_apply_at = 0
	_apply_lookup_state()
	var words = _checked_lookup_words()
	if words.size() == 0:
		lookup_count_label.text = "Check at least one word."
		return
	var textures = _compute_lookup_textures()
	if textures.size() == 0:
		lookup_count_label.text = "No library asset matches these words."
		return
	# Make sure DD's slider shows the value the search was run with, and
	# keeps it after the Object tool restores its saved panel state
	var slider = _get_library_strictness()
	if slider != null and slider.value != lookup_strictness.value:
		slider.value = lookup_strictness.value
	_pending_dd_strictness = lookup_strictness.value
	# Switching tool hides the Select Tool panel, which closes this dialog
	var toolset = Global.Editor.get("Toolset")
	if toolset != null and is_instance_valid(toolset) and toolset.has_method("Quickswitch"):
		toolset.Quickswitch("ObjectTool")
	# One frame of slack so the library panel is shown before we fill it
	call_deferred("_show_in_library", textures, words)


func _show_in_library(textures: Array, words: Array) -> void:
	var panel = _get_library_panel()
	if panel == null:
		return
	# "All" tab, so the panel state matches what we display
	var all_btn = panel.get("allButton")
	if all_btn != null and is_instance_valid(all_btn) and not all_btn.pressed:
		all_btn.pressed = true
		if all_btn.has_signal("toggled"):
			all_btn.emit_signal("toggled", true)
	panel.call("ShowObjectsArray", textures)
	# Cosmetic: reflect the words in the search bar without submitting it
	# (submitting would run DD's own search and replace our result)
	var le = _find_search_line_edit(panel)
	if le != null:
		le.text = PoolStringArray(words).join(" ")
	print("Find in Library: showing ", textures.size(), " asset(s) for '", PoolStringArray(words).join(" "), "'")


# Entering the Object (or Scatter) tool calls ObjectLibraryPanel.Load(),
# which sets the slider back to the value saved when that tool was left,
# one frame later (after "await Global.FrameSignal"). So when the panel
# becomes visible with a value pending, keep re-applying it for a few
# frames, until DD's restore has run; the tool then saves our value itself.
func _maintain_library_strictness() -> void:
	var panel = _get_library_panel()
	var vis = panel != null and panel.is_visible_in_tree()
	if vis and not _library_was_visible and _pending_dd_strictness != null:
		_pending_dd_frames = 10
	_library_was_visible = vis
	if _pending_dd_frames <= 0:
		return
	_pending_dd_frames -= 1
	var slider = _get_library_strictness()
	if slider != null and slider.value != _pending_dd_strictness:
		slider.value = _pending_dd_strictness
	if _pending_dd_frames == 0:
		_pending_dd_strictness = null


func _find_search_line_edit(root):
	if root == null or not is_instance_valid(root):
		return null
	if root is LineEdit and root.is_visible_in_tree():
		return root
	for child in root.get_children():
		var found = _find_search_line_edit(child)
		if found != null:
			return found
	return null


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
