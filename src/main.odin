package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// 0. Core Data Structures

Editor :: struct {
	lines:        [dynamic][dynamic]u8, // Dynamic array of lines, each line is dynamic array of UTF-8 bytes
	cursor:       Cursor,
	selection:    Selection,
	scroll:       Scroll,
	config:       Config,
	undo_manager: UndoManager,
	search:       SearchState,
	file_path:    string,
	dirty:        bool, // Has unsaved changes?

	// Rendering state
	window:       ^sdl.Window,
	renderer:     ^sdl.Renderer,
	font:         ^ttf.Font,
	text_engine:  ^ttf.TextEngine,
	last_tick:    u64, // Time of last frame
	window_focus: bool,
}

Cursor :: struct {
	row:           int,
	col:           int,
	preferred_col: int, // Remembers horizontal position when moving vertically
}

Selection :: struct {
	active: bool,
	anchor: Cursor, // Where selection started (shift+click or shift+arrow start)
}

Scroll :: struct {
	x:        f32,
	y:        f32,
	target_x: f32, // For smooth scrolling
	target_y: f32,
}

Config :: struct {
	tab_width:   int,
	font_size:   f32,
	line_height: int,
	char_width:  f32,
}

ActionType :: enum {
	Insert,
	Delete,
}

Action :: struct {
	type:      ActionType,
	start:     Cursor,
	text:      string,
	timestamp: u64,
}

UndoManager :: struct {
	undo_stack: [dynamic]Action,
	redo_stack: [dynamic]Action,
	is_undoing: bool,
}

SearchState :: struct {
	active:        bool,
	mode:          SearchMode,
	query:         strings.Builder,
	replace_query: strings.Builder,
	results:       [dynamic]Cursor,
	current_idx:   int,
	focus:         SearchFocus,
}

SearchMode :: enum {
	Find,
	Replace,
}

SearchFocus :: enum {
	Query,
	ReplaceQuery,
}

// Global constants
WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 600
FONT_PATH :: "fonts/Fira_Mono/FiraMono-Regular.ttf"
TEXT_MARGIN :: 10.0
TARGET_FPS :: 120

main :: proc() {
	context.logger = log.create_console_logger()
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				for _, entry in track.allocation_map {
					log.warnf("%v leaked %v bytes", entry.location, entry.size)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}
	// 1. Initialize SDL
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init failed")
		return
	}
	defer sdl.Quit()

	if !ttf.Init() {
		fmt.eprintln("TTF_Init failed")
		return
	}
	defer ttf.Quit()

	editor := Editor{}
	defer free_editor(&editor)
	editor.config = Config {
		tab_width   = 4,
		font_size   = 16,
		line_height = 20, // Will be updated
		char_width  = 10.0, // Will be updated
	}

	strings.builder_init(&editor.search.query)
	strings.builder_init(&editor.search.replace_query)
	defer strings.builder_destroy(&editor.search.query)
	defer strings.builder_destroy(&editor.search.replace_query)
	defer delete(editor.search.results)

	// Initialize Window and Renderer
	window_flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}
	w_name := cstring("monetina-text-editor")
	editor.window = sdl.CreateWindow(w_name, WINDOW_WIDTH, WINDOW_HEIGHT, window_flags)
	if editor.window == nil {
		fmt.eprintln("CreateWindow failed")
		return
	}
	defer sdl.DestroyWindow(editor.window)

	editor.renderer = sdl.CreateRenderer(editor.window, nil)
	if editor.renderer == nil {
		fmt.eprintln("CreateRenderer failed")
		return
	}
	defer sdl.DestroyRenderer(editor.renderer)

	sdl.SetRenderVSync(editor.renderer, 0)

	editor.text_engine = ttf.CreateRendererTextEngine(editor.renderer)
	if editor.text_engine == nil {
		fmt.eprintln("CreateRendererTextEngine failed")
		return
	}
	defer ttf.DestroyRendererTextEngine(editor.text_engine)
	// Load Font
	editor.font = ttf.OpenFont(FONT_PATH, editor.config.font_size)
	if editor.font == nil {
		fmt.eprintf("Failed to load font: %s\n", FONT_PATH)
		return
	}
	defer ttf.CloseFont(editor.font)

	editor.config.line_height = int(ttf.GetFontHeight(editor.font))

	// Measure 'A' for char_width
	text_a := ttf.CreateText(editor.text_engine, editor.font, cstring("A"), 1)
	if text_a != nil {
		editor.config.char_width = 10.0 // Fallback
		ttf.DestroyText(text_a)
	}

	// Initial content
	if len(os.args) > 1 {
		load_file(&editor, os.args[1])
	} else {
		append(&editor.lines, make([dynamic]u8))
	}

	if !sdl.StartTextInput(editor.window) {
		fmt.eprintln("StartTextInput failed")
	}

	fmt.println("Editor started")

	editor.last_tick = sdl.GetTicks()

	// Main Loop
	running := true
	for running {
		frame_start := sdl.GetTicks()

		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == .QUIT {
				running = false
			}
			handle_event(&editor, &event, &running)
		}

		update(&editor)
		render(&editor)

		free_all(context.temp_allocator)

		frame_time := sdl.GetTicks() - frame_start
		if frame_time < 1000 / TARGET_FPS {
			sdl.Delay(u32(1000 / TARGET_FPS - frame_time))
		}
	}
}

get_gutter_width :: proc(editor: ^Editor) -> f32 {
	lines_count := len(editor.lines)
	if lines_count < 1 {lines_count = 1}
	digits := int(math.log10(f32(lines_count))) + 1
	if digits < 4 {digits = 4}
	return f32(digits) * editor.config.char_width + 20.0
}

get_text_start_x :: proc(editor: ^Editor) -> f32 {
	return get_gutter_width(editor) + TEXT_MARGIN
}

