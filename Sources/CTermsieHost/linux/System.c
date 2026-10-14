// Process setup, the main loop, menus, the clipboard, dialogs, the secret store, and the
// desktop's conventions, over GTK 4, GIO and libsecret.

#include "Internal.h"

#include <libsecret/secret.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------------- strings

char *tw_utf8(const TWChar *s, int len) {
    if (!s) return NULL;
    return g_utf16_to_utf8(s, len, NULL, NULL, NULL);
}

TWChar *tw_utf16(const char *s) {
    if (!s) return NULL;
    glong n = 0;
    gunichar2 *u = g_utf8_to_utf16(s, -1, NULL, &n, NULL);
    if (!u) return NULL;
    TWChar *out = malloc((n + 1) * sizeof(TWChar));
    memcpy(out, u, (n + 1) * sizeof(TWChar));
    g_free(u);
    return out;
}

int tw_write_utf16(const char *s, TWChar *out, int capacity) {
    if (!out || capacity <= 0) return 0;
    out[0] = 0;
    if (!s) return 0;
    glong n = 0;
    gunichar2 *u = g_utf8_to_utf16(s, -1, NULL, &n, NULL);
    if (!u) return 0;
    if (n >= capacity) n = capacity - 1;
    memcpy(out, u, n * sizeof(TWChar));
    out[n] = 0;
    g_free(u);
    return (int)n;
}

GtkWindow *tw_parent(TWWindowHandle owner) {
    if (!owner) return NULL;
    GtkWidget *w = ((struct TWNative *)owner)->window;
    return w && GTK_IS_WINDOW(w) ? GTK_WINDOW(w) : NULL;
}

void tw_free(void *p) { free(p); }

// ------------------------------------------------------------------------------------ setup

void tw_process_init(void) {
    // No display (a container running `--emit-shim`) is not fatal here; only a window needs one.
    if (!gtk_init_check()) return;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_object_set(settings, "gtk-application-prefer-dark-theme", TRUE, NULL);
}

int tw_window_set_appearance(TWWindowHandle window, int dark, int backdrop) {
    (void)window; (void)dark; (void)backdrop;
    // Blur behind a window is a compositor extension (KDE has one, GNOME none), so terminals
    // are drawn opaque.
    return 0;
}

void tw_window_set_icon(TWWindowHandle window, const TWChar *iconPath) {
    (void)iconPath;
    GtkWindow *w = tw_parent(window);
    if (w) gtk_window_set_icon_name(w, "com.termsie.app");
}

void tw_ime_set_position(TWWindowHandle window, int x, int y, int lineHeight) {
    struct TWWindow *tw = window;
    if (!tw || !tw->im) return;
    int s = tw->scale > 0 ? tw->scale : 1;
    GdkRectangle r = {x / s, y / s, 1, lineHeight / s};
    gtk_im_context_set_cursor_location(tw->im, &r);
}

void tw_beep(void) {
    GdkDisplay *d = gdk_display_get_default();
    if (d) gdk_display_beep(d);
}

int tw_ui_font_family(TWChar *out, int capacity) {
    char *name = NULL;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_object_get(settings, "gtk-font-name", &name, NULL);
    const char *family = "Sans";
    PangoFontDescription *desc = name ? pango_font_description_from_string(name) : NULL;
    if (desc && pango_font_description_get_family(desc)) family = pango_font_description_get_family(desc);
    int n = tw_write_utf16(family, out, capacity);
    if (desc) pango_font_description_free(desc);
    g_free(name);
    return n;
}

// -------------------------------------------------------------------------------- main loop

typedef struct {
    void (*fn)(void *);
    void *context;
} Work;

static gboolean runWork(gpointer data) {
    Work *w = data;
    w->fn(w->context);
    return G_SOURCE_REMOVE;
}

void tw_main_post(void (*fn)(void *), void *context) {
    Work *w = g_new(Work, 1);
    w->fn = fn;
    w->context = context;
    g_idle_add_full(G_PRIORITY_DEFAULT, runWork, w, g_free);
}

