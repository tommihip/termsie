// A GTK 4 window holding one drawing area, which the Swift host draws and receives every event
// of. Keys go through an input method first (so composed text works), then to the host; the
// pointer comes straight from GDK's events, including while a button is held outside the window.

#include "Internal.h"

#include <stdlib.h>

static unsigned modifiers(GdkModifierType state) {
    unsigned m = 0;
    if (state & GDK_SHIFT_MASK) m |= 1;
    if (state & GDK_ALT_MASK) m |= 2;
    if (state & GDK_CONTROL_MASK) m |= 4;
    return m;
}

static void drawArea(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    struct TWWindow *tw = data;
    tw->cr = cr;
    tw->width = width;
    tw->height = height;
    if (tw->cb.draw) tw->cb.draw(tw->cb.context);
    tw->cr = NULL;
}

static void areaResized(GtkDrawingArea *area, int width, int height, gpointer data) {
    struct TWWindow *tw = data;
    tw->width = width;
    tw->height = height;
    tw->scale = gtk_widget_get_scale_factor(GTK_WIDGET(area));
    if (tw->scale < 1) tw->scale = 1;
    if (tw->cb.resize) tw->cb.resize(tw->cb.context, width, height, tw->scale);
}

static void imCommitted(GtkIMContext *im, const char *text, gpointer data) {
    (void)im;
    struct TWWindow *tw = data;
    if (tw->cb.text && text) tw->cb.text(tw->cb.context, text);
}

static gboolean keyPressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state,
                           gpointer data) {
    struct TWWindow *tw = data;
    if (!tw->cb.key_down) return FALSE;
    // The key with no modifiers, for shortcuts: Ctrl+Shift+T is the T key whatever Shift makes it.
    guint base = keyval;
    GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
    GdkDisplay *display = gtk_widget_get_display(tw->area);
    guint translated = 0;
    int group = event ? (int)gdk_key_event_get_layout(event) : 0;
    int effectiveGroup = 0, level = 0;
    GdkModifierType consumed = 0;
    if (gdk_display_translate_key(display, keycode, (GdkModifierType)0, group, &translated, &effectiveGroup, &level, &consumed)
        && translated) {
        base = translated;
    }
    guint unicode = gdk_keyval_to_unicode(keyval);
    return tw->cb.key_down(tw->cb.context, keyval, base, unicode, modifiers(state)) ? TRUE : FALSE;
}

static void focusEntered(GtkEventControllerFocus *c, gpointer data) {
    (void)c;
    struct TWWindow *tw = data;
    gtk_im_context_focus_in(tw->im);
}

static void focusLeft(GtkEventControllerFocus *c, gpointer data) {
    (void)c;
    struct TWWindow *tw = data;
    gtk_im_context_focus_out(tw->im);
}

static int buttonIndex(guint button) {
    switch (button) {
    case 1: return 0;
    case 2: return 1;
    case 3: return 2;
    default: return -1;
    }
}