draw_selection_rects :: proc(editor: ^Editor, view_start, view_end: int) {
	// Selection range
	s := editor.selection.anchor
	e := editor.cursor

	// Normalize
	if s.row > e.row || (s.row == e.row && s.col > e.col) {
		temp := s
		s = e
		e = temp
	}

	sdl.SetRenderDrawColor(editor.renderer, 60, 60, 80, 255)

	// Iterate lines in intersection
	start_r := max(s.row, view_start)
	end_r := min(e.row, view_end - 1)

	for r := start_r; r <= end_r; r += 1 {
		line_len := get_char_col(editor.lines[r][:], len(editor.lines[r]))

		c_start := 0
		if r == s.row {c_start = s.col}

		c_end := line_len
		if r == e.row {c_end = e.col}

		// Visualize newline selection if not last line of selection
		extra_width := f32(0.0)
		if r != e.row {
			extra_width = editor.config.char_width
		}

		x_start := measure_line_width(editor.lines[r], c_start, editor.config)
		x_end := measure_line_width(editor.lines[r], c_end, editor.config)

		offset_x := get_text_start_x(editor)
		x := offset_x - editor.scroll.x + x_start
		width := (x_end - x_start) + extra_width

		y := f32(r) * f32(editor.config.line_height) - editor.scroll.y

		rect := sdl.FRect{x, y, width, f32(editor.config.line_height)}
		sdl.RenderFillRect(editor.renderer, &rect)
	}
	sdl.SetRenderDrawColor(editor.renderer, 200, 200, 200, 255)
}

save_file_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	context = runtime.default_context()
	if filelist == nil {return}

	// Create user event to handle saving on main thread
	path_str := string(filelist[0])
	if len(path_str) == 0 {return}

	// Clone string to heap to pass safely
	// We'll use cstring for simplicity with delete/free
	new_cstr := strings.clone_to_cstring(path_str, context.allocator)

	event: sdl.Event
	event.type = sdl.EventType.USER
	event.user.code = 0
	event.user.data1 = rawptr(new_cstr)
	_ = sdl.PushEvent(&event)
}

open_file_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	context = runtime.default_context()
	if filelist == nil {return}

	path_str := string(filelist[0])
	if len(path_str) == 0 {return}

	new_cstr := strings.clone_to_cstring(path_str, context.allocator)

	event: sdl.Event
	event.type = sdl.EventType.USER
	event.user.code = 1 // 1 for open
	event.user.data1 = rawptr(new_cstr)
	_ = sdl.PushEvent(&event)
}

handle_event :: proc(editor: ^Editor, event: ^sdl.Event, running: ^bool) {
	if editor.search.active {
		if event.type == .TEXT_INPUT || event.type == .KEY_DOWN {
			handle_search_input(editor, event)
			return
		}
	}

	if event.type == .TEXT_INPUT {
		// Handle text input
		text_str := string(event.text.text)
		insert_text(editor, text_str)
	} else if event.type == .KEY_DOWN {
		if event.key.key == sdl.K_ESCAPE {
			// Deselect instead of quit
			editor.selection.active = false
		}
		// Handle other keys
		handle_key(editor, event.key)
	} else if event.type == .USER {
		// Handle file operations
		// Code 0: Save, Code 1: Open
		if event.user.data1 != nil {
			c_path := cstring(event.user.data1)
			path := string(c_path)

			if event.user.code == 0 {
				save_file(editor, path)
			} else if event.user.code == 1 {
				load_file(editor, path)
			}

			// mem.free(rawptr(c_path), runtime.default_allocator())
		}
	} else if event.type == .MOUSE_BUTTON_DOWN {
		if event.button.button == sdl.BUTTON_LEFT {
			click_row, click_col := screen_to_grid(editor, event.button.x, event.button.y)

			if click_row != editor.cursor.row {
				leave_line(editor, editor.cursor.row)
			}

			editor.cursor.row = click_row
			editor.cursor.col = click_col
			editor.cursor.preferred_col = click_col

			// Start selection
			editor.selection.active = true
			editor.selection.anchor = editor.cursor
		}
	} else if event.type == .MOUSE_MOTION {
		if event.motion.state == sdl.BUTTON_LMASK {
			// Dragging
			drag_row, drag_col := screen_to_grid(editor, event.motion.x, event.motion.y)
			editor.cursor.row = drag_row
			editor.cursor.col = drag_col
			editor.cursor.preferred_col = drag_col

			// Update selection (anchor remains same)
		}
	} else if event.type == .MOUSE_WHEEL {
		scroll_speed := f32(30.0)
		mods := sdl.GetModState()
		if (mods & sdl.KMOD_SHIFT) != nil {
			// Horizontal scroll with Shift+Wheel
			editor.scroll.target_x -= event.wheel.y * scroll_speed
			editor.scroll.target_x += event.wheel.x * scroll_speed
		} else {
			editor.scroll.target_y -= event.wheel.y * scroll_speed
			editor.scroll.target_x += event.wheel.x * scroll_speed
		}
	} else if event.type == .WINDOW_PIXEL_SIZE_CHANGED || event.type == .WINDOW_RESIZED {
		// Handle resize if needed
	}
}

next_tab_stop :: proc(x, tab_width: f32) -> f32 {
	return f32(int(x / tab_width) + 1) * tab_width
}

screen_to_grid :: proc(editor: ^Editor, x, y: f32) -> (int, int) {
	rel_y := y + editor.scroll.y
	row := int(rel_y / f32(editor.config.line_height))
	if row < 0 {row = 0}
	if row >= len(editor.lines) {row = len(editor.lines) - 1}

	rel_x := x + editor.scroll.x - get_text_start_x(editor)

	line := editor.lines[row]
	current_x := f32(0.0)
	tab_width_px := f32(editor.config.tab_width) * editor.config.char_width

	offset := 0
	col := 0
	for offset < len(line) {
		r, w := utf8.decode_rune(line[offset:])
		char_w := editor.config.char_width
		if r == '	' {
			new_x := next_tab_stop(current_x, tab_width_px)
			char_w = new_x - current_x
		}

		if rel_x < current_x + char_w / 2.0 {
			return row, col
		}
		current_x += char_w
		offset += w
		col += 1
	}

	return row, col
}

measure_line_width :: proc(line: [dynamic]u8, count: int, config: Config) -> f32 {
	width := f32(0.0)
	tab_width_px := f32(config.tab_width) * config.char_width

	offset := 0
	chars := 0
	for offset < len(line) && chars < count {
		r, w := utf8.decode_rune(line[offset:])
		offset += w
		chars += 1

		if r == '	' {
			width = next_tab_stop(width, tab_width_px)
		} else {
			width += config.char_width
		}
	}
	return width
}

