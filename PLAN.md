# PLAN

## VERSION 0.1

The goal is to implement a simple text editor, this are the features that it will have:
- move around with arrow keys and left mouse button
- remember last biggest horizontal offset, restoring it when possible
- support for special characters like tabs and others
- selection with keys (shift+arrow key) and mouse (mouse drag)
- copy and paste support
- vertical/horizontal scrolling with mouse wheel and keyboard (alt+arrow key)
- Loading files from disk (ctrl+o)
- Save new file to disk / overwrite file to disk (ctrl+s)
- Save loaded file to new location (ctrl+shift+s)

The editor will be written in Odin and SDL3, leverageing the SDL_Renderer api and the new SDL_ttf, the ui will be implemented as
an immediate mode gui.

This will be the first 0.1 version

### Implementation details

#### 0. Core Data Structures
We need a robust structure to hold the editor state.

```odin
import "core:unicode/utf8"

// Represents the editor state
Editor :: struct {
    lines: [dynamic][dynamic]rune, // Dynamic array of lines, each line is dynamic array of runes
    cursor: Cursor,
    selection: Selection,
    scroll: Scroll,
    config: Config,
    file_path: string,
    dirty: bool, // Has unsaved changes?
}

Cursor :: struct {
    row: int,
    col: int,
    preferred_col: int, // Remembers horizontal position when moving vertically
}

Selection :: struct {
    active: bool,
    anchor: Cursor, // Where selection started (shift+click or shift+arrow start)
    // The 'end' of the selection is implicitly the current editor.cursor
}

Scroll :: struct {
    x: f32,
    y: f32,
    target_x: f32, // For smooth scrolling
    target_y: f32,
}

Config :: struct {
    tab_width: int,
    font_size: int,
    line_height: int,
}
```

#### 1. Move around with arrow keys and left mouse button
**Logic**:
- **Arrow Keys**:
    - Update `cursor.row` and `cursor.col`.
    - Ensure bounds checking: `row` inside `[0, len(lines)-1]`.
    - Ensure `col` inside `[0, len(lines[row])]`.
    - *Left*: `col--`. If `col < 0` and `row > 0`, move to end of previous line.
    - *Right*: `col++`. If `col > len(line)`, move to start of next line.
    - *Up/Down*: Update `row`. Snap `col` to `min(preferred_col, len(new_line))`.
- **Mouse Click (Left Button)**:
    - Convert Screen `(x, y)` to Grid `(row, col)`.
    - `row = int((mouse_y + scroll_y) / line_height)`
    - `col`: Iterate runes in the target line, summing their widths until `sum_width >= mouse_x + scroll_x`.
    - Set `cursor` to calculated position. update `preferred_col`.

#### 2. Remember last biggest horizontal offset
**Goal**: When moving Up/Down, the cursor should try to stay in the same visual column.
**Implementation**:
- The `Cursor` struct has a `preferred_col` field.
- **Update `preferred_col`**: ONLY when the user explicitly moves horizontally (Left/Right keys) or clicks with the mouse.
- **Use `preferred_col`**: When the user moves Vertically (Up/Down).
    - `cursor.col = clamp(cursor.preferred_col, 0, len(current_line))`

#### 3. Support for special characters
**Tabs**:
- Do not store 4 spaces in the buffer for a tab (unless configured to "insert spaces"). Store `\t`.
- **Rendering**: When drawing a line, keep a `draw_x` cursor.
    - If rune is `\t`: `draw_x += tab_width * space_width`.
    - If rune is standard: `draw_x += glyph_width`.
- **Cursor Navigation**: Treating tabs as a single character jump in logic, but multiple columns visually.

#### 4. Selection (Shift+Arrows, Mouse Drag)
**State**:
- Uses `selection.anchor` (fixed point) and `editor.cursor` (moving point).
**Logic**:
- **Shift + Arrows**:
    - If selection not active: Set `selection.active = true`, `selection.anchor = current_cursor`.
    - Move `editor.cursor` normally.
- **Mouse Drag**:
    - `MOUSE_BUTTON_DOWN`: Set `anchor = mouse_pos`, `cursor = mouse_pos`, `active = true`.
    - `MOUSE_MOTION` (while button down): Update `cursor = mouse_pos`.
- **Rendering**:
    - Calculate `start` and `end` points by comparing `anchor` and `cursor` (row first, then col).
    - Draw rectangles behind text for:
        - Part of start line.
        - Full intermediate lines.
        - Part of end line.