static gboolean pointerEvent(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer data) {
    (void)controller;
    struct TWWindow *tw = data;
    GdkEventType type = gdk_event_get_event_type(event);
    switch (type) {
    case GDK_BUTTON_PRESS:
    case GDK_BUTTON_RELEASE:
    case GDK_MOTION_NOTIFY:
    case GDK_SCROLL:
    case GDK_LEAVE_NOTIFY:
        break;
    default:
        return FALSE;
    }
    double sx = 0, sy = 0;
    gdk_event_get_position(event, &sx, &sy);
    // Surface coordinates to the drawing area's.
    GtkNative *native = gtk_widget_get_native(tw->area);
    double nx = 0, ny = 0;
    if (native) gtk_native_get_surface_transform(native, &nx, &ny);
    graphene_point_t in = GRAPHENE_POINT_INIT((float)(sx - nx), (float)(sy - ny)), out = in;
    if (native && !gtk_widget_compute_point(GTK_WIDGET(native), tw->area, &in, &out)) out = in;
    double x = out.x, y = out.y;
    unsigned mods = modifiers(gdk_event_get_modifier_state(event));

    switch (type) {
    case GDK_BUTTON_PRESS: {
        int button = buttonIndex(gdk_button_event_get_button(event));
        if (button < 0) return FALSE;
        tw->pressed |= 1u << button;
        gtk_widget_grab_focus(tw->area);
        if (tw->cb.mouse_down) tw->cb.mouse_down(tw->cb.context, x, y, button, mods);
        return TRUE;
    }
    case GDK_BUTTON_RELEASE: {
        int button = buttonIndex(gdk_button_event_get_button(event));
        if (button < 0) return FALSE;
        tw->pressed &= ~(1u << button);
        if (tw->cb.mouse_up) tw->cb.mouse_up(tw->cb.context, x, y, button, mods);
        return TRUE;
    }
    case GDK_MOTION_NOTIFY:
        if (tw->cb.mouse_move) tw->cb.mouse_move(tw->cb.context, x, y, mods);
        return FALSE;
    case GDK_SCROLL: {
        double stepsX = 0, stepsY = 0;
        switch (gdk_scroll_event_get_direction(event)) {
        case GDK_SCROLL_UP: stepsY = 1; break;
        case GDK_SCROLL_DOWN: stepsY = -1; break;
        case GDK_SCROLL_LEFT: stepsX = 1; break;
        case GDK_SCROLL_RIGHT: stepsX = -1; break;
        case GDK_SCROLL_SMOOTH: {
            double dx = 0, dy = 0;
            gdk_scroll_event_get_deltas(event, &dx, &dy);
#if GTK_CHECK_VERSION(4, 8, 0)
            // A touchpad reports pixels; a wheel reports clicks.
            if (gdk_scroll_event_get_unit(event) == GDK_SCROLL_UNIT_SURFACE) { dx /= 40; dy /= 40; }
#endif
            stepsX = -dx;
            stepsY = -dy;
            break;
        }
        }
        if (tw->cb.scroll) tw->cb.scroll(tw->cb.context, x, y, stepsX, stepsY, mods);
        return TRUE;
    }
    case GDK_LEAVE_NOTIFY:
        if (!tw->pressed && tw->cb.mouse_leave) tw->cb.mouse_leave(tw->cb.context);
        return FALSE;
    default:
        return FALSE;
    }
}

static gboolean closeRequested(GtkWindow *window, gpointer data) {
    (void)window;
    struct TWWindow *tw = data;
    if (tw->cb.close_request) return tw->cb.close_request(tw->cb.context) ? FALSE : TRUE;
    return FALSE;
}

static void activeChanged(GObject *window, GParamSpec *spec, gpointer data) {
    (void)spec;
    struct TWWindow *tw = data;
    if (tw->cb.focus) tw->cb.focus(tw->cb.context, gtk_window_is_active(GTK_WINDOW(window)) ? 1 : 0);
}

static void windowDestroyed(GtkWidget *window, gpointer data) {
    (void)window;
    struct TWWindow *tw = data;
    tw->window = NULL;
    tw->area = NULL;
    if (tw->cb.destroyed) tw->cb.destroyed(tw->cb.context);
    if (tw->im) g_object_unref(tw->im);
    free(tw);
}

