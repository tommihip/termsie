// Forms: labelled rows of GTK controls and a row of buttons, the Linux side of the settings
// dialogs. The Swift side describes the fields and reads them back by key.

#include "Internal.h"

#include <stdlib.h>
#include <string.h>

enum { KIND_HEADING, KIND_NOTE, KIND_TEXT, KIND_MULTILINE, KIND_CHECK, KIND_CHOICE, KIND_COMBO, KIND_BUTTON };

struct TWControl {
    GtkWidget *widget;
    GtkWidget *label;
    GtkWidget *accessory;
    char *key;
    int kind;
    struct TWForm *form;
};

struct TWForm {
    GtkWidget *window;      // first, as TWNative
    GtkWidget *grid;
    GtkWidget *buttons;
    int row;
    TWFormCallbacks cb;
    GPtrArray *controls;
    int done;
    int suppress;           // programmatic changes are not the user's
};

static void addLabel(struct TWForm *f, struct TWControl *c, const TWChar *text) {
    char *t = tw_utf8(text, -1);
    c->label = gtk_label_new(t ? t : "");
    g_free(t);
    gtk_label_set_xalign(GTK_LABEL(c->label), 0);
    gtk_label_set_wrap(GTK_LABEL(c->label), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(c->label), 28);
    gtk_widget_set_valign(c->label, GTK_ALIGN_START);
    gtk_widget_set_margin_top(c->label, 4);
    gtk_grid_attach(GTK_GRID(f->grid), c->label, 0, f->row, 1, 1);
}

static struct TWControl *newControl(struct TWForm *f, const char *key, int kind) {
    struct TWControl *c = g_new0(struct TWControl, 1);
    c->key = g_strdup(key ? key : "");
    c->kind = kind;
    c->form = f;
    g_ptr_array_add(f->controls, c);
    return c;
}

static void accessoryClicked(GtkButton *button, gpointer data) {
    (void)button;
    struct TWControl *c = data;
    if (c->form->cb.accessory) c->form->cb.accessory(c->form->cb.context, c->key);
}

static void choiceChanged(GObject *dropdown, GParamSpec *spec, gpointer data) {
    (void)dropdown; (void)spec;
    struct TWControl *c = data;
    if (c->form->suppress) return;
    if (c->form->cb.selection_changed) c->form->cb.selection_changed(c->form->cb.context, c->key);
}

static void actionClicked(GtkButton *button, gpointer data) {
    struct TWForm *f = data;
    int id = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "tw-id"));
    if (f->cb.button) f->cb.button(f->cb.context, id);
}

static gboolean formCloseRequested(GtkWindow *window, gpointer data) {
    (void)window;
    struct TWForm *f = data;
    if (f->cb.close_request) f->cb.close_request(f->cb.context);
    // The Swift side hides or finishes the form itself; GTK never destroys it on its own.
    return TRUE;
}

static GtkStringList *stringList(const TWChar *options) {
    GtkStringList *list = gtk_string_list_new(NULL);
    if (!options) return list;
    const TWChar *p = options;
    while (*p) {
        int n = 0;
        while (p[n]) n++;
        char *s = tw_utf8(p, n);
        gtk_string_list_append(list, s ? s : "");
        g_free(s);
        p += n + 1;
    }
    return list;
}

TWForm *tw_form_create(TWWindowHandle owner, const TWChar *title, int resizable, const TWFormCallbacks *callbacks) {
    struct TWForm *f = g_new0(struct TWForm, 1);
    if (callbacks) f->cb = *callbacks;
    f->controls = g_ptr_array_new();
    f->window = gtk_window_new();
    char *t = tw_utf8(title, -1);
    gtk_window_set_title(GTK_WINDOW(f->window), t ? t : "");
    g_free(t);
    GtkWindow *parent = tw_parent(owner);
    if (parent) gtk_window_set_transient_for(GTK_WINDOW(f->window), parent);
    gtk_window_set_resizable(GTK_WINDOW(f->window), resizable ? TRUE : FALSE);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(f->window), TRUE);
    g_signal_connect(f->window, "close-request", G_CALLBACK(formCloseRequested), f);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(box, 14);
    gtk_widget_set_margin_bottom(box, 14);
    gtk_widget_set_margin_start(box, 14);
    gtk_widget_set_margin_end(box, 14);
    f->grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(f->grid), 6);
    gtk_grid_set_column_spacing(GTK_GRID(f->grid), 12);
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroller), TRUE);
    gtk_scrolled_window_set_propagate_natural_width(GTK_SCROLLED_WINDOW(scroller), TRUE);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroller), 760);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), f->grid);
    gtk_widget_set_vexpand(scroller, TRUE);
    gtk_box_append(GTK_BOX(box), scroller);
    f->buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(f->buttons, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(box), f->buttons);
    gtk_window_set_child(GTK_WINDOW(f->window), box);
    return f;
}