unsigned tw_main_after(unsigned ms, void (*fn)(void *), void *context) {
    Work *w = g_new(Work, 1);
    w->fn = fn;
    w->context = context;
    return g_timeout_add_full(G_PRIORITY_DEFAULT, ms, runWork, w, g_free);
}

void tw_main_cancel(unsigned id) {
    if (id) g_source_remove(id);
}

static GMainLoop *mainLoop;
static int quitCode;

int tw_main_run(void) {
    mainLoop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(mainLoop);
    g_main_loop_unref(mainLoop);
    mainLoop = NULL;
    return quitCode;
}

void tw_main_quit(int code) {
    quitCode = code;
    if (mainLoop) g_main_loop_quit(mainLoop);
}

/// Runs a nested loop until `*done` is set, pumping events meanwhile: how a synchronous dialog
/// or clipboard read waits on GTK's asynchronous answers.
static void waitUntil(int *done, GMainLoop **loopOut) {
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    *loopOut = loop;
    while (!*done) g_main_context_iteration(NULL, TRUE);
    *loopOut = NULL;
    g_main_loop_unref(loop);
}

// ------------------------------------------------------------------------------------ watch

struct TWWatch {
    GFileMonitor *monitor;
    void (*fn)(void *);
    void *context;
};

static void watchChanged(GFileMonitor *m, GFile *a, GFile *b, GFileMonitorEvent e, gpointer data) {
    (void)m; (void)a; (void)b; (void)e;
    struct TWWatch *w = data;
    w->fn(w->context);
}

TWWatch *tw_watch_directory(const TWChar *path, void (*fn)(void *), void *context) {
    char *p = tw_utf8(path, -1);
    if (!p) return NULL;
    GFile *file = g_file_new_for_path(p);
    g_free(p);
    GFileMonitor *monitor = g_file_monitor_directory(file, G_FILE_MONITOR_NONE, NULL, NULL);
    g_object_unref(file);
    if (!monitor) return NULL;
    struct TWWatch *w = g_new0(struct TWWatch, 1);
    w->monitor = monitor;
    w->fn = fn;
    w->context = context;
    g_signal_connect(monitor, "changed", G_CALLBACK(watchChanged), w);
    return w;
}

void tw_watch_stop(TWWatch *w) {
    if (!w) return;
    g_file_monitor_cancel(w->monitor);
    g_object_unref(w->monitor);
    g_free(w);
}

// ------------------------------------------------------------------------------------ menus

struct TWMenu {
    GMenu *menu;              // the sections
    GMenu *section;           // the one being filled
    GSimpleActionGroup *actions;
    int chosen;
    int done;
};

TWMenuHandle tw_menu_create(void) {
    TWMenu *m = g_new0(TWMenu, 1);
    m->menu = g_menu_new();
    m->section = g_menu_new();
    g_menu_append_section(m->menu, NULL, G_MENU_MODEL(m->section));
    m->actions = g_simple_action_group_new();
    return m;
}

static void itemActivated(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)parameter;
    TWMenu *root = data;
    const char *name = g_action_get_name(G_ACTION(action));
    root->chosen = atoi(name + 4);   // "item<id>"
    root->done = 1;
}