TWWindow *tw_window_create(const TWWindowCallbacks *callbacks, const TWChar *title, int width, int height) {
    struct TWWindow *tw = calloc(1, sizeof *tw);
    if (callbacks) tw->cb = *callbacks;
    tw->width = width > 0 ? width : 1280;
    tw->height = height > 0 ? height : 820;
    tw->scale = 1;

    tw->window = gtk_window_new();
    char *t = tw_utf8(title, -1);
    gtk_window_set_title(GTK_WINDOW(tw->window), t ? t : "Termsie");
    g_free(t);
    gtk_window_set_default_size(GTK_WINDOW(tw->window), tw->width, tw->height);

    tw->area = gtk_drawing_area_new();
    gtk_widget_set_focusable(tw->area, TRUE);
    gtk_widget_set_hexpand(tw->area, TRUE);
    gtk_widget_set_vexpand(tw->area, TRUE);
    gtk_widget_set_size_request(tw->area, 520, 300);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(tw->area), drawArea, tw, NULL);
    g_signal_connect(tw->area, "resize", G_CALLBACK(areaResized), tw);
    gtk_window_set_child(GTK_WINDOW(tw->window), tw->area);

    tw->im = gtk_im_multicontext_new();
    gtk_im_context_set_client_widget(tw->im, tw->area);
    g_signal_connect(tw->im, "commit", G_CALLBACK(imCommitted), tw);

    GtkEventController *key = gtk_event_controller_key_new();
    gtk_event_controller_key_set_im_context(GTK_EVENT_CONTROLLER_KEY(key), tw->im);
    g_signal_connect(key, "key-pressed", G_CALLBACK(keyPressed), tw);
    gtk_widget_add_controller(tw->area, key);

    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(focusEntered), tw);
    g_signal_connect(focus, "leave", G_CALLBACK(focusLeft), tw);
    gtk_widget_add_controller(tw->area, focus);

    GtkEventController *legacy = gtk_event_controller_legacy_new();
    g_signal_connect(legacy, "event", G_CALLBACK(pointerEvent), tw);
    gtk_widget_add_controller(tw->area, legacy);

    g_signal_connect(tw->window, "close-request", G_CALLBACK(closeRequested), tw);
    g_signal_connect(tw->window, "notify::is-active", G_CALLBACK(activeChanged), tw);
    g_signal_connect(tw->window, "destroy", G_CALLBACK(windowDestroyed), tw);
    return tw;
}

void tw_window_show(TWWindow *tw, int activate) {
    if (!tw || !tw->window) return;
    if (activate) gtk_window_present(GTK_WINDOW(tw->window)); else gtk_widget_set_visible(tw->window, TRUE);
    gtk_widget_grab_focus(tw->area);
}

void tw_window_destroy(TWWindow *tw) {
    if (!tw || !tw->window) return;
    gtk_window_destroy(GTK_WINDOW(tw->window));   // frees tw through the destroy signal
}

void tw_window_set_title(TWWindow *tw, const TWChar *title) {
    if (!tw || !tw->window) return;
    char *t = tw_utf8(title, -1);
    gtk_window_set_title(GTK_WINDOW(tw->window), t ? t : "");
    g_free(t);
}

void tw_window_get_size(TWWindow *tw, int *width, int *height, int *scale) {
    if (!tw) return;
    if (width) *width = tw->width;
    if (height) *height = tw->height;
    if (scale) *scale = tw->scale > 0 ? tw->scale : 1;
}

int tw_window_is_visible(TWWindow *tw) {
    return tw && tw->window && gtk_widget_get_visible(tw->window);
}

int tw_window_is_focused(TWWindow *tw) {
    return tw && tw->window && gtk_window_is_active(GTK_WINDOW(tw->window));
}

void tw_window_set_fullscreen(TWWindow *tw, int on) {
    if (!tw || !tw->window) return;
    if (on) gtk_window_fullscreen(GTK_WINDOW(tw->window)); else gtk_window_unfullscreen(GTK_WINDOW(tw->window));
}

int tw_window_is_fullscreen(TWWindow *tw) {
    return tw && tw->window && gtk_window_is_fullscreen(GTK_WINDOW(tw->window));
}

void tw_window_set_cursor(TWWindow *tw, const char *name) {
    if (tw && tw->area) gtk_widget_set_cursor_from_name(tw->area, name);
}

void tw_window_queue_draw(TWWindow *tw) {
    if (tw && tw->area) gtk_widget_queue_draw(tw->area);
}