void tw_form_destroy(TWForm *f) {
    if (!f) return;
    if (f->window) gtk_window_destroy(GTK_WINDOW(f->window));
    for (guint i = 0; i < f->controls->len; i++) {
        struct TWControl *c = g_ptr_array_index(f->controls, i);
        g_free(c->key);
        g_free(c);
    }
    g_ptr_array_free(f->controls, TRUE);
    g_free(f);
}

TWControl *tw_form_add_heading(TWForm *f, const char *key, const TWChar *text) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_HEADING);
    char *t = tw_utf8(text, -1);
    c->widget = gtk_label_new(NULL);
    char *markup = g_markup_printf_escaped("<b>%s</b>", t ? t : "");
    gtk_label_set_markup(GTK_LABEL(c->widget), markup);
    g_free(markup);
    g_free(t);
    gtk_label_set_xalign(GTK_LABEL(c->widget), 0);
    gtk_widget_set_margin_top(c->widget, 6);
    gtk_grid_attach(GTK_GRID(f->grid), c->widget, 0, f->row++, 3, 1);
    return c;
}

TWControl *tw_form_add_note(TWForm *f, const char *key, const TWChar *text) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_NOTE);
    char *t = tw_utf8(text, -1);
    c->widget = gtk_label_new(t ? t : "");
    g_free(t);
    gtk_label_set_xalign(GTK_LABEL(c->widget), 0);
    gtk_label_set_wrap(GTK_LABEL(c->widget), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(c->widget), 60);
    gtk_widget_add_css_class(c->widget, "dim-label");
    gtk_grid_attach(GTK_GRID(f->grid), c->widget, 1, f->row++, 2, 1);
    return c;
}

TWControl *tw_form_add_text(TWForm *f, const char *key, const TWChar *label, const TWChar *value, const TWChar *accessory) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_TEXT);
    addLabel(f, c, label);
    c->widget = gtk_entry_new();
    char *v = tw_utf8(value, -1);
    gtk_editable_set_text(GTK_EDITABLE(c->widget), v ? v : "");
    g_free(v);
    gtk_widget_set_hexpand(c->widget, TRUE);
    gtk_widget_set_size_request(c->widget, 360, -1);
    gtk_grid_attach(GTK_GRID(f->grid), c->widget, 1, f->row, accessory ? 1 : 2, 1);
    if (accessory) {
        char *a = tw_utf8(accessory, -1);
        c->accessory = gtk_button_new_with_label(a ? a : "");
        g_free(a);
        g_signal_connect(c->accessory, "clicked", G_CALLBACK(accessoryClicked), c);
        gtk_grid_attach(GTK_GRID(f->grid), c->accessory, 2, f->row, 1, 1);
    }
    f->row++;
    return c;
}

TWControl *tw_form_add_multiline(TWForm *f, const char *key, const TWChar *label, const TWChar *value, int lines, int monospace) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_MULTILINE);
    if (label && *label) addLabel(f, c, label);
    c->widget = gtk_text_view_new();
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(c->widget), monospace ? TRUE : FALSE);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(c->widget), 4);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(c->widget), 6);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(c->widget), 6);
    char *v = tw_utf8(value, -1);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(c->widget)), v ? v : "", -1);
    g_free(v);
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), c->widget);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), monospace ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER,
                                   GTK_POLICY_AUTOMATIC);
    gtk_widget_add_css_class(scroller, "frame");
    gtk_widget_set_size_request(scroller, 360, (lines > 0 ? lines : 3) * 18 + 10);
    gtk_widget_set_hexpand(scroller, TRUE);
    c->accessory = scroller;   // what gets hidden with the control
    gtk_grid_attach(GTK_GRID(f->grid), scroller, label && *label ? 1 : 0, f->row++, label && *label ? 2 : 3, 1);
    return c;
}

TWControl *tw_form_add_check(TWForm *f, const char *key, const TWChar *label, int on) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_CHECK);
    addLabel(f, c, label);
    c->widget = gtk_check_button_new();
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c->widget), on ? TRUE : FALSE);
    gtk_grid_attach(GTK_GRID(f->grid), c->widget, 1, f->row++, 2, 1);
    return c;
}

