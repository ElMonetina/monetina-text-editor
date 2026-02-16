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

## VERSION 0.1.1

This version is a followup cleanup of version 0.1, it aims to make the code clearer, less buggy and more performant. Not a feature
release, so it won't add any new functionality.

## SESSION 2 SUMMARY: Refactoring & Polish Complete

### Overview
Executed version 0.1.1 of the plan, focusing on code cleanup, bug fixes, and architecture improvements. The codebase is now more robust and easier to extend.

### Work Completed

#### Code Cleanup & Organization ✓
- **Refactored Rendering**: Extracted `render_line` procedure to simplify the main `render` loop, reducing complexity in the main update cycle.
- **Constants**: Introduced `TEXT_MARGIN` (10.0) to replace magic numbers for consistent layout.
- **Helper Functions**: Created `next_tab_stop` helper to unify tab width calculations across `render`, `measure_line_width`, and `screen_to_grid`, eliminating logic duplication.

#### Bug Fixes & Logic Improvements ✓
- **Selection Replacement**: Typing text or pressing Enter with an active selection now correctly deletes the selected text before inserting new content (previously it just deselected).
- **Dirty Flag Tracking**: The `dirty` flag is now correctly set to `true` when inserting text, deleting characters, or modifying lines, ensuring the editor tracks unsaved changes.
- **Trailing Tab Cleanup**: Moving the cursor horizontally across line boundaries now triggers `leave_line`, ensuring trailing tabs are trimmed correctly on the line being left.
- **Text Color**: Explicitly set text color to white (220, 220, 220) to ensure visibility against the dark background, rather than relying on defaults.

#### Build Status
- ✓ Editor compiles without errors: `odin build src -debug` (Exit Code 0)

### Next Steps
The editor is now in a cleaner state. The original recommendations for the next session remain valid:
1. **Undo/Redo** - Essential for usable editor (use command pattern or change buffer)
2. **Search/Replace** - (Ctrl+F, Ctrl+H)
3. **Line Numbers** - Display column on left side

## VERSION 0.2

This version focuses on essential text editing features and usability improvements.

### Features
1.  **Undo/Redo System**: Robust history of actions.
2.  **Search & Replace**: Find text within the file and replace occurrences.
3.  **Line Numbers**: Visual indicator of line positions.
4.  **Performance**: Optimize file loading for larger files.

### Implementation Details

#### 1. Undo/Redo System
**Architecture**: Command Pattern with History Stacks.

```odin
ActionType :: enum { Insert, Delete }

Action :: struct {
    type: ActionType,
    start: Cursor,       // Where the action happened
    text: string,        // The text involved (inserted or deleted)
    timestamp: u64,      // For grouping typing actions
}

UndoManager :: struct {
    undo_stack: [dynamic]Action,
    redo_stack: [dynamic]Action,
    is_undoing: bool,    // Flag to prevent recording actions during undo/redo
}
```

**Logic**:
- **Record Action**: Whenever `insert_text` or `delete_...` is called, push an `Action` to `undo_stack` and clear `redo_stack`.
- **Undo (Ctrl+Z)**: Pop from `undo_stack`.
    - If `Insert`: Delete inserted text (range `start` to `start + len`).
    - If `Delete`: Insert `text` at `start`.
    - Push inverse action to `redo_stack`.
- **Redo (Ctrl+Y)**: Pop from `redo_stack`, execute, push to `undo_stack`.
- **Grouping**: Consecutive character insertions within a small time window should be merged into a single action to avoid undoing one character at a time.

#### 2. Search & Replace
**UI**:
- A simple overlay at the bottom of the screen.
- Toggle with `Ctrl+F`.
- Input field for search query.

**State**:
```odin
SearchState :: struct {
    active: bool,
    query: strings.Builder,
    results: [dynamic]Cursor, // Start positions of matches
    current_idx: int,
}
```

**Logic**:
- **Find**: Scan `editor.lines`, match `query`. Store results.
- **Navigate (Enter/F3)**: Move cursor to `results[current_idx]`, scroll to view.
- **Highlight**: Draw a different background color for the text at result positions.

#### 3. Line Numbers
**Rendering**:
- Calculate `gutter_width` based on `total_lines` digits.
- In `render()`:
    - Draw a background rect for the gutter on the left.
    - Loop visible lines: Render line number at `y`, right-aligned in gutter.
    - Offset text rendering X start position by `gutter_width`.