handle_key :: proc(editor: ^Editor, key: sdl.KeyboardEvent) {
	// Use global mod state
	mods := sdl.GetModState()
	is_ctrl := (mods & sdl.KMOD_CTRL) != nil
	is_alt := (mods & sdl.KMOD_ALT) != nil

	// Check if key is pressed
	if key.down {
		old_cursor := editor.cursor

		// Use global mod state to be sure
		is_shift := (mods & sdl.KMOD_SHIFT) != nil

		switch key.key {
		case sdl.K_UP:
			if is_alt || is_ctrl {
				editor.scroll.target_y -= f32(editor.config.line_height)
			} else {
				move_cursor(editor, -1, 0)
				update_selection(editor, is_shift, old_cursor)
			}
		case sdl.K_DOWN:
			if is_alt || is_ctrl {
				editor.scroll.target_y += f32(editor.config.line_height)
			} else {
				move_cursor(editor, 1, 0)
				update_selection(editor, is_shift, old_cursor)
			}
		case sdl.K_LEFT:
			move_cursor(editor, 0, -1)
			update_selection(editor, is_shift, old_cursor)
		case sdl.K_RIGHT:
			move_cursor(editor, 0, 1)
			update_selection(editor, is_shift, old_cursor)
		case sdl.K_BACKSPACE:
			if editor.selection.active {
				delete_selection(editor)
			} else {
				delete_char_backwards(editor)
			}
		case sdl.K_TAB:
			insert_text(editor, "\t")
		case sdl.K_RETURN:
			// Enter
			insert_newline(editor)
		case sdl.K_C:
			if is_ctrl {
				copy_selection(editor)
			}
		case sdl.K_V:
			if is_ctrl {
				paste_from_clipboard(editor)
			}
		case sdl.K_O:
			if is_ctrl {
				sdl.ShowOpenFileDialog(open_file_callback, nil, editor.window, nil, 0, nil, false)
			}
		case sdl.K_S:
			if is_ctrl {
				if is_shift || len(editor.file_path) == 0 {
					// Save As: Open dialog
					// Pass nil for userdata as we use PushEvent
					sdl.ShowSaveFileDialog(save_file_callback, nil, editor.window, nil, 0, nil)
				} else {
					save_file(editor, editor.file_path)
				}
			}
		case sdl.K_Z:
			if is_ctrl {
				if is_shift {
					redo(editor)
				} else {
					undo(editor)
				}
			}
		case sdl.K_Y:
			if is_ctrl {
				redo(editor)
			}
		case sdl.K_F:
			if is_ctrl {
				editor.search.active = true
				editor.search.mode = .Find
				editor.search.focus = .Query
				perform_search(editor)
			}
		case sdl.K_H:
			if is_ctrl {
				editor.search.active = true
				editor.search.mode = .Replace
				editor.search.focus = .Query
				perform_search(editor)
			}
		case:
		// Handle other keys
		}
	}
}

handle_search_input :: proc(editor: ^Editor, event: ^sdl.Event) {
	if event.type == .KEY_DOWN {
		key := event.key.key
		switch key {
		case sdl.K_ESCAPE:
			editor.search.active = false
			editor.window_focus = true // Restore focus
		case sdl.K_BACKSPACE:
			builder := &editor.search.query
			if editor.search.focus == .ReplaceQuery {
				builder = &editor.search.replace_query
			}
			if strings.builder_len(builder^) > 0 {
				// Remove last rune
				str := strings.to_string(builder^)
				_, w := utf8.decode_last_rune(str)
				// Rebuild without last char
				// Efficient enough for search query
				new_str := str[:len(str) - w]
				clone := strings.clone(new_str, context.temp_allocator)
				strings.builder_reset(builder)
				strings.write_string(builder, clone)
			}
			if editor.search.focus == .Query {
				perform_search(editor)
			}
		case sdl.K_TAB:
			if editor.search.mode == .Replace {
				if editor.search.focus == .Query {
					editor.search.focus = .ReplaceQuery
				} else {
					editor.search.focus = .Query
				}
			}
		case sdl.K_RETURN:
			if editor.search.mode == .Replace && editor.search.focus == .ReplaceQuery {
				perform_replace(editor)
			} else {
				jump_to_next_result(editor)
			}
		case sdl.K_F3:
			mods := sdl.GetModState()
			if (mods & sdl.KMOD_SHIFT) != nil {
				// Prev
				jump_to_prev_result(editor)
			} else {
				jump_to_next_result(editor)
			}
		}
	} else if event.type == .TEXT_INPUT {
		text := string(event.text.text)
		if editor.search.focus == .Query {
			strings.write_string(&editor.search.query, text)
			perform_search(editor)
		} else {
			strings.write_string(&editor.search.replace_query, text)
		}
	}
}

perform_replace :: proc(editor: ^Editor) {
	if len(editor.search.results) == 0 {return}

	// Check if cursor matches a result
	current_match_idx := -1
	for i := 0; i < len(editor.search.results); i += 1 {
		res := editor.search.results[i]
		if res.row == editor.cursor.row && res.col == editor.cursor.col {
			current_match_idx = i
			break
		}
	}

	if current_match_idx != -1 {
		// Calculate end cursor for deletion
		query := strings.to_string(editor.search.query)
		start := editor.search.results[current_match_idx]

		// End cursor calculation (utf8 aware)
		lines := strings.split(query, "\n", context.temp_allocator)
		end_row := start.row + len(lines) - 1
		end_col := 0
		if len(lines) == 1 {
			end_col = start.col + utf8.rune_count(query)
		} else {
			end_col = utf8.rune_count(lines[len(lines) - 1])
		}

		end := Cursor{end_row, end_col, 0}

		// Delete match
		delete_range(editor, start, end)

		// Insert replacement
		replace_text := strings.to_string(editor.search.replace_query)
		insert_text(editor, replace_text)

		// Re-run search to update indices
		perform_search(editor)

		// Move to next result
		jump_to_next_result(editor)
	} else {
		// Just move to next if not on match
		jump_to_next_result(editor)
	}
}

