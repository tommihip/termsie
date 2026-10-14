// Shared between the Linux host's C files: the window struct the renderer draws into, and the
// UTF-16 ↔ UTF-8 conversions every function needs at its edge.

#ifndef TW_INTERNAL_H
#define TW_INTERNAL_H

#define GDK_DISABLE_DEPRECATION_WARNINGS
#include <gtk/gtk.h>
#include <pango/pangocairo.h>

#include "CTermsieHost.h"

/// Every native handle the Swift side passes as an owner (a main window, a form) starts with
/// its GtkWindow, so dialogs can find a parent whichever it is.
struct TWNative {
    GtkWidget *window;
};

struct TWWindow {
    GtkWidget *window;      // first, as TWNative
    GtkWidget *area;
    GtkIMContext *im;
    TWWindowCallbacks cb;
    cairo_t *cr;            // the drawing area's context, during its draw callback only
    int width, height;      // logical pixels
    int scale;
    unsigned pressed;       // buttons held, so a leave during a drag is not a leave
};

/// UTF-8 copy of a UTF-16 string, to g_free. `len` -1 for NUL-terminated.
char *tw_utf8(const TWChar *s, int len);
/// UTF-16 copy of a UTF-8 string, to free with tw_free.
TWChar *tw_utf16(const char *s);
/// Writes a UTF-8 string into a UTF-16 buffer, NUL-terminated. Returns the length written.
int tw_write_utf16(const char *s, TWChar *out, int capacity);
/// The GtkWindow behind an owner handle, or NULL.
GtkWindow *tw_parent(TWWindowHandle owner);

#endif