- **Input**: Adjust `screen_to_grid` to account for `gutter_width` offset (subtract it from mouse X).

#### 4. Performance: File Loading
**Current**: `read_entire_file` -> `split` -> `string_to_runes` (High memory usage/allocations).
**Optimized**:
- Read file bytes.
- Iterate bytes, decoding UTF-8 on the fly using `utf8.decode_rune`.
- Build `[dynamic]rune` for current line.
- On `\n`, append line to `lines`, start new line.
- Avoid creating intermediate strings for every line.

### Plan Steps
1.  **Refactor**: Implement `UndoManager` and hook it into `insert`/`delete`.
2.  **Feature**: Implement `Ctrl+Z` / `Ctrl+Y`.
3.  **UI**: Implement Line Numbers (affects layout constants).
4.  **UI**: Implement Search overlay and logic.
5.  **Optimization**: Rewrite `load_file`.

## SESSION 3 SUMMARY: Version 0.2 Complete

### Overview
Successfully implemented all planned features for Version 0.2, including robust Undo/Redo, Search & Replace, Line Numbers, and significant performance optimizations. The editor now supports advanced editing workflows and handles large files smoothly.

### Work Completed

#### 1. Undo/Redo System ✓
- **Architecture**: Implemented Command Pattern with `UndoManager` and `Action` structs.
- **Actions**: Supports `Insert` and `Delete` actions with precise cursor restoration.
- **Integration**: Hooked into all text modification functions (`insert_text`, `delete_selection`, etc.).
- **Shortcuts**: `Ctrl+Z` (Undo), `Ctrl+Y` / `Ctrl+Shift+Z` (Redo).

#### 2. Search & Replace ✓
- **UI**: Added a custom overlay at the bottom of the window.
- **Find**: Real-time search with result highlighting (yellow blend mode).
- **Replace**: `Ctrl+H` toggles Replace mode. `Enter` replaces current match and finds next.
- **Navigation**: `Enter`, `F3`, `Shift+F3` for cycling through results.
- **Feedback**: Displays match count (e.g., "1/5") and highlights current match.

#### 3. Line Numbers & Gutter ✓
- **Dynamic Width**: Gutter width scales based on total line count (`log10`).
- **Rendering**: Drawn on top of text content to handle horizontal scrolling correctly.
- **Interaction**: Clicking the gutter selects the corresponding line.
- **Visuals**: Distinct background color and right-aligned numbers.

#### 4. Performance Optimizations ✓
- **File Loading**: Rewrote `load_file` to stream UTF-8 bytes directly into dynamic rune arrays, avoiding massive string allocations.
- **Rendering**: Implemented view frustum culling in `render_line` to skip processing/rendering characters outside the visible viewport (both left and right).
- **Smooth Scrolling**: Clamped `dt` to prevent scroll jumping during lag spikes.
- **Frame Rate**: Added a 120 FPS limiter and disabled VSync to ensure consistent performance.

### Build Status
- ✓ Editor compiles and runs successfully: `odin build src -debug`

## VERSION 0.2.1

goals:
- default line gutter to be 4 lines wide to avoid the moving of the text buffer while typing.
- reduce ram usage, for reference I opend a very large file in this editor and it took 660mb in ram, I opened the same file in KWrite and it took 85mb.
- review the code of version 0.2, clean it up and look for possible bugs and performance improvements.
## VERSION 0.2.1

### Goals
- [ ] Set minimum gutter width to 4 digits (e.g., "   1").
- [ ] Reduce RAM usage significantly (Goal: < 100MB for large files).
- [ ] Code cleanup and optimization.

### Implementation Plan

#### 1. Gutter Width
- **Task**: Modify `get_gutter_width` in `src/main.odin`.
- **Detail**: Ensure the calculated width corresponds to at least 4 digits.

#### 2. Data Structure Refactor (RAM Reduction)
- **Task**: Change `Editor.lines` from `[dynamic][dynamic]rune` to `[dynamic][dynamic]u8`.
- **Impact**:
  - `load_file`: Read as bytes, split by newline, store as `[dynamic]u8`.
  - `save_file`: Write bytes directly.
  - `insert_text`: Convert input to UTF-8 bytes and insert.
  - `delete_range`: Operate on byte slices.
  - `render_line`: Iterate bytes, decode runes on-the-fly for rendering and column counting.
  - `Cursor`: Keep `col` as character index (0-based visual column).
  - `Helpers`: Implement `byte_offset_of_col(line: []u8, col: int) -> int` and `col_of_byte_offset`.

