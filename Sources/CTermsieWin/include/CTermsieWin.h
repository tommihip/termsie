// CTermsieWin: the Win32, Direct2D and DirectWrite pieces of the Windows app, behind a flat C
// interface. DirectWrite has no C binding at all, and COM, process creation and the credential
// store are far shorter to write in C++ than through Swift's C interop, so the Swift side calls
// these functions and never touches a COM interface directly.
//
// Strings are UTF-16 (wchar_t). Coordinates are device-independent pixels (DIPs) unless a name
// says otherwise. Every function is safe to call with a NULL handle and does nothing then.

#ifndef CTERMSIEWIN_H
#define CTERMSIEWIN_H

// Deliberately free of Windows headers. Swift imports this header as a Clang module, and under
// modules windows.h leaks its include guards without its declarations, so HWND and friends
// would be unusable here. Handles are passed as opaque pointers and the C++ casts them; the
// integer types are spelled as the Windows typedefs define them (unsigned long is unsigned long).
#include <stddef.h>
#include <stdint.h>

typedef void *TWWindowHandle;
typedef void *TWMenuHandle;

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------------------------
// Process setup

/// Per-monitor DPI awareness, COM, and the common-controls classes. Call once, first thing.
void tw_process_init(void);

/// The Windows build number (e.g. 22631), read from the kernel rather than the compatibility
/// shim GetVersionEx applies.
unsigned long tw_windows_build(void);

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

/// A renderer drawing into `hwnd` through a DirectComposition swap chain, so pixels with alpha
/// below 1 show the window backdrop through. Falls back to WARP when there is no GPU.
TWRenderer *tw_renderer_create(TWWindowHandle hwnd);
void tw_renderer_destroy(TWRenderer *r);
/// Size in physical pixels and the DPI to draw at (96 = 100%).
void tw_renderer_resize(TWRenderer *r, unsigned int width, unsigned int height, float dpi);
/// 1 on success. Drawing calls are only valid between begin and end.
int tw_renderer_begin(TWRenderer *r);
/// 1 on success, 0 if the device was lost: recreate the renderer and draw again.
int tw_renderer_end(TWRenderer *r);
/// Draws the next frame into an offscreen bitmap instead of the window, and `tw_snapshot_end`
/// writes it as a PNG. Used by the headless test driver. Size in physical pixels.
int tw_snapshot_begin(TWRenderer *r, unsigned int width, unsigned int height, float dpi);
int tw_snapshot_end(TWRenderer *r, const wchar_t *pngPath);

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

/// weight: 400 regular, 700 bold. A family that does not exist falls back to Consolas.
TWFont *tw_font_create(const wchar_t *family, float sizeDIP, int weight, int italic);
void tw_font_destroy(TWFont *f);
void tw_font_metrics(TWFont *f, float dpi, TWFontMetrics *out);
/// 1 if the family is installed.
int tw_font_family_exists(const wchar_t *family);
/// Installed font families, sorted. Writes up to `cap` names separated by NUL into `out`
/// (`outChars` long) and returns how many it wrote.
int tw_font_families(wchar_t *out, int outChars, int monospacedOnly);

/// Draws one run of terminal text with its first glyph's cell at (x, y), top-left. Characters
/// the font lacks are drawn from a fallback font. `cellWidth` > 0 places each character at its
/// own cell so proportional fallbacks cannot drift the grid; `cells` (may be NULL) gives each
/// UTF-16 unit's column count (2 for wide, 0 for a
/// combining mark or the second half of a surrogate pair).
void tw_draw_cells(TWRenderer *r, TWFont *f, const wchar_t *text, int len, const uint8_t *cells,
                   float x, float y, float cellWidth, float cellHeight, float baseline, TWColor color);
/// Interface text: one line in a box, aligned (0 left, 1 centre, 2 right), vertically centred,
/// ending in an ellipsis when it does not fit.
void tw_draw_text(TWRenderer *r, TWFont *f, const wchar_t *text, int len,
                  float x, float y, float w, float h, int align, TWColor color);
/// Width of a line of interface text.
float tw_measure_text(TWFont *f, const wchar_t *text, int len);

// ---------------------------------------------------------------------------------------------
// Window chrome