/// "Ctrl+Shift+N" as GTK spells an accelerator: "<Control><Shift>n".
static char *accelerator(const char *label) {
    GString *out = g_string_new(NULL);
    char **parts = g_strsplit(label, "+", -1);
    int n = 0;
    while (parts[n]) n++;
    for (int i = 0; i < n - 1; i++) {
        if (!strcmp(parts[i], "Ctrl")) g_string_append(out, "<Control>");
        else if (!strcmp(parts[i], "Alt")) g_string_append(out, "<Alt>");
        else if (!strcmp(parts[i], "Shift")) g_string_append(out, "<Shift>");
    }
    const char *key = n > 0 ? parts[n - 1] : "";
    const char *name = key;
    if (!strcmp(key, "Enter")) name = "Return";
    else if (!strcmp(key, "PgUp")) name = "Page_Up";
    else if (!strcmp(key, "PgDn")) name = "Page_Down";
    else if (!strcmp(key, "Del")) name = "Delete";
    else if (!strcmp(key, "Ins")) name = "Insert";
    else if (!strcmp(key, "Esc")) name = "Escape";
    else if (!strcmp(key, "=")) name = "equal";
    else if (!strcmp(key, "+")) name = "plus";
    else if (!strcmp(key, "-")) name = "minus";
    else if (!strcmp(key, ",")) name = "comma";
    else if (!strcmp(key, "[")) name = "bracketleft";
    else if (!strcmp(key, "]")) name = "bracketright";
    else if (!strcmp(key, "\\")) name = "backslash";
    if (strlen(key) == 1 && g_ascii_isalpha(key[0])) {
        g_string_append_c(out, g_ascii_tolower(key[0]));
    } else {
        g_string_append(out, name);
    }
    g_strfreev(parts);
    return g_string_free(out, FALSE);
}

void tw_menu_append(TWMenuHandle menu, int id, const TWChar *label, int enabled, int checked) {
    if (!menu || !label) return;
    char *text = tw_utf8(label, -1);
    if (!text) return;
    char *tab = strchr(text, '\t');
    char *accel = NULL;
    if (tab) {
        *tab = 0;
        accel = accelerator(tab + 1);
    }
    char *name = g_strdup_printf("item%d", id);
    GSimpleAction *action = checked ? g_simple_action_new_stateful(name, NULL, g_variant_new_boolean(TRUE))
                                    : g_simple_action_new(name, NULL);
    g_simple_action_set_enabled(action, enabled ? TRUE : FALSE);
    g_signal_connect(action, "activate", G_CALLBACK(itemActivated), menu);
    g_action_map_add_action(G_ACTION_MAP(menu->actions), G_ACTION(action));
    GMenuItem *item = g_menu_item_new(text, NULL);
    char *detailed = g_strdup_printf("menu.%s", name);
    g_menu_item_set_action_and_target_value(item, detailed, NULL);
    if (accel && *accel) g_menu_item_set_attribute(item, "accel", "s", accel);
    g_menu_append_item(menu->section, item);
    g_object_unref(item);
    g_object_unref(action);
    g_free(detailed);
    g_free(name);
    g_free(accel);
    g_free(text);
}

void tw_menu_append_separator(TWMenuHandle menu) {
    if (!menu) return;
    if (g_menu_model_get_n_items(G_MENU_MODEL(menu->section)) == 0) return;
    g_object_unref(menu->section);
    menu->section = g_menu_new();
    g_menu_append_section(menu->menu, NULL, G_MENU_MODEL(menu->section));
}

/// A submenu's items end up in the parent's action group, which is the one the popover gets.
static void adoptActions(TWMenu *into, TWMenu *from) {
    char **names = g_action_group_list_actions(G_ACTION_GROUP(from->actions));
    for (int i = 0; names && names[i]; i++) {
        GAction *a = g_action_map_lookup_action(G_ACTION_MAP(from->actions), names[i]);
        if (!a) continue;
        g_signal_handlers_disconnect_by_func(a, itemActivated, from);
        g_signal_connect(a, "activate", G_CALLBACK(itemActivated), into);
        g_action_map_add_action(G_ACTION_MAP(into->actions), a);
    }
    g_strfreev(names);
}

void tw_menu_append_submenu(TWMenuHandle menu, const TWChar *label, TWMenuHandle submenu) {
    if (!menu || !submenu) return;
    char *text = tw_utf8(label, -1);
    adoptActions(menu, submenu);
    g_menu_append_submenu(menu->section, text ? text : "", G_MENU_MODEL(submenu->menu));
    g_free(text);
    tw_menu_destroy(submenu);
}