#### 3. Code Cleanup
- **Task**: Review `UndoManager` for potential memory leaks (e.g. `Action.text` strings).
- **Task**: Ensure all dynamic arrays are properly freed on shutdown (though OS does this, good practice).

## VERSION 0.2.1 SUMMARY: RAM Reduction & Polish

### Overview
Successfully refactored the core data structure to reduce RAM usage significantly and polished the UI.

### Work Completed
#### 1. RAM Reduction (Data Structure Refactor) ✓
- **Change**: Switched from `[dynamic][dynamic]rune` to `[dynamic][dynamic]u8`.
- **Impact**: ASCII text now takes 1 byte per char instead of 4 bytes per rune + array overhead.
- **Implementation**:
  - Rewrote `load_file` to stream bytes directly.
  - Rewrote `insert_text`, `delete_char_backwards`, `delete_range` to handle UTF-8 byte manipulation.
  - Rewrote `render_line` to decode UTF-8 on the fly.
  - Updated `clipboard` handling.

#### 2. UI Polish ✓
- **Gutter**: Enforced minimum width of 4 digits for stability.

#### 3. Code Cleanup ✓
- **Undo History**: Implemented `clear_undo_history` to properly free memory when loading new files.

### Build Status
- ✓ Editor compiles and runs successfully: `odin build src -debug`

## VERSION 0.2.2 [UNPLANNED]

### Bug Fixes
- **Lag on Long Lines**: Rewrote `render_line` to perform fast-forward skipping of off-screen text segments, avoiding expensive `CreateText` calls for non-visible content.
- **RAM Usage**: Optimized `load_file` to allocate exact capacity for lines, reducing memory overhead from dynamic array growth.

### Technical Details
- **Rendering**: Implemented view frustum culling logic inside `render_line` that calculates visible rune ranges based on character width and current scroll position.
- **File Loading**: Replaced `append`-based line construction with a two-pass approach (scan for newline, allocate exact size, copy).
- **Correctness**: Fixed potential off-by-one errors in line parsing logic (CRLF handling).

### Results
- Significant reduction in RAM usage (estimated ~200MB savings for large files with short lines).
- Elimination of rendering lag for long lines (rendering time now proportional to screen width, not line length).

## VERSION 0.2.3 [UNPLANNED]

### Debugging
- **Memory Tracking**: Implemented `mem.Tracking_Allocator` in `main.odin` to identify memory leaks.
- **Resource Cleanup**: Added explicit cleanup for all dynamic data structures on shutdown to ensure the allocator reports true leaks only.

### Bug Fixes (v0.2.3)
- **Bad Free**: Fixed "Bad free" error in file operations by ensuring memory allocated by the default allocator in callbacks is freed by the default allocator in `handle_event`.

## VERSION 0.2.3 SUMMARY: Memory Tracking & Cleanup

### Overview
Implemented memory tracking tools to debug memory usage and ensure resource cleanup. User has further optimized the tracking code to be conditional on `ODIN_DEBUG`.

### Work Completed
#### 1. Memory Tracking ✓
- **Implementation**: Added `mem.Tracking_Allocator` to `main.odin`.
- **Optimization**: User updated code to use `when ODIN_DEBUG` and `core:log` for cleaner debug output.
- **Verification**: Verified that the editor runs without major leaks (after fixing the "Bad free" issue with callback strings).

#### 2. Resource Cleanup ✓
- **Implementation**: Added `free_editor` procedure to explicitly release dynamic arrays and resources on shutdown.
- **Result**: Memory usage is confirmed low (~50MB) and stable.

### Current Status
- Editor is performant and memory efficient.
- Codebase is clean and instrumented for debugging.
- Ready for Version 0.3 planning.