perform_search :: proc(editor: ^Editor) {
	clear(&editor.search.results)
	query := strings.to_string(editor.search.query)
	if len(query) == 0 {return}

	for i := 0; i < len(editor.lines); i += 1 {
		line := editor.lines[i]
		// Optimization: Check if line contains first rune of query?
		// For now, simple conversion
		line_str := string(line[:])

		start_idx := 0
		for {
			idx := strings.index(line_str[start_idx:], query)
			if idx == -1 {break}

			real_idx := start_idx + idx
			// Convert byte index to rune index (column)
			col := utf8.rune_count(line_str[:real_idx])

			append(&editor.search.results, Cursor{i, col, 0})
			start_idx = real_idx + len(query) // Move past match
			if start_idx >= len(line_str) {break}
		}
	}
}

jump_to_next_result :: proc(editor: ^Editor) {
	if len(editor.search.results) == 0 {return}

	// Find next match after current cursor
	found := false
	for i := 0; i < len(editor.search.results); i += 1 {
		res := editor.search.results[i]
		if res.row > editor.cursor.row ||
		   (res.row == editor.cursor.row && res.col > editor.cursor.col) {
			editor.search.current_idx = i
			found = true
			break
		}
	}

	if !found {
		editor.search.current_idx = 0 // Wrap
	}

	target := editor.search.results[editor.search.current_idx]
	editor.cursor.row = target.row
	editor.cursor.col = target.col
	editor.cursor.preferred_col = target.col
	ensure_cursor_visible(editor)
}

jump_to_prev_result :: proc(editor: ^Editor) {
	if len(editor.search.results) == 0 {return}

	// Find prev match before current cursor
	target_idx := len(editor.search.results) - 1
	for i := len(editor.search.results) - 1; i >= 0; i -= 1 {
		res := editor.search.results[i]
		if res.row < editor.cursor.row ||
		   (res.row == editor.cursor.row && res.col < editor.cursor.col) {
			target_idx = i
			break
		}
	}

	editor.search.current_idx = target_idx
	target := editor.search.results[target_idx]
	editor.cursor.row = target.row
	editor.cursor.col = target.col
	editor.cursor.preferred_col = target.col
	ensure_cursor_visible(editor)
}

update_selection :: proc(editor: ^Editor, is_shift: bool, old_cursor: Cursor) {
	if is_shift {
		if !editor.selection.active {
			editor.selection.active = true
			editor.selection.anchor = old_cursor
		}
	} else {
		editor.selection.active = false
	}
}


get_byte_offset :: proc(line: []u8, col: int) -> int {
	offset := 0
	count := 0
	for offset < len(line) && count < col {
		_, w := utf8.decode_rune(line[offset:])
		offset += w
		count += 1
	}
	return offset
}

get_char_col :: proc(line: []u8, offset: int) -> int {
	if offset > len(line) {return utf8.rune_count(line)}
	return utf8.rune_count(line[:offset])
}


load_file :: proc(editor: ^Editor, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != os.General_Error.None {
		fmt.eprintln("Failed to read file:", path, "Error:", err)
		return
	}
	defer delete(data)

	// Clear existing lines
	for line in editor.lines {
		delete(line)
	}
	clear(&editor.lines)

	// Scan lines first to allocate exact capacity
	// This optimization saves memory by avoiding capacity growth overhead
	offset := 0
	line_start := 0
	for offset < len(data) {
		b := data[offset]
		offset += 1

		if b == '\n' {
			// Found line end
			count := offset - line_start - 1 // Exclude

			if count > 0 && data[offset - 2] == 13 {
				count -= 1 // Exclude
			}
			if count < 0 {count = 0}

			line := make([dynamic]u8, count, count)
			// Copy data
			copy(line[:], data[line_start:line_start + count])
			append(&editor.lines, line)

			line_start = offset
		}
	}

	// Last line
	if line_start < len(data) {
		count := len(data) - line_start
		line := make([dynamic]u8, count, count)
		copy(line[:], data[line_start:])
		append(&editor.lines, line)
	} else if len(data) > 0 && data[len(data) - 1] == '\n' {
		// File ended with newline, add empty line
		append(&editor.lines, make([dynamic]u8))
	} else if len(data) == 0 {
		append(&editor.lines, make([dynamic]u8))
	}

	editor.file_path = strings.clone(path)
	editor.cursor = Cursor{0, 0, 0}
	editor.selection.active = false

	// Clear undo history
	clear_undo_history(editor)

	fmt.println("Loaded file:", path)
}

save_file :: proc(editor: ^Editor, path: string) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	for i := 0; i < len(editor.lines); i += 1 {
		line := editor.lines[i]
		str := string(line[:])
		strings.write_string(&builder, str)
		if i < len(editor.lines) - 1 {
			strings.write_byte(&builder, '\n') // Unix style
		}
	}

	data := strings.to_string(builder)
	err := os.write_entire_file(path, transmute([]u8)data)
	if err == os.General_Error.None {
		fmt.println("Saved file:", path)
		if editor.file_path != path {
			delete(editor.file_path)
			editor.file_path = strings.clone(path)
		}
		editor.dirty = false
	} else {
		fmt.eprintln("Failed to save file:", path, "Error:", err)
	}
}

copy_selection :: proc(editor: ^Editor) {
	s := editor.selection.anchor
	e := editor.cursor

	if s.row > e.row || (s.row == e.row && s.col > e.col) {
		temp := s
		s = e
		e = temp
	}

	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)

	for r := s.row; r <= e.row; r += 1 {
		line := editor.lines[r]
		start_offset := 0
		if r == s.row {start_offset = get_byte_offset(line[:], s.col)}

		end_offset := len(line)
		if r == e.row {end_offset = get_byte_offset(line[:], e.col)}

		if end_offset > len(line) {end_offset = len(line)}
		if start_offset > len(line) {start_offset = len(line)}

		if start_offset < end_offset {
			slice := line[start_offset:end_offset]
			strings.write_string(&builder, string(slice))
		}

		if r != e.row {
			strings.write_byte(&builder, '\n')
		}
	}

	text := strings.to_string(builder)
	if len(text) > 0 {
		c_text := strings.clone_to_cstring(text, context.temp_allocator)
		sdl.SetClipboardText(c_text)
	}
}

paste_from_clipboard :: proc(editor: ^Editor) {
	if !sdl.HasClipboardText() {return}

	text := sdl.GetClipboardText()
	if text != nil {
		// text is cstring or [^]u8
		insert_text(editor, string(cstring(text)))
	}
}