void tw_menu_destroy(TWMenuHandle menu) {
    if (!menu) return;
    g_object_unref(menu->section);
    g_object_unref(menu->menu);
    g_object_unref(menu->actions);
    g_free(menu);
}

static void popoverClosed(GtkPopover *p, gpointer data) {
    (void)p;
    TWMenu *menu = data;
    // The item's action fires after the popover closes; let it, then stop waiting.
    menu->done = 1;
}

static gboolean finishLater(gpointer data) {
    int *done = data;
    *done = 1;
    return G_SOURCE_REMOVE;
}

int tw_track_menu(TWWindowHandle window, TWMenuHandle menu, int x, int y) {
    struct TWWindow *tw = window;
    if (!tw || !menu || !tw->area) return 0;
    menu->chosen = 0;
    menu->done = 0;
    GtkWidget *popover = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu->menu));
    gtk_widget_insert_action_group(popover, "menu", G_ACTION_GROUP(menu->actions));
    gtk_widget_set_parent(popover, tw->area);
    gtk_popover_set_has_arrow(GTK_POPOVER(popover), FALSE);
    int s = tw->scale > 0 ? tw->scale : 1;
    GdkRectangle at = {x / s, y / s, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(popover), &at);
    gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
    int closed = 0;
    g_signal_connect(popover, "closed", G_CALLBACK(popoverClosed), menu);
    gtk_popover_popup(GTK_POPOVER(popover));
    while (!menu->done) g_main_context_iteration(NULL, TRUE);
    // Give a chosen item's activation, which arrives after the close, one more turn.
    g_idle_add_full(G_PRIORITY_LOW, finishLater, &closed, NULL);
    while (!closed) g_main_context_iteration(NULL, TRUE);
    gtk_widget_unparent(popover);
    return menu->chosen;
}

// -------------------------------------------------------------------------------- clipboard

typedef struct {
    char *text;
    int done;
    int refs;
} ClipRead;

static void clipReadFinished(GObject *source, GAsyncResult *result, gpointer data) {
    ClipRead *read = data;
    read->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, NULL);
    read->done = 1;
    if (--read->refs == 0) { g_free(read->text); g_free(read); }
}

static gboolean clipTimeout(gpointer data) {
    int *done = data;
    *done = 1;
    return G_SOURCE_REMOVE;
}

static TWChar *readClipboard(GdkClipboard *clipboard) {
    if (!clipboard) return NULL;
    ClipRead *read = g_new0(ClipRead, 1);
    read->refs = 2;
    int timedOut = 0;
    gdk_clipboard_read_text_async(clipboard, NULL, clipReadFinished, read);
    guint timer = g_timeout_add(2000, clipTimeout, &timedOut);
    while (!read->done && !timedOut) g_main_context_iteration(NULL, TRUE);
    if (!timedOut) g_source_remove(timer);
    TWChar *out = read->done && read->text ? tw_utf16(read->text) : NULL;
    if (--read->refs == 0) { g_free(read->text); g_free(read); }
    return out;
}

static int writeClipboard(GdkClipboard *clipboard, const TWChar *text, int len) {
    if (!clipboard || !text || len < 0) return 0;
    char *s = tw_utf8(text, len);
    if (!s) return 0;
    gdk_clipboard_set_text(clipboard, s);
    g_free(s);
    return 1;
}

int tw_clipboard_set_text(TWWindowHandle owner, const TWChar *text, int len) {
    (void)owner;
    GdkDisplay *d = gdk_display_get_default();
    return d ? writeClipboard(gdk_display_get_clipboard(d), text, len) : 0;
}

TWChar *tw_clipboard_get_text(TWWindowHandle owner) {
    (void)owner;
    GdkDisplay *d = gdk_display_get_default();
    return d ? readClipboard(gdk_display_get_clipboard(d)) : NULL;
}

int tw_selection_set_text(TWWindowHandle owner, const TWChar *text, int len) {
    (void)owner;
    GdkDisplay *d = gdk_display_get_default();
    return d ? writeClipboard(gdk_display_get_primary_clipboard(d), text, len) : 0;
}