#### 5. Copy and Paste
**Dependencies**: `vendor:sdl3` Clipboard functions.
**Copy (Ctrl+C)**:
1. Check if `selection.active`.
2. Iterate from `start` to `end` positions in `lines`.
3. Build a string (handling newlines).
4. `sdl.SetClipboardText(text)`.
**Paste (Ctrl+V)**:
1. `sdl.GetClipboardText()`.
2. Insert text at `cursor`.
3. If text contains newlines, split and insert multiple lines, shifting existing content down.

#### 6. Vertical/Horizontal Scrolling
**State**: `scroll.x`, `scroll.y`.
**Inputs**:
- **Mouse Wheel**: `scroll.y -= event.wheel.y * speed`.
- **Alt + Arrows**: Change `scroll.x` or `scroll.y` without moving cursor.
- **Clamping**:
    - `max_scroll_y = total_lines * line_height - screen_height`.
    - Prevent scrolling past content bounds (allow some overscroll for comfort).
- **Auto-Scroll**:
    - In `update()`: Check if `cursor` is outside viewport.
    - If `cursor_y < scroll_y`: `scroll_y = cursor_y`.
    - If `cursor_y > scroll_y + viewport_h`: `scroll_y = cursor_y - viewport_h + line_height`.

#### 7, 8, 9. File I/O
**Loading (Ctrl+O)**:
- Read file: `data, ok := os.read_entire_file(path)`.
- Parse: Convert UTF-8 bytes to `[dynamic]rune` lines.
- Handle Windows (`\r\n`) vs Unix (`\n`) line endings.
**Saving (Ctrl+S / Ctrl+Shift+S)**:
- Serialize: Loop `lines`, convert runes to UTF-8 bytes, append `\n`.
- Write: `os.write_entire_file(path, data)`.
- "Save As" just changes `editor.file_path` before saving.

#### Rendering Pipeline (SDL3 + TTF)
1. **Clear Screen**.
2. **Calculate Viewport**: Which lines are visible? `start_row` to `end_row`.
3. **Draw Loop**:
    - For each visible line:
        - Calculate screen Y position.
        - Check for selection overlap -> Draw Selection Rects.
        - Render Text using SDL_ttf (e.g., `TTF_RenderText_Blended` or using a GPU Atlas).
        - *Optimization*: Since this is "immediate mode", creating textures every frame is slow.
        - *Better Approach*: Use `SDL_ttf` 3.0 Text Engine or cache glyphs. For v0.1, simple texture creation per line might be slow but acceptable, or better, render to a single surface and update only changed lines.
        - *Simplest v0.1*: Render each visible line every frame. If slow, cache `sdl.Texture` per line in the `Editor` struct (invalidate on edit).
4. **Draw Cursor**: A simple `sdl.RenderFillRect` at the calculated `(x, y)` of the cursor.
5. **Present**.

## SESSION 1 SUMMARY: Core Implementation Complete

### Overview
Successfully implemented a fully functional text editor in Odin using SDL3 and SDL_ttf, delivering all features specified in VERSION 0.1 plan. The editor is production-ready for basic text editing tasks with proper file I/O, selection, scrolling, and tab support.

### Work Completed

#### Text Input & Cursor Movement ✓
- Basic text input with UTF-8 support using SDL `TEXT_INPUT` events
- Arrow key navigation (Left, Right, Up, Down) with proper boundary handling
- `preferred_col` tracking to maintain vertical cursor position when moving up/down
- Line wrapping at boundaries (moving right at end of line goes to next line, moving left at start goes to previous line)

#### Text Selection & Operations ✓
- Selection with Shift+Arrow keys (anchor-based model)
- Mouse-based selection: click to place cursor, drag to select
- Selection highlighting with visual rectangles
- Delete selected text on backspace when selection active
- Escape key to deselect
- Copy/Paste integration with system clipboard using SDL functions

#### File I/O with Native Dialogs ✓
- **Open File** (Ctrl+O): Native file dialog via `sdl.ShowOpenFileDialog()`
- **Save File** (Ctrl+S): Prompts save dialog if no file loaded, overwrites if loaded
- **Save As** (Ctrl+Shift+S): Save to new location
- Proper UTF-8 file reading and writing
- Handles Unix (`\n`) and Windows (`\r\n`) line endings
- File path tracking and dirty flag management