insert_text :: proc(editor: ^Editor, text: string) {
	if len(text) == 0 {return}
	editor.dirty = true

	// Handle multiline insertion
	if editor.selection.active {
		delete_selection(editor)
	}

	if !editor.undo_manager.is_undoing {
		record_action(editor, .Insert, editor.cursor, text)
	}

	lines_str := strings.split(text, "\n", context.temp_allocator)

	for i := 0; i < len(lines_str); i += 1 {
		line_str := lines_str[i]
		// Strip
		content := line_str
		if len(content) > 0 && content[len(content) - 1] == '\n' {
			content = content[:len(content) - 1]
		}

		if len(content) > 0 {
			line := &editor.lines[editor.cursor.row]
			offset := get_byte_offset(line[:], editor.cursor.col)
			inject_at(line, offset, ..transmute([]u8)content)
			editor.cursor.col += utf8.rune_count(content)
		}

		if i < len(lines_str) - 1 {
			insert_newline_internal(editor)
		}
	}
	editor.cursor.preferred_col = editor.cursor.col
	ensure_cursor_visible(editor)
}

insert_newline :: proc(editor: ^Editor) {
	if !editor.undo_manager.is_undoing {
		record_action(editor, .Insert, editor.cursor, "\n")
	}
	insert_newline_internal(editor)
}

insert_newline_internal :: proc(editor: ^Editor) {
	editor.dirty = true
	if editor.selection.active {
		delete_selection(editor)
	}

	current_line := &editor.lines[editor.cursor.row]
	offset := get_byte_offset(current_line[:], editor.cursor.col)

	// Split current line at cursor.col
	// Right part moves to new line
	right_part := make([dynamic]u8)
	if offset < len(current_line) {
		append(&right_part, ..current_line[offset:])
		resize(current_line, offset)
	}

	// Insert new line after current row
	inject_at(&editor.lines, editor.cursor.row + 1, right_part)

	leave_line(editor, editor.cursor.row)

	editor.cursor.row += 1
	editor.cursor.col = 0
	editor.cursor.preferred_col = 0
	ensure_cursor_visible(editor)
}

delete_char_backwards :: proc(editor: ^Editor) {
	if !editor.undo_manager.is_undoing {
		// Record deletion
		if editor.cursor.col > 0 {
			line := editor.lines[editor.cursor.row]
			offset := get_byte_offset(line[:], editor.cursor.col)
			if offset > 0 {
				str := string(line[:offset])
				_, w := utf8.decode_last_rune_in_string(str)
				char_bytes := line[offset - w:offset]
				text := string(char_bytes)
				record_action(
					editor,
					.Delete,
					Cursor{editor.cursor.row, editor.cursor.col - 1, 0},
					text,
				)
			}
		} else if editor.cursor.row > 0 {
			record_action(
				editor,
				.Delete,
				Cursor {
					editor.cursor.row - 1,
					get_char_col(
						editor.lines[editor.cursor.row - 1][:],
						len(editor.lines[editor.cursor.row - 1]),
					),
					0,
				},
				"\n",
			)
		}
	}

	if editor.cursor.col > 0 {
		editor.dirty = true
		// Remove char at col-1
		line := &editor.lines[editor.cursor.row]
		offset := get_byte_offset(line[:], editor.cursor.col)
		if offset > 0 {
			str := string(line[:offset])
			_, w := utf8.decode_last_rune_in_string(str)
			remove_range(line, offset - w, offset)
			editor.cursor.col -= 1
			editor.cursor.preferred_col = editor.cursor.col
		}
	} else if editor.cursor.row > 0 {
		editor.dirty = true
		// Merge with previous line
		curr_line := editor.lines[editor.cursor.row]
		prev_line := &editor.lines[editor.cursor.row - 1]

		old_len_chars := get_char_col(prev_line[:], len(prev_line))
		append(prev_line, ..curr_line[:])

		// Remove current line
		ordered_remove(&editor.lines, editor.cursor.row)
		delete(curr_line) // Free memory of removed line

		editor.cursor.row -= 1
		editor.cursor.col = old_len_chars
		editor.cursor.preferred_col = old_len_chars
	}
	ensure_cursor_visible(editor)
}

delete_selection :: proc(editor: ^Editor) {
	if !editor.selection.active {return}

	editor.dirty = true
	s := editor.selection.anchor
	e := editor.cursor

	if s.row > e.row || (s.row == e.row && s.col > e.col) {
		temp := s
		s = e
		e = temp
	}

	if !editor.undo_manager.is_undoing {
		text := get_text_in_range(editor, s, e)
		record_action(editor, .Delete, s, text)
		delete(text) // record_action clones it
	}

	delete_range(editor, s, e)

	editor.cursor = s
	editor.cursor.preferred_col = s.col
	editor.selection.active = false
	ensure_cursor_visible(editor)
}

// Helpers for undo/redo

delete_range :: proc(editor: ^Editor, s, e: Cursor) {
	if s.row == e.row {
		line := &editor.lines[s.row]
		start_offset := get_byte_offset(line[:], s.col)
		end_offset := get_byte_offset(line[:], e.col)

		if start_offset < len(line) {
			real_end := min(end_offset, len(line))
			if start_offset < real_end {
				remove_range(line, start_offset, real_end)
			}
		}
	} else {
		// Multi-line delete
		start_line := &editor.lines[s.row]
		start_offset := get_byte_offset(start_line[:], s.col)
		resize(start_line, start_offset)

		end_line := editor.lines[e.row]
		end_offset := get_byte_offset(end_line[:], e.col)
		if end_offset < len(end_line) {
			append(start_line, ..end_line[end_offset:])
		}

		for i := e.row; i > s.row; i -= 1 {
			delete(editor.lines[i])
			ordered_remove(&editor.lines, i)
		}
	}
}

get_text_in_range :: proc(editor: ^Editor, s, e: Cursor) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.allocator)

	for r := s.row; r <= e.row; r += 1 {
		line := editor.lines[r]
		start_offset := 0
		if r == s.row {start_offset = get_byte_offset(line[:], s.col)}

		end_offset := len(line)
		if r == e.row {end_offset = get_byte_offset(line[:], e.col)}

		if end_offset > len(line) {end_offset = len(line)}
		if start_offset > len(line) {start_offset = len(line)}

		if start_offset < end_offset {
			slice := line[start_offset:end_offset]
			strings.write_string(&builder, string(slice))
		}

		if r != e.row {
			strings.write_byte(&builder, '\n')
		}
	}
	return strings.to_string(builder)
}