TWChar *tw_selection_get_text(TWWindowHandle owner) {
    (void)owner;
    GdkDisplay *d = gdk_display_get_default();
    return d ? readClipboard(gdk_display_get_primary_clipboard(d)) : NULL;
}

// ------------------------------------------------------------------------------------ shell

int tw_shell_open(const TWChar *target) {
    char *s = tw_utf8(target, -1);
    if (!s) return 0;
    char *uri = g_path_is_absolute(s) ? g_filename_to_uri(s, NULL, NULL) : g_strdup(s);
    gboolean ok = uri ? g_app_info_launch_default_for_uri(uri, NULL, NULL) : FALSE;
    g_free(uri);
    g_free(s);
    return ok ? 1 : 0;
}

int tw_shell_reveal(const TWChar *folder, const TWChar *file) {
    (void)file;
    return tw_shell_open(folder);
}

// ---------------------------------------------------------------------------------- dialogs

typedef struct {
    int response;
    int done;
} DialogWait;

static void dialogResponded(GtkDialog *dialog, int response, gpointer data) {
    (void)dialog;
    DialogWait *wait = data;
    wait->response = response;
    wait->done = 1;
}

static void nativeResponded(GtkNativeDialog *dialog, int response, gpointer data) {
    (void)dialog;
    DialogWait *wait = data;
    wait->response = response;
    wait->done = 1;
}

int tw_file_dialog(TWWindowHandle owner, int save, int pickFolder, const TWChar *title, const TWChar *filterName,
                   const TWChar *filterSpec, const TWChar *defaultName, const TWChar *defaultExtension,
                   const TWChar *initialFolder, TWChar *out, int capacity) {
    (void)defaultExtension;
    if (!out || capacity <= 0) return 0;
    char *titleUtf8 = tw_utf8(title, -1);
    GtkFileChooserAction action = pickFolder ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
                                 : save ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN;
    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(titleUtf8 ? titleUtf8 : "", tw_parent(owner), action,
                                                               save ? "_Save" : pickFolder ? "_Choose" : "_Open", "_Cancel");
    g_free(titleUtf8);
    gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog), TRUE);
    GtkFileChooser *chooser = GTK_FILE_CHOOSER(dialog);
    if (filterName && filterSpec && !pickFolder) {
        char *name = tw_utf8(filterName, -1), *spec = tw_utf8(filterSpec, -1);
        GtkFileFilter *filter = gtk_file_filter_new();
        gtk_file_filter_set_name(filter, name);
        gtk_file_filter_add_pattern(filter, spec);
        gtk_file_chooser_add_filter(chooser, filter);
        GtkFileFilter *all = gtk_file_filter_new();
        gtk_file_filter_set_name(all, "All files");
        gtk_file_filter_add_pattern(all, "*");
        gtk_file_chooser_add_filter(chooser, all);
        g_free(name);
        g_free(spec);
    }
    if (save && defaultName) {
        char *name = tw_utf8(defaultName, -1);
        gtk_file_chooser_set_current_name(chooser, name);
        g_free(name);
    }
    if (initialFolder) {
        char *folder = tw_utf8(initialFolder, -1);
        GFile *f = g_file_new_for_path(folder);
        gtk_file_chooser_set_current_folder(chooser, f, NULL);
        g_object_unref(f);
        g_free(folder);
    }
    DialogWait wait = {GTK_RESPONSE_CANCEL, 0};
    g_signal_connect(dialog, "response", G_CALLBACK(nativeResponded), &wait);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
    while (!wait.done) g_main_context_iteration(NULL, TRUE);
    int result = 0;
    if (wait.response == GTK_RESPONSE_ACCEPT) {
        GFile *file = gtk_file_chooser_get_file(chooser);
        char *path = file ? g_file_get_path(file) : NULL;
        if (path) {
            tw_write_utf16(path, out, capacity);
            result = 1;
        }
        g_free(path);
        if (file) g_object_unref(file);
    }
    g_object_unref(dialog);
    return result;
}

