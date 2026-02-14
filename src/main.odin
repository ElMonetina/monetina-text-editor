package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// 0. Core Data Structures

Editor :: struct {
	lines:       [dynamic][dynamic]rune, // Dynamic array of lines, each line is dynamic array of runes
	cursor:      Cursor,
	selection:   Selection,
	scroll:      Scroll,
	config:      Config,
	file_path:   string,
	dirty:       bool, // Has unsaved changes?

	// Rendering state
	window:      ^sdl.Window,
	renderer:    ^sdl.Renderer,
	font:        ^ttf.Font,
	text_engine: ^ttf.TextEngine,
	last_tick:   u64, // Time of last frame
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

// Global constants
WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 600
FONT_PATH :: "fonts/Fira_Mono/FiraMono-Regular.ttf"

main :: proc() {
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
	editor.config = Config {
		tab_width   = 4,
		font_size   = 16,
		line_height = 20, // Will be updated
		char_width  = 10.0, // Will be updated
	}

	// Initialize Window and Renderer
	window_flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}
	editor.window = sdl.CreateWindow("moned", WINDOW_WIDTH, WINDOW_HEIGHT, window_flags)
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
		append(&editor.lines, make([dynamic]rune))
	}

	if !sdl.StartTextInput(editor.window) {
		fmt.eprintln("StartTextInput failed")
	}

	fmt.println("Editor started")

	editor.last_tick = sdl.GetTicks()

	// Main Loop
	running := true
	for running {
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
	}
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
		line_len := len(editor.lines[r])

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

		x := 10.0 - editor.scroll.x + x_start
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

			delete(c_path)
		}
	} else if event.type == .MOUSE_BUTTON_DOWN {
		if event.button.button == sdl.BUTTON_LEFT {
			click_row, click_col := screen_to_grid(editor, event.button.x, event.button.y)

			if click_row != editor.cursor.row {
				leave_line(editor)
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

screen_to_grid :: proc(editor: ^Editor, x, y: f32) -> (int, int) {
	rel_y := y + editor.scroll.y
	row := int(rel_y / f32(editor.config.line_height))
	if row < 0 {row = 0}
	if row >= len(editor.lines) {row = len(editor.lines) - 1}

	rel_x := x + editor.scroll.x - 10.0 // Margin

	line := editor.lines[row]
	current_x := f32(0.0)
	tab_width_px := f32(editor.config.tab_width) * editor.config.char_width

	for i := 0; i < len(line); i += 1 {
		char_w := editor.config.char_width
		if line[i] == '\t' {
			// Calculate tab width
			next_tab := (int(current_x / tab_width_px) + 1)
			new_x := f32(next_tab) * tab_width_px
			char_w = new_x - current_x
		}

		if rel_x < current_x + char_w / 2.0 {
			return row, i
		}
		current_x += char_w
	}

	return row, len(line)
}

measure_line_width :: proc(line: [dynamic]rune, count: int, config: Config) -> f32 {
	width := f32(0.0)
	tab_width_px := f32(config.tab_width) * config.char_width

	for i := 0; i < count && i < len(line); i += 1 {
		if line[i] == '\t' {
			next_tab := (int(width / tab_width_px) + 1)
			width = f32(next_tab) * tab_width_px
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
		case:
		// Handle other keys
		}
	}
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

load_file :: proc(editor: ^Editor, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != os.General_Error.None {
		fmt.eprintln("Failed to read file:", path, "Error:", err)
		return
	}
	defer delete(data)

	text := string(data)

	// Clear existing lines
	for line in editor.lines {
		delete(line)
	}
	clear(&editor.lines)

	// Split lines
	// Handle \r\n
	lines_str := strings.split(text, "\n", context.temp_allocator)

	for l in lines_str {
		// Remove \r if present
		line_content := l
		if len(l) > 0 && l[len(l) - 1] == '\r' {
			line_content = l[:len(l) - 1]
		}

		runes := utf8.string_to_runes(line_content)
		// dynamic array creation from slice
		d_line := make([dynamic]rune)
		append(&d_line, ..runes)
		append(&editor.lines, d_line)
		delete(runes) // runes slice from string_to_runes needs to be freed?
		// "Returns a slice of runes allocated with allocator." -> Yes.
	}

	editor.file_path = strings.clone(path)
	editor.cursor = Cursor{0, 0, 0}
	editor.selection.active = false
	fmt.println("Loaded file:", path)
}

save_file :: proc(editor: ^Editor, path: string) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	for i := 0; i < len(editor.lines); i += 1 {
		line := editor.lines[i]
		str := utf8.runes_to_string(line[:], context.temp_allocator)
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
	// Simple stub for now to fix build if functions missing
	// Assuming logic from previous step is fine but maybe missing imports?
	// Ah, strings builder usage needs "core:strings" which is imported.
	// But get_selection_text logic was complex.

	s := editor.selection.anchor
	e := editor.cursor

	if s.row > e.row || (s.row == e.row && s.col > e.col) {
		temp := s
		s = e
		e = temp
	}

	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator) // Use temp allocator for simplicity

	for r := s.row; r <= e.row; r += 1 {
		line := editor.lines[r]
		c_start := 0
		if r == s.row {c_start = s.col}
		c_end := len(line)
		if r == e.row {c_end = e.col}

		if c_end > len(line) {c_end = len(line)}
		if c_start > len(line) {c_start = len(line)}

		if c_start < c_end {
			// Slicing dynamic array?
			// line is [dynamic]rune
			// slice := line[c_start:c_end] works in Odin?
			// slice is []rune

			// Manual copy to ensure we have a valid slice
			// Or just utf8.runes_to_string
			// But runes_to_string takes []rune.
			// line[:] is []rune.

			slice := line[c_start:c_end]
			str := utf8.runes_to_string(slice, context.temp_allocator)
			strings.write_string(&builder, str)
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
	// Handle multiline insertion
	// Clear selection before inserting (if any)
	// For v0.1: just disable selection, don't delete selected text yet
	editor.selection.active = false

	lines_str := strings.split(text, "\n", context.temp_allocator)

	for i := 0; i < len(lines_str); i += 1 {
		line_str := lines_str[i]
		// Strip \r
		content := line_str
		if len(content) > 0 && content[len(content) - 1] == '\r' {
			content = content[:len(content) - 1]
		}

		if len(content) > 0 {
			runes := utf8.string_to_runes(content, context.temp_allocator)
			line := &editor.lines[editor.cursor.row]
			inject_at(line, editor.cursor.col, ..runes)
			editor.cursor.col += len(runes)
		}

		if i < len(lines_str) - 1 {
			insert_newline(editor)
		}
	}
	editor.cursor.preferred_col = editor.cursor.col
	ensure_cursor_visible(editor)
}

insert_newline :: proc(editor: ^Editor) {
	editor.selection.active = false
	current_line := &editor.lines[editor.cursor.row]

	// Split current line at cursor.col
	// Right part moves to new line
	right_part := make([dynamic]rune)
	if editor.cursor.col < len(current_line) {
		append(&right_part, ..current_line[editor.cursor.col:])
		resize(current_line, editor.cursor.col)
	}

	// Insert new line after current row
	inject_at(&editor.lines, editor.cursor.row + 1, right_part)

	leave_line(editor)

	editor.cursor.row += 1
	editor.cursor.col = 0
	editor.cursor.preferred_col = 0
	ensure_cursor_visible(editor)
}

delete_char_backwards :: proc(editor: ^Editor) {
	if editor.cursor.col > 0 {
		// Remove char at col-1
		line := &editor.lines[editor.cursor.row]
		ordered_remove(line, editor.cursor.col - 1)
		editor.cursor.col -= 1
		editor.cursor.preferred_col = editor.cursor.col
	} else if editor.cursor.row > 0 {
		// Merge with previous line
		curr_line := editor.lines[editor.cursor.row]
		prev_line := &editor.lines[editor.cursor.row - 1]

		old_len := len(prev_line)
		append(prev_line, ..curr_line[:])

		// Remove current line
		ordered_remove(&editor.lines, editor.cursor.row)
		delete(curr_line) // Free memory of removed line

		editor.cursor.row -= 1
		editor.cursor.col = old_len
		editor.cursor.preferred_col = old_len
	}
	ensure_cursor_visible(editor)
}

delete_selection :: proc(editor: ^Editor) {
	if !editor.selection.active {return}

	s := editor.selection.anchor
	e := editor.cursor

	if s.row > e.row || (s.row == e.row && s.col > e.col) {
		temp := s
		s = e
		e = temp
	}

	if s.row == e.row {
		line := &editor.lines[s.row]
		// Count of chars to remove: e.col - s.col
		// Remove from s.col to e.col-1
		count := e.col - s.col
		for i := 0; i < count; i += 1 {
			ordered_remove(line, s.col)
		}
	} else {
		// Multi-line delete

		// 1. Truncate start line to s.col
		start_line := &editor.lines[s.row]
		resize(start_line, s.col)

		// 2. Append suffix of end line
		end_line := editor.lines[e.row]
		if e.col < len(end_line) {
			append(start_line, ..end_line[e.col:])
		}

		// 3. Remove intermediate lines (s.row+1 to e.row inclusive)
		// We remove from index e.row down to s.row+1 to avoid shifting issues
		for i := e.row; i > s.row; i -= 1 {
			delete(editor.lines[i]) // Free memory of inner array
			ordered_remove(&editor.lines, i)
		}
	}

	editor.cursor = s
	editor.cursor.preferred_col = s.col
	editor.selection.active = false
	ensure_cursor_visible(editor)
}

move_cursor :: proc(editor: ^Editor, d_row, d_col: int) {
	// Vertical movement
	if d_row != 0 {
		old_row := editor.cursor.row
		editor.cursor.row += d_row
		if editor.cursor.row < 0 {editor.cursor.row = 0}
		if editor.cursor.row >= len(editor.lines) {editor.cursor.row = len(editor.lines) - 1}

		if editor.cursor.row != old_row {
			// Restore old row temporarily to clear it
			new_row := editor.cursor.row
			editor.cursor.row = old_row
			leave_line(editor)
			editor.cursor.row = new_row
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
				editor.cursor.row -= 1
				editor.cursor.col = len(editor.lines[editor.cursor.row])
			} else {
				editor.cursor.col = 0
			}
		} else if editor.cursor.col > line_len {
			if editor.cursor.row < len(editor.lines) - 1 {
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
	cursor_x := f32(editor.cursor.col) * editor.config.char_width + 10.0
	if cursor_x < editor.scroll.target_x {
		editor.scroll.target_x = cursor_x - 10.0
	}
	if cursor_x > editor.scroll.target_x + f32(w) - editor.config.char_width - 20.0 {
		editor.scroll.target_x = cursor_x - f32(w) + editor.config.char_width + 20.0
	}
}

update :: proc(editor: ^Editor) {
	current_tick := sdl.GetTicks()
	dt := f32(current_tick - editor.last_tick) / 1000.0
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

leave_line :: proc(editor: ^Editor) {
	if editor.cursor.row < 0 || editor.cursor.row >= len(editor.lines) {return}

	line := &editor.lines[editor.cursor.row]
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
		line := editor.lines[i]
		if len(line) == 0 {continue}

		current_x := 10.0 - editor.scroll.x
		y := f32(i) * f32(editor.config.line_height) - editor.scroll.y
		tab_width_px := f32(editor.config.tab_width) * editor.config.char_width

		// Render line segment by segment
		seg_builder: strings.Builder
		strings.builder_init(&seg_builder, context.temp_allocator)

		for r_idx := 0; r_idx < len(line); r_idx += 1 {
			r := line[r_idx]
			if r == '\t' {
				// Flush segment
				if strings.builder_len(seg_builder) > 0 {
					text := strings.to_string(seg_builder)
					c_text := strings.clone_to_cstring(text, context.temp_allocator)
					text_obj := ttf.CreateText(
						editor.text_engine,
						editor.font,
						c_text,
						uint(len(text)),
					)
					if text_obj != nil {
						ttf.DrawRendererText(text_obj, current_x, y)
						// text_obj is opaque, assume monospace width
						current_x += f32(utf8.rune_count(text)) * editor.config.char_width
						ttf.DestroyText(text_obj)
					}
					strings.builder_reset(&seg_builder)
				}

				// Advance tab
				// Rel x from start of line content (ignoring scroll for alignment)
				line_start_x := 10.0 - editor.scroll.x
				rel_x := current_x - line_start_x
				next_tab := (int(rel_x / tab_width_px) + 1)
				current_x = line_start_x + f32(next_tab) * tab_width_px
			} else {
				strings.write_rune(&seg_builder, r)
			}
		}

		// Flush remaining
		if strings.builder_len(seg_builder) > 0 {
			text := strings.to_string(seg_builder)
			c_text := strings.clone_to_cstring(text, context.temp_allocator)
			text_obj := ttf.CreateText(editor.text_engine, editor.font, c_text, uint(len(text)))
			if text_obj != nil {
				ttf.DrawRendererText(text_obj, current_x, y)
				ttf.DestroyText(text_obj)
			}
		}
	}

	// Draw Cursor
	cursor_x: f32 = 10.0 - editor.scroll.x
	if len(editor.lines) > editor.cursor.row {
		line := editor.lines[editor.cursor.row]
		width := measure_line_width(line, editor.cursor.col, editor.config)
		cursor_x += width
	}
	cursor_y := f32(editor.cursor.row) * f32(editor.config.line_height) - editor.scroll.y

	sdl.SetRenderDrawColor(editor.renderer, 200, 200, 200, 255)
	cursor_rect := sdl.FRect{cursor_x, cursor_y, 2.0, f32(editor.config.line_height)}
	sdl.RenderFillRect(editor.renderer, &cursor_rect)

	sdl.RenderPresent(editor.renderer)
}