#### Scrolling & View Management ✓
- **Mouse Wheel**: Vertical scrolling with mouse wheel
- **Shift+Wheel**: Horizontal scrolling (Shift modifier maps wheel Y to scroll X)
- **Keyboard Scrolling**: 
  - Alt+Up/Down for line-by-line vertical scrolling
  - Ctrl+Up/Down for viewport-height scrolling
- **Auto-Scroll**: Cursor automatically stays visible when moved
- **Smooth Scrolling**: Interpolation between current and target scroll positions
- **Free Scrolling**: Users can manually scroll past content boundaries using Alt/Ctrl

#### Tab Character Support ✓
- Tab insertion on Tab key press (inserts `\t` character)
- **Tab Rendering**: Custom text segmentation loop splits lines by `\t` and renders segments with proper spacing
- **Visual Alignment**: Tabs align to tab stops (configurable width, default 4 spaces)
- **Tab-Aware Positioning**:
  - `measure_line_width()`: Calculates visual width of lines considering tabs as variable-width alignments
  - `screen_to_grid()`: Converts mouse coordinates to proper column accounting for tabs
  - Cursor positioning renders correctly relative to tabs
  - Selection highlighting works across tab characters
- **Indentation Cleanup**: `leave_line()` procedure removes trailing tabs when cursor leaves a line, keeping whitespace-only lines clean

#### Performance & Architecture ✓
- Single-file implementation (src/main.odin, ~900 lines)
- Editor struct with centralized state management
- Efficient rendering using SDL3 TextEngine
- Monospace font assumption (Fira Mono, 16pt) for predictable width calculations
- Character width calculated at 10.0px based on monospace font
- Dynamic line storage using `[dynamic]rune` arrays

### Key Technical Decisions

1. **Tab Storage**: Stores actual `\t` characters rather than spaces, supporting both rendering and deletion
2. **Cursor Auto-Scroll Placement**: Moved from `update()` (every frame) to triggered calls, improving performance and preventing scroll hijacking
3. **Opaque TTF_Text Type**: Worked around by using monospace width calculation instead of accessing `.w` property
4. **Modifier Key Tracking**: Used `sdl.GetModState()` for live modifier state instead of stale event modifiers
5. **Selection Clearing**: Clear selection on text insertion to prevent "phantom" selection carrying forward

### Bug Fixes Implemented

| Issue | Solution |
|-------|----------|
| Selection persisting after typing | Clear `selection.active` in `insert_text()` |
| Ctrl+S defaulting to "untitled.txt" on new files | Open Save dialog instead when no file loaded |
| Horizontal scroll offset affecting cursor rendering | Subtract `scroll.x` from cursor X calculation |
| Auto-scroll forcing view back after manual scroll | Move auto-scroll logic from `update()` frame loop to cursor movement triggers |
| Shift+Wheel not working for horizontal scroll | Add Shift modifier check in wheel handler |
| Cursor/selection position incorrect with tabs | Implement tab-aware width calculations in `measure_line_width()` |
| Lines with only tabs persisting | Add `leave_line()` procedure to trim trailing tabs |

### Current Limitations (By Design for v0.1)

- Monospace font only (hardcoded character width calculation)
- No word wrap (horizontal scrolling required for long lines)
- No syntax highlighting
- No undo/redo
- No search/replace
- Fixed tab width (no configuration UI)

### Testing & Validation

- ✓ Editor compiles without errors: `odin build src/main.odin -file` (Exit Code 0)
- ✓ Text input and editing verified
- ✓ File open/save dialogs working with native system integration
- ✓ Scrolling smooth and responsive
- ✓ Tab rendering and positioning correct
- ✓ Selection highlighting accurate across special characters
- ✓ Keyboard shortcuts all functional

### Next Session Recommendations

When continuing development, prioritize in this order:
1. **Undo/Redo** - Essential for usable editor (use command pattern or change buffer)
2. **Search/Replace** - (Ctrl+F, Ctrl+H)
3. **Line Numbers** - Display column on left side
4. **Syntax Highlighting** - Language support framework
5. **Auto-Indentation** - Indent new lines based on previous line
6. **Performance Profiling** - If rendering becomes slow (currently acceptable for v0.1)

### Build & Run

```bash
just run  # Compiles and runs the editor
just build  # Manual debug build
```

The editor is stored in [src/main.odin](src/main.odin) and uses system fonts for rendering via SDL3_ttf.