int tw_alert(TWWindowHandle owner, const TWChar *title, const TWChar *message, int buttons, int icon, int defaultSecond) {
    char *titleUtf8 = tw_utf8(title, -1), *messageUtf8 = tw_utf8(message, -1);
    GtkMessageType type = icon == 1 ? GTK_MESSAGE_QUESTION : icon == 2 ? GTK_MESSAGE_WARNING
                        : icon == 3 ? GTK_MESSAGE_ERROR : GTK_MESSAGE_INFO;
    GtkWidget *dialog = gtk_message_dialog_new(tw_parent(owner), GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, type,
                                               GTK_BUTTONS_NONE, "%s", titleUtf8 ? titleUtf8 : "");
    if (messageUtf8 && *messageUtf8) {
        gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s", messageUtf8);
    }
    // Win32's ids, so both hosts answer alike: 1 OK, 2 Cancel, 6 Yes, 7 No.
    int first = 1, second = 1, dismissed = 1;
    switch (buttons) {
    case 1:
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_Cancel", 2);
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_OK", 1);
        first = 1; second = 2; dismissed = 2;
        break;
    case 3:
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_Cancel", 2);
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_No", 7);
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_Yes", 6);
        first = 6; second = 7; dismissed = 2;
        break;
    case 4:
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_No", 7);
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_Yes", 6);
        first = 6; second = 7; dismissed = 7;
        break;
    default:
        gtk_dialog_add_button(GTK_DIALOG(dialog), "_OK", 1);
        break;
    }
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), defaultSecond ? second : first);
    DialogWait wait = {dismissed, 0};
    g_signal_connect(dialog, "response", G_CALLBACK(dialogResponded), &wait);
    gtk_window_present(GTK_WINDOW(dialog));
    while (!wait.done) g_main_context_iteration(NULL, TRUE);
    gtk_window_destroy(GTK_WINDOW(dialog));
    g_free(titleUtf8);
    g_free(messageUtf8);
    int r = wait.response;
    return (r == 1 || r == 2 || r == 6 || r == 7) ? r : dismissed;
}

// ---------------------------------------------------------------------------------- secrets

static const SecretSchema schema = {
    "com.termsie.app.env", SECRET_SCHEMA_NONE, {
        {"target", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {NULL, 0},
    }
};

int tw_cred_write(const TWChar *target, const TWChar *comment, const void *blob, uint32_t length) {
    char *t = tw_utf8(target, -1);
    if (!t) return 0;
    char *label = tw_utf8(comment, -1);
    char *value = g_strndup(blob ? blob : "", length);
    GError *error = NULL;
    gboolean ok = secret_password_store_sync(&schema, SECRET_COLLECTION_DEFAULT, label && *label ? label : "Termsie",
                                             value, NULL, &error, "target", t, NULL);
    if (error) {
        g_warning("Termsie: secret store: %s", error->message);
        g_error_free(error);
    }
    g_free(value);
    g_free(label);
    g_free(t);
    return ok ? 1 : 0;
}

int tw_cred_read(const TWChar *target, void **blob) {
    if (!blob) return -1;
    *blob = NULL;
    char *t = tw_utf8(target, -1);
    if (!t) return -1;
    char *value = secret_password_lookup_sync(&schema, NULL, NULL, "target", t, NULL);
    g_free(t);
    if (!value) return -1;
    size_t n = strlen(value);
    *blob = malloc(n > 0 ? n : 1);
    memcpy(*blob, value, n);
    secret_password_free(value);
    return (int)n;
}

int tw_cred_delete(const TWChar *target) {
    char *t = tw_utf8(target, -1);
    if (!t) return 0;
    gboolean ok = secret_password_clear_sync(&schema, NULL, NULL, "target", t, NULL);
    g_free(t);
    return ok ? 1 : 0;
}
