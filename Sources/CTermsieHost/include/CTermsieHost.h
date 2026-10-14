// CTermsieHost: what the shared front end needs from the platform, behind a flat C interface.
//
// On Windows the implementation (windows/) is Win32, Direct2D and DirectWrite: DirectWrite has
// no C binding at all, and COM, process creation and the credential store are far shorter to
// write in C++ than through Swift's C interop. On Linux (linux/) it is GTK 4, Cairo, Pango and
// libsecret, where GObject signals and varargs are the awkward part. The Swift side calls these
// functions and never touches a COM interface or a GObject directly.
//
// Strings are UTF-16 (TWChar). Coordinates are device-independent pixels (DIPs: logical pixels
// on Linux) unless a name says otherwise. Every function is safe to call with a NULL handle and
// does nothing then.

#ifndef CTERMSIEHOST_H
#define CTERMSIEHOST_H

// Deliberately free of platform headers. Swift imports this header as a Clang module, and under
// modules windows.h leaks its include guards without its declarations, so HWND and friends
// would be unusable here. Handles are passed as opaque pointers and the implementation casts
// them.
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
typedef wchar_t TWChar;
#else
typedef uint16_t TWChar;
#endif

/// A native window or widget: an HWND on Windows, a TWWindow on Linux.
typedef void *TWWindowHandle;
typedef struct TWMenu TWMenu;
typedef TWMenu *TWMenuHandle;

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------------------------
// Process setup

/// Per-monitor DPI awareness, COM and the common-controls classes on Windows; GTK on Linux.
/// Call once, first thing.
void tw_process_init(void);

#ifdef _WIN32
/// The Windows build number (e.g. 22631), read from the kernel rather than the compatibility
/// shim GetVersionEx applies.
unsigned long tw_windows_build(void);
#endif

// ---------------------------------------------------------------------------------------------
// Rendering

typedef struct TWRenderer TWRenderer;
typedef struct TWFont TWFont;

typedef struct TWColor {
    float r, g, b, a;   // straight (not premultiplied) alpha, 0...1
} TWColor;

typedef struct TWFontMetrics {
    float cellWidth;    // advance of a monospaced cell, rounded to whole device pixels
    float cellHeight;   // line height, rounded to whole device pixels
    float baseline;     // distance from the top of a cell to the baseline
    float underlinePosition;
    float underlineThickness;
} TWFontMetrics;

/// A renderer drawing into a window. On Windows, through a DirectComposition swap chain, so
/// pixels with alpha below 1 show the window backdrop through, falling back to WARP without a
/// GPU. On Linux, with Cairo into the window's drawing area during its draw callback.
TWRenderer *tw_renderer_create(TWWindowHandle window);
void tw_renderer_destroy(TWRenderer *r);
/// Size in physical pixels and the DPI to draw at (96 = 100%).
void tw_renderer_resize(TWRenderer *r, unsigned int width, unsigned int height, float dpi);
/// 1 on success. Drawing calls are only valid between begin and end. On Linux, 0 outside the
/// window's draw callback: ask the window to redraw instead.
int tw_renderer_begin(TWRenderer *r);
/// 1 on success, 0 if the device was lost: recreate the renderer and draw again.
int tw_renderer_end(TWRenderer *r);
/// Draws the next frame into an offscreen bitmap instead of the window, and `tw_snapshot_end`
/// writes it as a PNG. Used by the headless test driver. Size in physical pixels.
int tw_snapshot_begin(TWRenderer *r, unsigned int width, unsigned int height, float dpi);
int tw_snapshot_end(TWRenderer *r, const TWChar *pngPath);

void tw_clear(TWRenderer *r, TWColor c);
void tw_fill_rect(TWRenderer *r, float x, float y, float w, float h, TWColor c);
void tw_fill_rounded_rect(TWRenderer *r, float x, float y, float w, float h, float radius, TWColor c);
void tw_stroke_rect(TWRenderer *r, float x, float y, float w, float h, float width, TWColor c);
void tw_stroke_rounded_rect(TWRenderer *r, float x, float y, float w, float h, float radius, float width, TWColor c);
void tw_draw_line(TWRenderer *r, float x1, float y1, float x2, float y2, float width, TWColor c);
void tw_fill_ellipse(TWRenderer *r, float cx, float cy, float rx, float ry, TWColor c);
/// A soft drop shadow under a rounded rectangle, drawn as stacked translucent outlines.
void tw_draw_shadow(TWRenderer *r, float x, float y, float w, float h, float radius, float spread, float opacity);
void tw_push_clip(TWRenderer *r, float x, float y, float w, float h);
void tw_pop_clip(TWRenderer *r);
/// Clips to a rounded rectangle until the matching pop.
void tw_push_rounded_clip(TWRenderer *r, float x, float y, float w, float h, float radius);
void tw_pop_rounded_clip(TWRenderer *r);