TWControl *tw_form_add_choice(TWForm *f, const char *key, const TWChar *label, const TWChar *options, int selected) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_CHOICE);
    addLabel(f, c, label);
    GtkStringList *list = stringList(options);
    c->widget = gtk_drop_down_new(G_LIST_MODEL(list), NULL);
    if (selected >= 0) gtk_drop_down_set_selected(GTK_DROP_DOWN(c->widget), (guint)selected);
    g_signal_connect(c->widget, "notify::selected", G_CALLBACK(choiceChanged), c);
    gtk_widget_set_hexpand(c->widget, TRUE);
    gtk_grid_attach(GTK_GRID(f->grid), c->widget, 1, f->row++, 2, 1);
    return c;
}

TWControl *tw_form_add_combo(TWForm *f, const char *key, const TWChar *label, const TWChar *options, const TWChar *text) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_COMBO);
    addLabel(f, c, label);
    c->widget = gtk_combo_box_text_new_with_entry();
    const TWChar *p = options;
    while (p && *p) {
        int n = 0;
        while (p[n]) n++;
        char *s = tw_utf8(p, n);
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(c->widget), s ? s : "");
        g_free(s);
        p += n + 1;
    }
    char *t = tw_utf8(text, -1);
    GtkWidget *entry = gtk_combo_box_get_child(GTK_COMBO_BOX(c->widget));
    if (entry) gtk_editable_set_text(GTK_EDITABLE(entry), t ? t : "");
    g_free(t);
    gtk_widget_set_hexpand(c->widget, TRUE);
    gtk_grid_attach(GTK_GRID(f->grid), c->widget, 1, f->row++, 2, 1);
    return c;
}

TWControl *tw_form_add_button(TWForm *f, const char *key, const TWChar *title) {
    if (!f) return NULL;
    struct TWControl *c = newControl(f, key, KIND_BUTTON);
    char *t = tw_utf8(title, -1);
    c->widget = gtk_button_new_with_label(t ? t : "");
    g_free(t);
    gtk_widget_set_halign(c->widget, GTK_ALIGN_START);
    g_signal_connect(c->widget, "clicked", G_CALLBACK(accessoryClicked), c);
    gtk_grid_attach(GTK_GRID(f->grid), c->widget, 1, f->row++, 2, 1);
    return c;
}

void tw_form_add_action(TWForm *f, int id, const TWChar *title, int isDefault) {
    if (!f) return;
    char *t = tw_utf8(title, -1);
    GtkWidget *button = gtk_button_new_with_label(t ? t : "");
    g_free(t);
    g_object_set_data(G_OBJECT(button), "tw-id", GINT_TO_POINTER(id));
    g_signal_connect(button, "clicked", G_CALLBACK(actionClicked), f);
    gtk_widget_set_size_request(button, 96, -1);
    gtk_box_append(GTK_BOX(f->buttons), button);
    if (isDefault) {
        gtk_widget_add_css_class(button, "suggested-action");
        gtk_window_set_default_widget(GTK_WINDOW(f->window), button);
    }
}

void tw_form_present(TWForm *f, int modal) {
    if (!f || !f->window) return;
    gtk_window_set_modal(GTK_WINDOW(f->window), modal ? TRUE : FALSE);
    gtk_window_present(GTK_WINDOW(f->window));
    if (!modal) return;
    f->done = 0;
    while (!f->done) g_main_context_iteration(NULL, TRUE);
}

void tw_form_finish(TWForm *f) {
    if (!f) return;
    f->done = 1;
    tw_form_hide(f);
}

void tw_form_hide(TWForm *f) {
    if (f && f->window) gtk_widget_set_visible(f->window, FALSE);
}

int tw_form_is_visible(TWForm *f) {
    return f && f->window && gtk_widget_get_visible(f->window);
}

static GtkWidget *entryOf(struct TWControl *c) {
    if (c->kind == KIND_COMBO) return gtk_combo_box_get_child(GTK_COMBO_BOX(c->widget));
    return c->widget;
}

TWChar *tw_control_get_text(TWControl *c) {
    if (!c || !c->widget) return NULL;
    switch (c->kind) {
    case KIND_TEXT:
    case KIND_COMBO: {
        GtkWidget *entry = entryOf(c);
        return tw_utf16(entry ? gtk_editable_get_text(GTK_EDITABLE(entry)) : "");
    }
    case KIND_MULTILINE: {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(c->widget));
        GtkTextIter start, end;
        gtk_text_buffer_get_bounds(buffer, &start, &end);
        char *s = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
        TWChar *out = tw_utf16(s);
        g_free(s);
        return out;
    }
    case KIND_NOTE:
    case KIND_HEADING:
        return tw_utf16(gtk_label_get_text(GTK_LABEL(c->widget)));
    case KIND_BUTTON:
        return tw_utf16(gtk_button_get_label(GTK_BUTTON(c->widget)));
    default:
        return tw_utf16("");
    }
}