record_action :: proc(editor: ^Editor, type: ActionType, start: Cursor, text: string) {
	// Clear redo stack
	for action in editor.undo_manager.redo_stack {
		delete(action.text)
	}
	clear(&editor.undo_manager.redo_stack)

	// Grouping logic (simplified: merge sequential inserts)
	/*
	if type == .Insert && len(editor.undo_manager.undo_stack) > 0 {
		last_action := &editor.undo_manager.undo_stack[len(editor.undo_manager.undo_stack) - 1]
		// Check if last action was insert and happened recently (e.g. < 500ms)
		// And check if positions are contiguous
		// For now, simple grouping by type and adjacency
		// Actually, let's keep it simple: no grouping first to ensure correctness
	}
	*/

	action := Action {
		type      = type,
		start     = start,
		text      = strings.clone(text),
		timestamp = sdl.GetTicks(),
	}
	append(&editor.undo_manager.undo_stack, action)
}

undo :: proc(editor: ^Editor) {
	if len(editor.undo_manager.undo_stack) == 0 {return}

	action := pop(&editor.undo_manager.undo_stack)
	editor.undo_manager.is_undoing = true
	defer editor.undo_manager.is_undoing = false

	editor.cursor = action.start
	// Reverse action
	switch action.type {
	case .Insert:
		// Undo Insert -> Delete
		// Calculate end position based on text
		lines := strings.split(action.text, "\n", context.temp_allocator)
		end_row := action.start.row + len(lines) - 1
		end_col := 0
		if len(lines) == 1 {
			end_col = action.start.col + len(lines[0]) // utf8 length? No, bytes. Wait.
			// cursor is in runes. len(string) is bytes.
			// We need rune count.
			end_col = action.start.col + utf8.rune_count(action.text)
		} else {
			end_col = utf8.rune_count(lines[len(lines) - 1])
		}

		delete_range(editor, action.start, Cursor{end_row, end_col, 0})

	case .Delete:
		// Undo Delete -> Insert
		insert_text(editor, action.text)
	}

	append(&editor.undo_manager.redo_stack, action)
}

redo :: proc(editor: ^Editor) {
	if len(editor.undo_manager.redo_stack) == 0 {return}

	action := pop(&editor.undo_manager.redo_stack)
	editor.undo_manager.is_undoing = true
	defer editor.undo_manager.is_undoing = false

	editor.cursor = action.start
	// Re-do action
	switch action.type {
	case .Insert:
		insert_text(editor, action.text)
	case .Delete:
		// Delete text again
		// Need end cursor
		lines := strings.split(action.text, "\n", context.temp_allocator)
		end_row := action.start.row + len(lines) - 1
		end_col := 0
		if len(lines) == 1 {
			end_col = action.start.col + utf8.rune_count(action.text)
		} else {
			end_col = utf8.rune_count(lines[len(lines) - 1])
		}
		delete_range(editor, action.start, Cursor{end_row, end_col, 0})
	}

	append(&editor.undo_manager.undo_stack, action)
}

move_cursor :: proc(editor: ^Editor, d_row, d_col: int) {
	// Vertical movement
	if d_row != 0 {
		old_row := editor.cursor.row
		editor.cursor.row += d_row
		if editor.cursor.row < 0 {editor.cursor.row = 0}
		if editor.cursor.row >= len(editor.lines) {editor.cursor.row = len(editor.lines) - 1}

		if editor.cursor.row != old_row {
			leave_line(editor, old_row)
		}

		// Snap to preferred column
		line_len := len(editor.lines[editor.cursor.row])
		editor.cursor.col = min(editor.cursor.preferred_col, line_len)
	}

	// Horizontal movement
	if d_col != 0 {
		editor.cursor.col += d_col
		line_len := len(editor.lines[editor.cursor.row])

		if editor.cursor.col < 0 {
			if editor.cursor.row > 0 {
				leave_line(editor, editor.cursor.row)
				editor.cursor.row -= 1
				editor.cursor.col = len(editor.lines[editor.cursor.row])
			} else {
				editor.cursor.col = 0
			}
		} else if editor.cursor.col > line_len {
			if editor.cursor.row < len(editor.lines) - 1 {
				leave_line(editor, editor.cursor.row)
				editor.cursor.row += 1
				editor.cursor.col = 0
			} else {
				editor.cursor.col = line_len
			}
		}

		editor.cursor.preferred_col = editor.cursor.col
	}

	ensure_cursor_visible(editor)
}

ensure_cursor_visible :: proc(editor: ^Editor) {
	w, h: i32
	sdl.GetWindowSize(editor.window, &w, &h)

	// Auto-Scroll Y
	cursor_y := f32(editor.cursor.row) * f32(editor.config.line_height)
	if cursor_y < editor.scroll.target_y {
		editor.scroll.target_y = cursor_y
	}
	if cursor_y > editor.scroll.target_y + f32(h) - f32(editor.config.line_height) {
		editor.scroll.target_y = cursor_y - f32(h) + f32(editor.config.line_height)
	}

	// Auto-Scroll X
	// Logic in content coordinates
	start_x := get_text_start_x(editor)
	viewport_w := f32(w) - start_x

	cursor_content_x := f32(editor.cursor.col) * editor.config.char_width

	if cursor_content_x < editor.scroll.target_x {
		editor.scroll.target_x = cursor_content_x
	}
	if cursor_content_x >
	   editor.scroll.target_x + viewport_w - editor.config.char_width - TEXT_MARGIN {
		editor.scroll.target_x =
			cursor_content_x - viewport_w + editor.config.char_width + TEXT_MARGIN
	}
}

update :: proc(editor: ^Editor) {
	current_tick := sdl.GetTicks()
	dt := f32(current_tick - editor.last_tick) / 1000.0
	if dt > 0.05 {dt = 0.05}
	editor.last_tick = current_tick

	// Smooth scroll
	speed := f32(15.0)
	editor.scroll.x += (editor.scroll.target_x - editor.scroll.x) * speed * dt
	editor.scroll.y += (editor.scroll.target_y - editor.scroll.y) * speed * dt

	// Clamp scroll Y
	total_height := f32(len(editor.lines)) * f32(editor.config.line_height)
	w, h: i32
	sdl.GetWindowSize(editor.window, &w, &h)
	max_y := total_height - f32(h) + f32(editor.config.line_height) * 4.0 // Some overscroll
	if max_y < 0 {max_y = 0}

	if editor.scroll.target_y < 0 {editor.scroll.target_y = 0}
	if editor.scroll.target_y > max_y {editor.scroll.target_y = max_y}

	// No clamp for X or very loose
	if editor.scroll.target_x < 0 {editor.scroll.target_x = 0}
}