/// weight: 400 regular, 700 bold. A family that does not exist falls back to the platform's
/// monospaced font.
TWFont *tw_font_create(const TWChar *family, float sizeDIP, int weight, int italic);
void tw_font_destroy(TWFont *f);
void tw_font_metrics(TWFont *f, float dpi, TWFontMetrics *out);
/// 1 if the family is installed.
int tw_font_family_exists(const TWChar *family);
/// Installed font families, sorted. Writes up to `cap` names separated by NUL into `out`
/// (`outChars` long) and returns how many it wrote.
int tw_font_families(TWChar *out, int outChars, int monospacedOnly);

/// Draws one run of terminal text with its first glyph's cell at (x, y), top-left. Characters
/// the font lacks are drawn from a fallback font. `cellWidth` > 0 places each character at its
/// own cell so proportional fallbacks cannot drift the grid; `cells` (may be NULL) gives each
/// UTF-16 unit's column count (2 for wide, 0 for a combining mark or the second half of a
/// surrogate pair).
void tw_draw_cells(TWRenderer *r, TWFont *f, const TWChar *text, int len, const uint8_t *cells,
                   float x, float y, float cellWidth, float cellHeight, float baseline, TWColor color);
/// Interface text: one line in a box, aligned (0 left, 1 centre, 2 right), vertically centred,
/// ending in an ellipsis when it does not fit.
void tw_draw_text(TWRenderer *r, TWFont *f, const TWChar *text, int len,
                  float x, float y, float w, float h, int align, TWColor color);
/// Width of a line of interface text.
float tw_measure_text(TWFont *f, const TWChar *text, int len);

// ---------------------------------------------------------------------------------------------
// Window chrome

/// Dark title bar and, on Windows 11, the acrylic backdrop behind translucent pixels.
/// Returns 1 when a backdrop is in effect, so the caller knows translucency will show. Linux
/// has no compositor-independent blur and returns 0.
int tw_window_set_appearance(TWWindowHandle window, int dark, int backdrop);
void tw_window_set_icon(TWWindowHandle window, const TWChar *iconPath);
/// Places the input method's composition window at a point in client pixels, so text being
/// composed (Chinese, Japanese, Korean input) appears at the terminal's cursor.
void tw_ime_set_position(TWWindowHandle window, int x, int y, int lineHeight);

// Popup menus, built item by item. Ids are the caller's; 0 is reserved for "nothing chosen".
TWMenuHandle tw_menu_create(void);
void tw_menu_append(TWMenuHandle menu, int id, const TWChar *label, int enabled, int checked);
void tw_menu_append_separator(TWMenuHandle menu);
/// Takes ownership of `submenu`.
void tw_menu_append_submenu(TWMenuHandle menu, const TWChar *label, TWMenuHandle submenu);
void tw_menu_destroy(TWMenuHandle menu);
/// Shows a popup menu at a point in the window's client pixels and returns the chosen item's
/// id, 0 for none. Blocks until the menu closes.
int tw_track_menu(TWWindowHandle window, TWMenuHandle menu, int x, int y);

// ---------------------------------------------------------------------------------------------
// Pseudo console (Windows; Linux uses SwiftTerm's own forkpty process)

#ifdef _WIN32
typedef struct TWPty TWPty;

/// Starts `commandLine` attached to a new pseudo console of cols × rows. `cwd` and `environment`
/// (a double-NUL-terminated block of NAME=value strings) may be NULL to inherit. On failure
/// returns NULL and sets `*error` to the Win32 error code.
TWPty *tw_pty_spawn(const TWChar *commandLine, const TWChar *cwd, const TWChar *environment,
                    short cols, short rows, unsigned long *error);
/// Blocking read of the console's output. Returns the byte count, 0 at end of stream.
int tw_pty_read(TWPty *p, void *buffer, unsigned long capacity);
/// Writes input to the console. Returns 1 on success.
int tw_pty_write(TWPty *p, const void *data, unsigned long length);
void tw_pty_resize(TWPty *p, short cols, short rows);
unsigned long tw_pty_pid(TWPty *p);
/// Waits for the child to exit. Returns 1 and sets `*exitCode` when it has, 0 on timeout.
int tw_pty_wait(TWPty *p, unsigned long timeoutMs, unsigned long *exitCode);
/// Closes the pseudo console, which ends the read loop. Safe to call from any thread, once.
void tw_pty_close(TWPty *p);
/// Ends the child and every process it started.
void tw_pty_terminate(TWPty *p);
/// Frees the handle. Call only after the reader has seen end of stream.
void tw_pty_free(TWPty *p);

// ---------------------------------------------------------------------------------------------
// Processes (Windows; Linux reads /proc)

typedef struct TWProcessInfo {
    unsigned long pid;
    unsigned long parentPid;
    TWChar name[260];
} TWProcessInfo;