void tw_control_set_text(TWControl *c, const TWChar *text) {
    if (!c || !c->widget) return;
    char *s = tw_utf8(text, -1);
    const char *v = s ? s : "";
    switch (c->kind) {
    case KIND_TEXT:
    case KIND_COMBO: {
        GtkWidget *entry = entryOf(c);
        if (entry) gtk_editable_set_text(GTK_EDITABLE(entry), v);
        break;
    }
    case KIND_MULTILINE:
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(c->widget)), v, -1);
        break;
    case KIND_NOTE:
        gtk_label_set_text(GTK_LABEL(c->widget), v);
        break;
    case KIND_HEADING: {
        char *markup = g_markup_printf_escaped("<b>%s</b>", v);
        gtk_label_set_markup(GTK_LABEL(c->widget), markup);
        g_free(markup);
        break;
    }
    case KIND_BUTTON:
        gtk_button_set_label(GTK_BUTTON(c->widget), v);
        break;
    default:
        break;
    }
    g_free(s);
}

int tw_control_get_checked(TWControl *c) {
    return c && c->kind == KIND_CHECK && gtk_check_button_get_active(GTK_CHECK_BUTTON(c->widget));
}

void tw_control_set_checked(TWControl *c, int on) {
    if (c && c->kind == KIND_CHECK) gtk_check_button_set_active(GTK_CHECK_BUTTON(c->widget), on ? TRUE : FALSE);
}

int tw_control_get_selection(TWControl *c) {
    if (!c) return -1;
    if (c->kind == KIND_CHOICE) {
        guint i = gtk_drop_down_get_selected(GTK_DROP_DOWN(c->widget));
        return i == GTK_INVALID_LIST_POSITION ? -1 : (int)i;
    }
    if (c->kind == KIND_COMBO) return gtk_combo_box_get_active(GTK_COMBO_BOX(c->widget));
    return -1;
}

void tw_control_set_selection(TWControl *c, int index) {
    if (!c) return;
    c->form->suppress++;
    if (c->kind == KIND_CHOICE) gtk_drop_down_set_selected(GTK_DROP_DOWN(c->widget), index < 0 ? 0 : (guint)index);
    else if (c->kind == KIND_COMBO) gtk_combo_box_set_active(GTK_COMBO_BOX(c->widget), index);
    c->form->suppress--;
}

void tw_control_set_options(TWControl *c, const TWChar *options, int selected) {
    if (!c) return;
    c->form->suppress++;
    if (c->kind == KIND_CHOICE) {
        GtkStringList *list = stringList(options);
        gtk_drop_down_set_model(GTK_DROP_DOWN(c->widget), G_LIST_MODEL(list));
        g_object_unref(list);
        gtk_drop_down_set_selected(GTK_DROP_DOWN(c->widget), selected < 0 ? 0 : (guint)selected);
    } else if (c->kind == KIND_COMBO) {
        gtk_combo_box_text_remove_all(GTK_COMBO_BOX_TEXT(c->widget));
        const TWChar *p = options;
        while (p && *p) {
            int n = 0;
            while (p[n]) n++;
            char *s = tw_utf8(p, n);
            gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(c->widget), s ? s : "");
            g_free(s);
            p += n + 1;
        }
        gtk_combo_box_set_active(GTK_COMBO_BOX(c->widget), selected);
    }
    c->form->suppress--;
}

void tw_control_set_visible(TWControl *c, int visible) {
    if (!c) return;
    gboolean v = visible ? TRUE : FALSE;
    if (c->widget) gtk_widget_set_visible(c->widget, v);
    if (c->label) gtk_widget_set_visible(c->label, v);
    if (c->accessory) gtk_widget_set_visible(c->accessory, v);
}

void tw_control_set_enabled(TWControl *c, int enabled) {
    if (c && c->widget) gtk_widget_set_sensitive(c->widget, enabled ? TRUE : FALSE);
}

void tw_control_focus(TWControl *c, int selectAll) {
    if (!c || !c->widget) return;
    GtkWidget *entry = entryOf(c);
    if (!entry) return;
    gtk_widget_grab_focus(entry);
    if (selectAll && GTK_IS_EDITABLE(entry)) gtk_editable_select_region(GTK_EDITABLE(entry), 0, -1);
}