leave_line :: proc(editor: ^Editor, row: int) {
	if row < 0 || row >= len(editor.lines) {return}

	line := &editor.lines[row]
	if len(line) == 0 {return}

	// Trim trailing tabs
	new_len := len(line)
	for i := len(line) - 1; i >= 0; i -= 1 {
		if line[i] == '\t' {
			new_len = i
		} else {
			break
		}
	}

	if new_len < len(line) {
		resize(line, new_len)
		editor.dirty = true
	}
}

render_line :: proc(editor: ^Editor, line_index: int, y: f32) {
	line := editor.lines[line_index]
	if len(line) == 0 {return}

	start_x := get_text_start_x(editor)
	current_x := start_x - editor.scroll.x
	tab_width_px := f32(editor.config.tab_width) * editor.config.char_width

	w_win, _: i32
	sdl.GetWindowSize(editor.window, &w_win, nil)
	screen_width := f32(w_win)

	// Quick Skip if entire line is off-screen left (requires knowing width)
	// We don't know total width. But we can skip left part fast.

	// Estimate chars to skip if far left
	offset := 0
	if current_x < -100.0 {
		// Skip some chars
		pixels_to_skip := -current_x - 100.0
		estimated_chars := int(pixels_to_skip / editor.config.char_width)
		if estimated_chars > 0 {
			// Verify we don't skip tabs blindly
			// Just loop without rendering until we are close
			for offset < len(line) && current_x < -100.0 {
				r, w := utf8.decode_rune(line[offset:])
				if r == '	' {
					line_start_x := start_x - editor.scroll.x
					rel_x := current_x - line_start_x
					current_x = line_start_x + next_tab_stop(rel_x, tab_width_px)
				} else {
					current_x += editor.config.char_width
				}
				offset += w
			}
		}
	}

	for offset < len(line) {
		// Culling (Right side)
		if current_x > screen_width {break}

		r, w := utf8.decode_rune(line[offset:])

		if r == '	' {
			line_start_x := start_x - editor.scroll.x
			rel_x := current_x - line_start_x
			current_x = line_start_x + next_tab_stop(rel_x, tab_width_px)
			offset += w
		} else {
			// Gather sequence
			start_offset := offset
			runes_count := 0

			look_offset := offset
			for look_offset < len(line) {
				nr, nw := utf8.decode_rune(line[look_offset:])
				if nr == '	' {break}
				look_offset += nw
				runes_count += 1
			}

			segment_width := f32(runes_count) * editor.config.char_width

			// Render only if visible
			if current_x + segment_width > 0 && current_x < screen_width {
				// Calculate visible sub-slice

				slice_start_runes := 0
				if current_x < 0 {
					slice_start_runes = int((-current_x) / editor.config.char_width)
				}

				slice_end_runes := runes_count
				if current_x + segment_width > screen_width {
					visible_width := screen_width - current_x
					slice_end_runes = int(visible_width / editor.config.char_width) + 1
				}

				if slice_start_runes < slice_end_runes {
					// Find byte offsets for these rune indices
					// This requires decoding again or careful stepping
					// Optimization: We already know start_offset.

					sub_start_offset := start_offset
					// Skip to start
					curr_rune_idx := 0
					temp_off := start_offset
					for curr_rune_idx < slice_start_runes {
						_, nw := utf8.decode_rune(line[temp_off:])
						temp_off += nw
						curr_rune_idx += 1
					}
					sub_start_offset = temp_off

					sub_end_offset := sub_start_offset
					// Skip to end
					for curr_rune_idx < slice_end_runes && temp_off < look_offset {
						_, nw := utf8.decode_rune(line[temp_off:])
						temp_off += nw
						curr_rune_idx += 1
					}
					sub_end_offset = temp_off

					if sub_start_offset < sub_end_offset {
						segment := line[sub_start_offset:sub_end_offset]
						text := string(segment)

						render_x := current_x + f32(slice_start_runes) * editor.config.char_width

						c_text := strings.clone_to_cstring(text, context.temp_allocator)
						text_obj := ttf.CreateText(
							editor.text_engine,
							editor.font,
							c_text,
							uint(len(text)),
						)
						if text_obj != nil {
							ttf.SetTextColor(text_obj, 220, 220, 220, 255)
							ttf.DrawRendererText(text_obj, render_x, y)
							ttf.DestroyText(text_obj)
						}
					}
				}
			}

			current_x += segment_width
			offset = look_offset
		}
	}
}