/// Every process on the system, in the order the kernel lists them. Returns the count written.
int tw_list_processes(TWProcessInfo *out, int capacity);
/// The full command line of a process the user owns. Returns its length, 0 when unreadable.
int tw_process_command_line(unsigned long pid, TWChar *out, int capacity);
/// The executable path of a process. Returns its length, 0 when unreadable.
int tw_process_image_path(unsigned long pid, TWChar *out, int capacity);
#endif

// ---------------------------------------------------------------------------------------------
// Secret store: the Credential Manager on Windows, the Secret Service (libsecret) on Linux

/// Stores `blob` as a credential named `target`, labelled `comment`. Returns 1 on success.
int tw_cred_write(const TWChar *target, const TWChar *comment, const void *blob, uint32_t length);
/// Reads a credential. Returns the blob length and a buffer to free with `tw_free`, or -1 when
/// there is no such credential.
int tw_cred_read(const TWChar *target, void **blob);
int tw_cred_delete(const TWChar *target);

// ---------------------------------------------------------------------------------------------
// Shell, clipboard, dialogs

int tw_clipboard_set_text(TWWindowHandle owner, const TWChar *text, int len);
/// The clipboard's text, to free with `tw_free`, or NULL.
TWChar *tw_clipboard_get_text(TWWindowHandle owner);
/// The selection clipboard (PRIMARY on Linux; the ordinary clipboard elsewhere).
int tw_selection_set_text(TWWindowHandle owner, const TWChar *text, int len);
TWChar *tw_selection_get_text(TWWindowHandle owner);
void tw_free(void *p);

#ifdef _WIN32
/// Starts a program with no console window, not waiting for it. Returns 1 on success.
int tw_spawn_detached(const TWChar *commandLine);
#endif

/// Opens a file, folder or URL with its default handler.
int tw_shell_open(const TWChar *target);
/// Shows a folder in the file manager with `file` selected (file may be NULL).
int tw_shell_reveal(const TWChar *folder, const TWChar *file);

/// The standard open/save dialog. `filterSpec` like L"*.json". Returns 1 and writes the chosen
/// path to `out` when the user chose one.
int tw_file_dialog(TWWindowHandle owner, int save, int pickFolder, const TWChar *title, const TWChar *filterName,
                   const TWChar *filterSpec, const TWChar *defaultName, const TWChar *defaultExtension,
                   const TWChar *initialFolder, TWChar *out, int capacity);

#ifdef _WIN32
// ---------------------------------------------------------------------------------------------
// Integrity (the Windows updater)

/// SHA-256 of a file. Returns 1 and fills `out`.
int tw_sha256_file(const TWChar *path, uint8_t out[32]);
/// Checks the file's Authenticode signature against the machine's trust roots. Returns 1 when
/// the signature is valid and writes the signer's subject name (the certificate's CN) to `out`.
int tw_verify_signature(const TWChar *path, TWChar *signer, int capacity);
#endif

#ifndef _WIN32
// ---------------------------------------------------------------------------------------------
// Linux: the GTK window, the main loop, dialogs and the rest of what Win32 gives the Windows
// host directly. Coordinates to the callbacks are logical pixels; `mods` is bit 1 shift,
// bit 2 alt, bit 4 control.

typedef struct TWWindow TWWindow;

typedef struct TWWindowCallbacks {
    void *context;
    /// Called inside the drawing area's draw: renderer begin/end work only during this.
    void (*draw)(void *context);
    void (*resize)(void *context, int width, int height, int scale);
    /// Buttons: 0 left, 1 middle, 2 right.
    void (*mouse_down)(void *context, double x, double y, int button, unsigned mods);
    void (*mouse_up)(void *context, double x, double y, int button, unsigned mods);
    void (*mouse_move)(void *context, double x, double y, unsigned mods);
    void (*mouse_leave)(void *context);
    /// Wheel steps, positive away from the user (up) and to the left.
    void (*scroll)(void *context, double x, double y, double stepsX, double stepsY, unsigned mods);
    /// A key the input method left alone. `keyval` is GDK's, `base` the same key with no
    /// modifiers (for shortcuts), `unicode` the character it would type or 0. Return 1 to
    /// consume it.
    int (*key_down)(void *context, unsigned keyval, unsigned base, unsigned unicode, unsigned mods);
    /// Text the input method committed, UTF-8.
    void (*text)(void *context, const char *utf8);
    void (*focus)(void *context, int focused);
    /// The close button. Return 1 to let the window close.
    int (*close_request)(void *context);
    void (*destroyed)(void *context);
} TWWindowCallbacks;