## VERSION 0.3
## VERSION 0.3
 ### Goals
  1. Switch to `core:nbio` for asynchronous file handling.
  2. Implement a versatile Status Bar.
  3. Unify command inputs (Search, Goto, Open, Save) into the Status Bar.
  4. Replace native file dialogs with command-based input.
  5. Implement Goto Line (Ctrl+G).

 ### Implementation Details
  #### 1. Async File I/O with core:nbio
   Integration [structs/init]
    Import `core:nbio`
    Initialize event loop `nbio.acquire_thread_event_loop()`
    Add `nbio.tick()` to main loop
   Loading
    `load_file_async(path)` triggers `nbio.open`
    Callbacks: `on_open` -> `nbio.read` -> `on_read_complete` -> `parse_buffer`
   Saving
    `save_file_async(path)` triggers `nbio.open` (Write/Create/Trunc)
    Callbacks: `on_open` -> `nbio.write` -> `on_write_complete` -> `nbio.close`

  #### 2. Status Bar & Command System
   Data Structures
    InputMode enum [Text, Command]
    CommandType enum [None, Find, Replace, GotoLine, OpenFile, SaveFile]
    CommandState struct
     active bool
     type CommandType
     input strings.Builder
     prompt string
     message string (for status updates like "Saved")
     message_time u64
   Rendering
    `render_status_bar` function
    Layout: Prompt/Input (Left), Cursor/File Info (Right)
   Input Handling
    Route keys to `handle_command_input` when in Command mode

  #### 3. Features
   Goto Line (Ctrl+G)
    Prompt: "Goto Line: "
    Action: Parse int, validate, update cursor.row
   File Operations
    Open (Ctrl+O): Prompt "Open: ", trigger async load
    Save (Ctrl+S): If path exists, save. Else prompt "Save As: "
   Search/Replace
    Refactor to use Status Bar input instead of overlay

 ### Plan Steps
  1. **UI & Infrastructure**: Implement `CommandState` and `render_status_bar`. ✓
  2. **Command Input**: Implement input handling for the status bar (Enter to submit, Esc to cancel). ✓
  3. **Goto Line**: Implement Ctrl+G using the new system. ✓
  4. **NBIO Integration**: Setup `nbio` loop and implement `load_file_async` / `save_file_async`. ✓
  5. **File Commands**: Connect Ctrl+O/Ctrl+S to the async IO functions. ✓
  6. **Search Migration**: Move Find/Replace to the status bar. ✓
  7. **Cleanup**: Remove SDL dialogs and sync IO. ✓

 ## VERSION 0.3 SUMMARY: Async I/O & Unified Commands
  ### Overview
   Successfully transitioned to asynchronous file I/O using `core:nbio` and implemented a command-based status bar for improved UX.
  ### Work Completed
   #### 1. Status Bar & Command System ✓
    - Implemented `CommandState` and rendering.
    - Unified input for commands (Open, Save, Find, Replace, Goto).
    - Added instant replacement preview for better UX.
    - Added cursor rendering in status bar.
   #### 2. Async I/O ✓
    - Integrated `core:nbio` event loop.
    - Implemented non-blocking load and save operations.
   #### 3. Cleanup & Polish ✓
    - Removed synchronous file dialogs.
    - Refactored Search to use the status bar.
    - Confirmed correct memory management for async operations.
    - Fixed undo/redo behavior for Replace operations by implementing a dedicated `Replace` action type.

 ## VERSION 0.3 SUMMARY: Async I/O & Unified Commands
  ### Overview
   Successfully transitioned to asynchronous file I/O using `core:nbio` and implemented a command-based status bar for improved UX.
  ### Work Completed
   #### 1. Status Bar & Command System ✓
    - Implemented `CommandState` and rendering.
    - Unified input for commands (Open, Save, Find, Replace, Goto).
    - Added instant replacement preview for better UX.
    - Added cursor rendering in status bar.
   #### 2. Async I/O ✓
    - Integrated `core:nbio` event loop.
    - Implemented non-blocking load and save operations.
   #### 3. Cleanup & Polish ✓
    - Removed synchronous file dialogs.
    - Refactored Search to use the status bar.
    - Confirmed correct memory management for async operations.

## VERSION 0.4

goals:
1. autoindent, works both with tabs and spaces.
2. Smart autopairs for characters like ", (, [, etc. Smart in the sense that it autopairs only if the next char is blank or \n.
3. surround text with pair characters, instead of replace it (when selecting text)
4. home/end to go to beginning and end of lines.
5. ctrl+left/ctrl+right to jump words (move to next blank space or \n)
6. expand ~ character when opening/saving files
7. tab completion for folders/files when loading/saving files.
8. trim empty lines after the last one not empty when saving.
9. add empty line after last one when saving.