render :: proc(editor: ^Editor) {
	sdl.SetRenderDrawColor(editor.renderer, 30, 30, 30, 255) // Dark background
	sdl.RenderClear(editor.renderer)

	// Calculate visible lines
	w_win, h_win: i32
	sdl.GetWindowSize(editor.window, &w_win, &h_win)

	start_line := int(editor.scroll.y / f32(editor.config.line_height))
	if start_line < 0 {start_line = 0}

	lines_visible := int(f32(h_win) / f32(editor.config.line_height)) + 2
	end_line := start_line + lines_visible
	if end_line > len(editor.lines) {end_line = len(editor.lines)}

	// Render loop
	// Handle selection highlight
	if editor.selection.active {
		draw_selection_rects(editor, start_line, end_line)
	}

	for i := start_line; i < end_line; i += 1 {
		y := f32(i) * f32(editor.config.line_height) - editor.scroll.y
		render_line(editor, i, y)
	}

	// Draw Cursor
	cursor_x: f32 = get_text_start_x(editor) - editor.scroll.x
	if len(editor.lines) > editor.cursor.row {
		line := editor.lines[editor.cursor.row]
		width := measure_line_width(line, editor.cursor.col, editor.config)
		cursor_x += width
	}
	cursor_y := f32(editor.cursor.row) * f32(editor.config.line_height) - editor.scroll.y

	sdl.SetRenderDrawColor(editor.renderer, 200, 200, 200, 255)
	cursor_rect := sdl.FRect{cursor_x, cursor_y, 2.0, f32(editor.config.line_height)}
	sdl.RenderFillRect(editor.renderer, &cursor_rect)

	// Draw Gutter
	gutter_width := get_gutter_width(editor)
	sdl.SetRenderDrawColor(editor.renderer, 40, 40, 40, 255)
	gutter_rect := sdl.FRect{0, 0, gutter_width, f32(h_win)}
	sdl.RenderFillRect(editor.renderer, &gutter_rect)

	// Draw line numbers
	for i := start_line; i < end_line; i += 1 {
		line_num_str := fmt.tprintf("%d", i + 1)
		c_str := strings.clone_to_cstring(line_num_str, context.temp_allocator)

		text_obj := ttf.CreateText(editor.text_engine, editor.font, c_str, 0)
		if text_obj != nil {
			ttf.SetTextColor(text_obj, 120, 120, 120, 255)

			// Right align
			num_len := f32(len(line_num_str))
			// Or calculate exact width? Monospace assumption:
			num_width := num_len * editor.config.char_width

			x_pos := gutter_width - num_width - 10.0 // 10px padding from right of gutter
			y_pos := f32(i) * f32(editor.config.line_height) - editor.scroll.y

			ttf.DrawRendererText(text_obj, x_pos, y_pos)
			ttf.DestroyText(text_obj)
		}
	}

	if editor.search.active {
		draw_search_highlights(editor, start_line, end_line)
		draw_search_bar(editor)
	}

	sdl.RenderPresent(editor.renderer)
}

draw_search_highlights :: proc(editor: ^Editor, view_start, view_end: int) {
	if len(editor.search.results) == 0 {return}

	sdl.SetRenderDrawColor(editor.renderer, 100, 100, 0, 100) // Yellowish
	sdl.SetRenderDrawBlendMode(editor.renderer, {.BLEND})

	query := strings.to_string(editor.search.query)
	q_len := utf8.rune_count(query)
	start_x := get_text_start_x(editor)

	for res in editor.search.results {
		if res.row < view_start || res.row >= view_end {continue}

		line := editor.lines[res.row]
		// Measure x pos
		x_start := measure_line_width(line, res.col, editor.config)
		x_end := measure_line_width(line, res.col + q_len, editor.config)

		x := start_x - editor.scroll.x + x_start
		width := x_end - x_start
		y := f32(res.row) * f32(editor.config.line_height) - editor.scroll.y

		rect := sdl.FRect{x, y, width, f32(editor.config.line_height)}
		sdl.RenderFillRect(editor.renderer, &rect)
	}
	sdl.SetRenderDrawBlendMode(editor.renderer, {})
}

draw_search_bar :: proc(editor: ^Editor) {
	w, h: i32
	sdl.GetWindowSize(editor.window, &w, &h)

	bar_height := f32(30.0)
	if editor.search.mode == .Replace {
		bar_height = 60.0
	}
	y := f32(h) - bar_height

	// Background
	sdl.SetRenderDrawColor(editor.renderer, 45, 45, 50, 255)
	rect := sdl.FRect{0, y, f32(w), bar_height}
	sdl.RenderFillRect(editor.renderer, &rect)

	// Border
	sdl.SetRenderDrawColor(editor.renderer, 80, 80, 80, 255)
	line_rect := sdl.FRect{0, y, f32(w), 1}
	sdl.RenderFillRect(editor.renderer, &line_rect)

	// Determine focus colors
	find_color := sdl.Color{150, 150, 150, 255}
	replace_color := sdl.Color{150, 150, 150, 255}

	if editor.search.focus == .Query {
		find_color = {220, 220, 220, 255}
	} else if editor.search.focus == .ReplaceQuery {
		replace_color = {220, 220, 220, 255}
	}

	// Find Text
	query := strings.to_string(editor.search.query)
	display_str := fmt.tprintf("Find: %s", query)
	c_str := strings.clone_to_cstring(display_str, context.temp_allocator)

	text_obj := ttf.CreateText(editor.text_engine, editor.font, c_str, 0)
	if text_obj != nil {
		ttf.SetTextColor(text_obj, find_color.r, find_color.g, find_color.b, 255)
		ttf.DrawRendererText(text_obj, 10.0, y + 5.0)
		ttf.DestroyText(text_obj)
	}

	// Replace Text
	if editor.search.mode == .Replace {
		rep_query := strings.to_string(editor.search.replace_query)
		rep_str := fmt.tprintf("Replace: %s", rep_query)
		c_rep := strings.clone_to_cstring(rep_str, context.temp_allocator)

		rep_obj := ttf.CreateText(editor.text_engine, editor.font, c_rep, 0)
		if rep_obj != nil {
			ttf.SetTextColor(rep_obj, replace_color.r, replace_color.g, replace_color.b, 255)
			ttf.DrawRendererText(rep_obj, 10.0, y + 35.0)
			ttf.DestroyText(rep_obj)
		}
	}

	// Match count
	if len(editor.search.results) > 0 {
		count_str := fmt.tprintf(
			"%d/%d",
			editor.search.current_idx + 1,
			len(editor.search.results),
		)
		c_count := strings.clone_to_cstring(count_str, context.temp_allocator)
		count_obj := ttf.CreateText(editor.text_engine, editor.font, c_count, 0)
		if count_obj != nil {
			ttf.SetTextColor(count_obj, 150, 150, 150, 255)
			// Right align
			w_text: i32
			ttf.GetTextSize(count_obj, &w_text, nil)
			ttf.DrawRendererText(count_obj, f32(w) - f32(w_text) - 10.0, y + 5.0)
			ttf.DestroyText(count_obj)
		}
	}
}

clear_undo_history :: proc(editor: ^Editor) {
	for action in editor.undo_manager.undo_stack {
		delete(action.text)
	}
	clear(&editor.undo_manager.undo_stack)

	for action in editor.undo_manager.redo_stack {
		delete(action.text)
	}
	clear(&editor.undo_manager.redo_stack)
}

free_editor :: proc(editor: ^Editor) {
	// Free lines
	for line in editor.lines {
		delete(line)
	}
	delete(editor.lines)

	// Free undo
	clear_undo_history(editor)
	delete(editor.undo_manager.undo_stack)
	delete(editor.undo_manager.redo_stack)

	// Free path
	delete(editor.file_path)
}