/// Dark title bar and, on Windows 11, the acrylic backdrop behind translucent pixels.
/// Returns 1 when a backdrop is in effect, so the caller knows translucency will show.
int tw_window_set_appearance(TWWindowHandle hwnd, int dark, int backdrop);
void tw_window_set_icon(TWWindowHandle hwnd, const wchar_t *icoPath);
/// Places the input method's composition window at a point in client pixels, so text being
/// composed (Chinese, Japanese, Korean input) appears at the terminal's cursor.
void tw_ime_set_position(TWWindowHandle hwnd, int x, int y, int lineHeight);
/// Shows a popup menu at a point in screen pixels and returns the chosen item's id, 0 for none.
/// (TrackPopupMenu returns the id through a BOOL, which Swift imports as a truth value.)
int tw_track_menu(TWWindowHandle owner, TWMenuHandle menu, int x, int y);
/// Turns the popup menus dark, using the same uxtheme switch Explorer and Notepad use.
void tw_menus_use_dark_mode(int dark);

// ---------------------------------------------------------------------------------------------
// Pseudo console

typedef struct TWPty TWPty;

/// Starts `commandLine` attached to a new pseudo console of cols × rows. `cwd` and `environment`
/// (a double-NUL-terminated block of NAME=value strings) may be NULL to inherit. On failure
/// returns NULL and sets `*error` to the Win32 error code.
TWPty *tw_pty_spawn(const wchar_t *commandLine, const wchar_t *cwd, const wchar_t *environment,
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
// Processes

typedef struct TWProcessInfo {
    unsigned long pid;
    unsigned long parentPid;
    wchar_t name[260];
} TWProcessInfo;

/// Every process on the system, in the order the kernel lists them. Returns the count written.
int tw_list_processes(TWProcessInfo *out, int capacity);
/// The full command line of a process the user owns. Returns its length, 0 when unreadable.
int tw_process_command_line(unsigned long pid, wchar_t *out, int capacity);
/// The executable path of a process. Returns its length, 0 when unreadable.
int tw_process_image_path(unsigned long pid, wchar_t *out, int capacity);

// ---------------------------------------------------------------------------------------------
// Credential Manager

/// Stores `blob` as a generic credential named `target`. Returns 1 on success.
int tw_cred_write(const wchar_t *target, const wchar_t *comment, const void *blob, unsigned long length);
/// Reads a credential. Returns the blob length and a buffer to free with `tw_free`, or -1 when
/// there is no such credential.
int tw_cred_read(const wchar_t *target, void **blob);
int tw_cred_delete(const wchar_t *target);

// ---------------------------------------------------------------------------------------------
// Shell, clipboard, dialogs

int tw_clipboard_set_text(TWWindowHandle owner, const wchar_t *text, int len);
/// The clipboard's text, to free with `tw_free`, or NULL.
wchar_t *tw_clipboard_get_text(TWWindowHandle owner);
void tw_free(void *p);

/// Starts a program with no console window, not waiting for it. Returns 1 on success.
int tw_spawn_detached(const wchar_t *commandLine);

/// Opens a file, folder or URL with its default handler.
int tw_shell_open(const wchar_t *target);
/// Shows a folder in Explorer with `file` selected (file may be NULL).
int tw_shell_reveal(const wchar_t *folder, const wchar_t *file);

/// The standard open/save dialog. `filterSpec` like L"*.json". Returns 1 and writes the chosen
/// path to `out` when the user chose one.
int tw_file_dialog(TWWindowHandle owner, int save, int pickFolder, const wchar_t *title, const wchar_t *filterName,
                   const wchar_t *filterSpec, const wchar_t *defaultName, const wchar_t *defaultExtension,
                   const wchar_t *initialFolder, wchar_t *out, int capacity);

// ---------------------------------------------------------------------------------------------
// Integrity

/// SHA-256 of a file. Returns 1 and fills `out`.
int tw_sha256_file(const wchar_t *path, uint8_t out[32]);
/// Checks the file's Authenticode signature against the machine's trust roots. Returns 1 when
/// the signature is valid and writes the signer's subject name (the certificate's CN) to `out`.
int tw_verify_signature(const wchar_t *path, wchar_t *signer, int capacity);

#ifdef __cplusplus
}
#endif

#endif