TWWindow *tw_window_create(const TWWindowCallbacks *callbacks, const TWChar *title, int width, int height);
void tw_window_show(TWWindow *w, int activate);
void tw_window_destroy(TWWindow *w);
void tw_window_set_title(TWWindow *w, const TWChar *title);
/// Logical size and the integer scale factor.
void tw_window_get_size(TWWindow *w, int *width, int *height, int *scale);
int tw_window_is_visible(TWWindow *w);
int tw_window_is_focused(TWWindow *w);
void tw_window_set_fullscreen(TWWindow *w, int on);
int tw_window_is_fullscreen(TWWindow *w);
/// A CSS cursor name: "default", "text", "pointer", "move", "ew-resize"...
void tw_window_set_cursor(TWWindow *w, const char *name);
void tw_window_queue_draw(TWWindow *w);

/// Posts work to the GTK main loop from any thread.
void tw_main_post(void (*fn)(void *), void *context);
/// Runs `fn` on the main loop after `ms` milliseconds. Returns an id for `tw_main_cancel`.
unsigned tw_main_after(unsigned ms, void (*fn)(void *), void *context);
void tw_main_cancel(unsigned id);
/// Runs the main loop until `tw_main_quit`. Returns the code given to it.
int tw_main_run(void);
void tw_main_quit(int code);

/// Watches a directory for changes through GIO. The callback runs on the main loop.
typedef struct TWWatch TWWatch;
TWWatch *tw_watch_directory(const TWChar *path, void (*fn)(void *), void *context);
void tw_watch_stop(TWWatch *w);

/// The desktop's interface font family (GTK's gtk-font-name), written to `out`. Returns its
/// length.
int tw_ui_font_family(TWChar *out, int capacity);
void tw_beep(void);

/// A message box. `buttons`: 0 OK, 1 OK/Cancel, 3 Yes/No/Cancel, 4 Yes/No; `icon`: 0 info,
/// 1 question, 2 warning, 3 error; `defaultSecond` makes the second button the default.
/// Returns 1 OK, 2 Cancel, 6 Yes, 7 No, the Win32 ids, so both hosts answer alike.
int tw_alert(TWWindowHandle owner, const TWChar *title, const TWChar *message, int buttons, int icon, int defaultSecond);

/// A form: labelled rows of controls and a row of buttons, the Linux side of the settings
/// dialogs. Controls are keyed by a UTF-8 string the callbacks report.
typedef struct TWForm TWForm;
typedef struct TWControl TWControl;

typedef struct TWFormCallbacks {
    void *context;
    void (*button)(void *context, int id);
    void (*accessory)(void *context, const char *key);
    void (*selection_changed)(void *context, const char *key);
    /// The close button. Return 1 to let the form close.
    int (*close_request)(void *context);
} TWFormCallbacks;

TWForm *tw_form_create(TWWindowHandle owner, const TWChar *title, int resizable, const TWFormCallbacks *callbacks);
void tw_form_destroy(TWForm *f);
TWControl *tw_form_add_heading(TWForm *f, const char *key, const TWChar *text);
TWControl *tw_form_add_note(TWForm *f, const char *key, const TWChar *text);
TWControl *tw_form_add_text(TWForm *f, const char *key, const TWChar *label, const TWChar *value, const TWChar *accessory);
TWControl *tw_form_add_multiline(TWForm *f, const char *key, const TWChar *label, const TWChar *value, int lines, int monospace);
TWControl *tw_form_add_check(TWForm *f, const char *key, const TWChar *label, int on);
/// `options` is NUL-separated, double-NUL terminated.
TWControl *tw_form_add_choice(TWForm *f, const char *key, const TWChar *label, const TWChar *options, int selected);
TWControl *tw_form_add_combo(TWForm *f, const char *key, const TWChar *label, const TWChar *options, const TWChar *text);
TWControl *tw_form_add_button(TWForm *f, const char *key, const TWChar *title);
void tw_form_add_action(TWForm *f, int id, const TWChar *title, int isDefault);
/// Shows the form. Modal runs a nested loop until `tw_form_finish`.
void tw_form_present(TWForm *f, int modal);
void tw_form_finish(TWForm *f);
void tw_form_hide(TWForm *f);
int tw_form_is_visible(TWForm *f);
/// The control's text, to free with `tw_free`.
TWChar *tw_control_get_text(TWControl *c);
void tw_control_set_text(TWControl *c, const TWChar *text);
int tw_control_get_checked(TWControl *c);
void tw_control_set_checked(TWControl *c, int on);
int tw_control_get_selection(TWControl *c);
void tw_control_set_selection(TWControl *c, int index);
void tw_control_set_options(TWControl *c, const TWChar *options, int selected);
/// Hides or shows the control with its label and accessory.
void tw_control_set_visible(TWControl *c, int visible);
void tw_control_set_enabled(TWControl *c, int enabled);
void tw_control_focus(TWControl *c, int selectAll);
#endif

#ifdef __cplusplus
}
#endif

#endif
