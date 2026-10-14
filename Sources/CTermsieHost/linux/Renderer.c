// Cairo and Pango on a GtkDrawingArea.
//
// The drawing area hands its cairo context to the draw callback, so a frame can only be drawn
// from there: `tw_renderer_begin` picks that context up and fails outside it, and the Swift side
// asks the window to redraw instead. Snapshots draw into an image surface and work any time.
//
// Terminal text is shaped with Pango, item by item (which is where fontconfig's fallback for
// characters the font lacks comes in), and then every cluster's advance is forced to its cells,
// so a grid stays a grid however the font's own advances round.

#include "Internal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// ------------------------------------------------------------------------------------- fonts

struct TWFont {
    PangoFontDescription *desc;
    char *family;
    float size;                        // DIPs
    float ascent, descent, height;     // DIPs at 96 dpi
    float advance;                     // the cell, DIPs
    float underlinePosition, underlineThickness;
};

static PangoContext *pangoContext(void) {
    static PangoContext *ctx;
    if (!ctx) {
        ctx = pango_font_map_create_context(pango_cairo_font_map_get_default());
        pango_cairo_context_set_resolution(ctx, 96);
    }
    return ctx;
}

/// Family names, lower-cased, with whether they are monospaced.
static GHashTable *families(void) {
    static GHashTable *table;
    if (table) return table;
    table = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    PangoFontFamily **list = NULL;
    int n = 0;
    pango_font_map_list_families(pango_cairo_font_map_get_default(), &list, &n);
    for (int i = 0; i < n; i++) {
        const char *name = pango_font_family_get_name(list[i]);
        if (!name || !*name) continue;
        char *entry = g_strdup_printf("%c%s", pango_font_family_is_monospace(list[i]) ? 'm' : 'p', name);
        g_hash_table_insert(table, g_utf8_strdown(name, -1), entry);
    }
    g_free(list);
    return table;
}

static const char *lookupFamily(const char *name) {
    if (!name || !*name) return NULL;
    char *key = g_utf8_strdown(name, -1);
    const char *entry = g_hash_table_lookup(families(), key);
    g_free(key);
    return entry ? entry + 1 : NULL;
}

int tw_font_family_exists(const TWChar *family) {
    char *name = tw_utf8(family, -1);
    int found = lookupFamily(name) != NULL;
    g_free(name);
    return found;
}

static int compareNames(gconstpointer a, gconstpointer b) {
    return g_utf8_collate(*(const char *const *)a, *(const char *const *)b);
}

int tw_font_families(TWChar *out, int outChars, int monospacedOnly) {
    if (!out || outChars <= 0) return 0;
    GPtrArray *names = g_ptr_array_new();
    GHashTableIter it;
    gpointer key, value;
    g_hash_table_iter_init(&it, families());
    while (g_hash_table_iter_next(&it, &key, &value)) {
        const char *entry = value;
        if (monospacedOnly && entry[0] != 'm') continue;
        g_ptr_array_add(names, (gpointer)(entry + 1));
    }
    g_ptr_array_sort(names, compareNames);
    int written = 0, used = 0;
    for (guint i = 0; i < names->len; i++) {
        const char *name = g_ptr_array_index(names, i);
        glong n = 0;
        gunichar2 *u = g_utf8_to_utf16(name, -1, NULL, &n, NULL);
        if (!u) continue;
        if (used + n + 1 >= outChars) { g_free(u); break; }
        memcpy(out + used, u, n * sizeof(TWChar));
        used += n;
        out[used++] = 0;
        written++;
        g_free(u);
    }
    if (used < outChars) out[used] = 0;
    g_ptr_array_free(names, TRUE);
    return written;
}

TWFont *tw_font_create(const TWChar *family, float sizeDIP, int weight, int italic) {
    char *requested = tw_utf8(family, -1);
    const char *chosen = lookupFamily(requested);
    // fontconfig's aliases always resolve, whatever is installed.
    if (!chosen) chosen = (requested && g_str_has_prefix(requested, "mono")) ? "monospace" : requested && *requested ? requested : "monospace";
    TWFont *f = calloc(1, sizeof *f);
    f->family = g_strdup(chosen);
    f->size = sizeDIP > 1 ? sizeDIP : 1;
    f->desc = pango_font_description_new();
    pango_font_description_set_family(f->desc, chosen);
    pango_font_description_set_weight(f->desc, weight >= 600 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
    pango_font_description_set_style(f->desc, italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    pango_font_description_set_absolute_size(f->desc, f->size * PANGO_SCALE);
    g_free(requested);

    PangoContext *ctx = pangoContext();
    PangoFont *font = pango_font_map_load_font(pango_context_get_font_map(ctx), ctx, f->desc);
    if (font) {
        PangoFontMetrics *m = pango_font_get_metrics(font, NULL);
        f->ascent = pango_font_metrics_get_ascent(m) / (float)PANGO_SCALE;
        f->descent = pango_font_metrics_get_descent(m) / (float)PANGO_SCALE;
        int height = pango_font_metrics_get_height(m);
        f->height = height > 0 ? height / (float)PANGO_SCALE : f->ascent + f->descent;
        f->underlinePosition = pango_font_metrics_get_underline_position(m) / (float)PANGO_SCALE;
        f->underlineThickness = pango_font_metrics_get_underline_thickness(m) / (float)PANGO_SCALE;
        pango_font_metrics_unref(m);
        g_object_unref(font);
    } else {
        f->ascent = f->size * 0.8f;
        f->descent = f->size * 0.2f;
        f->height = f->size * 1.2f;
        f->underlinePosition = -f->size * 0.1f;
        f->underlineThickness = 1;
    }
    // The advance of a wide, ordinary glyph defines the cell.
    PangoLayout *layout = pango_layout_new(ctx);
    pango_layout_set_font_description(layout, f->desc);
    const char *probes[] = {"M", "0"};
    float advance = 0;
    for (int i = 0; i < 2; i++) {
        pango_layout_set_text(layout, probes[i], -1);
        PangoRectangle ink, logical;
        pango_layout_get_extents(layout, &ink, &logical);
        float w = logical.width / (float)PANGO_SCALE;
        if (w > advance) advance = w;
    }
    g_object_unref(layout);
    f->advance = advance > 0 ? advance : f->size * 0.6f;
    return f;
}

void tw_font_destroy(TWFont *f) {
    if (!f) return;
    if (f->desc) pango_font_description_free(f->desc);
    g_free(f->family);
    free(f);
}

void tw_font_metrics(TWFont *f, float dpi, TWFontMetrics *out) {
    if (!f || !out) return;
    float px = (dpi > 0 ? dpi : 96) / 96.0f;
    float gap = f->height - f->ascent - f->descent;
    if (gap < 0) gap = 0;
    out->cellWidth = fmaxf(1.0f, roundf(f->advance * px)) / px;
    out->cellHeight = fmaxf(1.0f, roundf((f->ascent + f->descent + gap) * px)) / px;
    out->baseline = roundf((f->ascent + gap / 2) * px) / px;
    // Pango's underline position is the distance above the baseline, negative for below.
    out->underlinePosition = out->baseline - f->underlinePosition;
    out->underlineThickness = fmaxf(1.0f / px, f->underlineThickness);
}

// ---------------------------------------------------------------------------------- renderer

struct TWRenderer {
    struct TWWindow *window;
    cairo_t *cr;
    cairo_surface_t *snapshot;
    unsigned width, height;
    float dpi;
    int drawing, snapshotting;
};

TWRenderer *tw_renderer_create(TWWindowHandle window) {
    TWRenderer *r = calloc(1, sizeof *r);
    r->window = window;
    r->dpi = 96;
    return r;
}

void tw_renderer_destroy(TWRenderer *r) {
    if (!r) return;
    if (r->snapshot) cairo_surface_destroy(r->snapshot);
    free(r);
}

void tw_renderer_resize(TWRenderer *r, unsigned width, unsigned height, float dpi) {
    if (!r) return;
    r->width = width;
    r->height = height;
    r->dpi = dpi > 0 ? dpi : 96;
}

int tw_renderer_begin(TWRenderer *r) {
    if (!r || r->drawing || !r->window || !r->window->cr) return 0;
    r->cr = r->window->cr;
    cairo_save(r->cr);
    r->drawing = 1;
    return 1;
}

int tw_renderer_end(TWRenderer *r) {
    if (!r || !r->drawing || r->snapshotting) return 1;
    cairo_restore(r->cr);
    r->cr = NULL;
    r->drawing = 0;
    return 1;
}

int tw_snapshot_begin(TWRenderer *r, unsigned width, unsigned height, float dpi) {
    if (!r || r->drawing) return 0;
    if (r->snapshot) cairo_surface_destroy(r->snapshot);
    r->snapshot = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width > 0 ? width : 1, height > 0 ? height : 1);
    r->cr = cairo_create(r->snapshot);
    float s = (dpi > 0 ? dpi : 96) / 96.0f;
    cairo_scale(r->cr, s, s);
    r->drawing = 1;
    r->snapshotting = 1;
    return 1;
}

int tw_snapshot_end(TWRenderer *r, const TWChar *pngPath) {
    if (!r || !r->snapshotting) return 0;
    cairo_destroy(r->cr);
    r->cr = NULL;
    r->drawing = 0;
    r->snapshotting = 0;
    char *path = tw_utf8(pngPath, -1);
    cairo_status_t status = path ? cairo_surface_write_to_png(r->snapshot, path) : CAIRO_STATUS_WRITE_ERROR;
    g_free(path);
    cairo_surface_destroy(r->snapshot);
    r->snapshot = NULL;
    return status == CAIRO_STATUS_SUCCESS;
}

// ---------------------------------------------------------------------------------- drawing

static void setColor(cairo_t *cr, TWColor c) {
    cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a);
}

static void roundedRect(cairo_t *cr, double x, double y, double w, double h, double radius) {
    double r = fmin(radius, fmin(w, h) / 2);
    if (r <= 0.25) {
        cairo_rectangle(cr, x, y, w, h);
        return;
    }
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
    cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

void tw_clear(TWRenderer *r, TWColor c) {
    if (!r || !r->drawing) return;
    cairo_save(r->cr);
    cairo_set_operator(r->cr, CAIRO_OPERATOR_SOURCE);
    setColor(r->cr, c);
    cairo_paint(r->cr);
    cairo_restore(r->cr);
}

void tw_fill_rect(TWRenderer *r, float x, float y, float w, float h, TWColor c) {
    if (!r || !r->drawing || w <= 0 || h <= 0 || c.a <= 0) return;
    setColor(r->cr, c);
    cairo_rectangle(r->cr, x, y, w, h);
    cairo_fill(r->cr);
}

void tw_fill_rounded_rect(TWRenderer *r, float x, float y, float w, float h, float radius, TWColor c) {
    if (!r || !r->drawing || w <= 0 || h <= 0 || c.a <= 0) return;
    setColor(r->cr, c);
    roundedRect(r->cr, x, y, w, h, radius);
    cairo_fill(r->cr);
}

void tw_stroke_rect(TWRenderer *r, float x, float y, float w, float h, float width, TWColor c) {
    if (!r || !r->drawing || c.a <= 0) return;
    setColor(r->cr, c);
    cairo_set_line_width(r->cr, width);
    cairo_rectangle(r->cr, x, y, w, h);
    cairo_stroke(r->cr);
}

void tw_stroke_rounded_rect(TWRenderer *r, float x, float y, float w, float h, float radius, float width, TWColor c) {
    if (!r || !r->drawing || c.a <= 0) return;
    setColor(r->cr, c);
    cairo_set_line_width(r->cr, width);
    roundedRect(r->cr, x, y, w, h, radius);
    cairo_stroke(r->cr);
}

void tw_draw_line(TWRenderer *r, float x1, float y1, float x2, float y2, float width, TWColor c) {
    if (!r || !r->drawing || c.a <= 0) return;
    setColor(r->cr, c);
    cairo_set_line_width(r->cr, width);
    cairo_move_to(r->cr, x1, y1);
    cairo_line_to(r->cr, x2, y2);
    cairo_stroke(r->cr);
}

void tw_fill_ellipse(TWRenderer *r, float cx, float cy, float rx, float ry, TWColor c) {
    if (!r || !r->drawing || c.a <= 0 || rx <= 0 || ry <= 0) return;
    setColor(r->cr, c);
    cairo_save(r->cr);
    cairo_translate(r->cr, cx, cy);
    cairo_scale(r->cr, rx, ry);
    cairo_arc(r->cr, 0, 0, 1, 0, 2 * G_PI);
    cairo_restore(r->cr);
    cairo_fill(r->cr);
}

void tw_draw_shadow(TWRenderer *r, float x, float y, float w, float h, float radius, float spread, float opacity) {
    if (!r || !r->drawing || spread <= 0 || opacity <= 0) return;
    // Concentric outlines fading outward approximate a Gaussian shadow at a fraction of the cost
    // of blurring the pane into a bitmap first.
    int steps = (int)fminf(12.0f, fmaxf(3.0f, spread / 1.5f));
    for (int i = steps; i >= 1; i--) {
        float t = (float)i / steps;
        float grow = spread * t;
        float alpha = opacity * (1 - t) * (1 - t) * 0.35f;
        TWColor c = {0, 0, 0, alpha};
        tw_fill_rounded_rect(r, x - grow, y - grow * 0.6f, w + 2 * grow, h + 2 * grow, radius + grow, c);
    }
}

void tw_push_clip(TWRenderer *r, float x, float y, float w, float h) {
    if (!r || !r->drawing) return;
    cairo_save(r->cr);
    cairo_rectangle(r->cr, x, y, fmaxf(0, w), fmaxf(0, h));
    cairo_clip(r->cr);
}

void tw_pop_clip(TWRenderer *r) {
    if (r && r->drawing) cairo_restore(r->cr);
}

void tw_push_rounded_clip(TWRenderer *r, float x, float y, float w, float h, float radius) {
    if (!r || !r->drawing) return;
    cairo_save(r->cr);
    roundedRect(r->cr, x, y, fmaxf(0, w), fmaxf(0, h), radius);
    cairo_clip(r->cr);
}

void tw_pop_rounded_clip(TWRenderer *r) {
    if (r && r->drawing) cairo_restore(r->cr);
}

// ------------------------------------------------------------------------------------- text

/// One code point of a run: where it starts in the UTF-8 text and on the grid.
typedef struct {
    int byteOffset;
    float column;
    int cells;
} CellPoint;

void tw_draw_cells(TWRenderer *r, TWFont *f, const TWChar *text, int len, const uint8_t *cells, float x, float y,
                   float cellWidth, float cellHeight, float baseline, TWColor c) {
    if (!r || !r->drawing || !f || !text || len <= 0 || c.a <= 0) return;
    (void)cellHeight;

    GString *utf8 = g_string_new(NULL);
    GArray *points = g_array_new(FALSE, FALSE, sizeof(CellPoint));
    float column = 0;
    for (int i = 0; i < len; i++) {
        gunichar cp = text[i];
        int units = 1;
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len && text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (text[i + 1] - 0xDC00);
            units = 2;
        }
        // 0 is a combining mark: drawn over the previous cell, advancing nothing.
        int width = cells ? cells[i] : 1;
        CellPoint p = {(int)utf8->len, column, width};
        g_array_append_val(points, p);
        g_string_append_unichar(utf8, cp);
        column += width;
        i += units - 1;
    }
    // Which code point starts at each byte, and the column reached at each byte.
    int *pointAtByte = g_new(int, utf8->len + 1);
    float *columnAtByte = g_new(float, utf8->len + 1);
    for (gsize b = 0; b <= utf8->len; b++) { pointAtByte[b] = -1; columnAtByte[b] = column; }
    for (guint i = 0; i < points->len; i++) {
        CellPoint *p = &g_array_index(points, CellPoint, i);
        pointAtByte[p->byteOffset] = (int)i;
        columnAtByte[p->byteOffset] = p->column;
    }

    float px = r->dpi / 96.0f;
    PangoContext *ctx = pangoContext();
    PangoAttrList *attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_font_desc_new(f->desc));
    GList *items = pango_itemize(ctx, utf8->str, 0, (int)utf8->len, attrs, NULL);
    setColor(r->cr, c);

    for (GList *l = items; l; l = l->next) {
        PangoItem *item = l->data;
        PangoGlyphString *glyphs = pango_glyph_string_new();
        pango_shape_full(utf8->str + item->offset, item->length, utf8->str, (int)utf8->len, &item->analysis, glyphs);

        // Pin every cluster to its cells: the cluster's glyphs keep their natural positions
        // relative to each other, centred in the cells, and the cluster as a whole advances by
        // exactly its cell width.
        int n = glyphs->num_glyphs;
        int i = 0;
        while (i < n) {
            int clusterByte = item->offset + glyphs->log_clusters[i];
            int j = i + 1;
            while (j < n && glyphs->log_clusters[j] == glyphs->log_clusters[i]) j++;
            int nextByte = j < n ? item->offset + glyphs->log_clusters[j] : item->offset + item->length;
            if (nextByte > (int)utf8->len) nextByte = (int)utf8->len;
            float startColumn = clusterByte <= (int)utf8->len ? columnAtByte[clusterByte] : column;
            float endColumn = columnAtByte[nextByte];
            if (endColumn < startColumn) endColumn = startColumn;
            int allotted = (int)((endColumn - startColumn) * cellWidth * PANGO_SCALE + 0.5f);
            int natural = 0;
            for (int k = i; k < j; k++) natural += glyphs->glyphs[k].geometry.width;
            int shift = (int)(roundf(((allotted - natural) / 2.0f) * px / PANGO_SCALE) * PANGO_SCALE / px);
            int cursor = 0;
            for (int k = i; k < j; k++) {
                int w = glyphs->glyphs[k].geometry.width;
                glyphs->glyphs[k].geometry.x_offset += shift + cursor;
                cursor += w;
                glyphs->glyphs[k].geometry.width = 0;
            }
            glyphs->glyphs[j - 1].geometry.width = allotted;
            i = j;
        }
        int firstByte = item->offset;
        float firstColumn = columnAtByte[firstByte];
        cairo_move_to(r->cr, x + firstColumn * cellWidth, y + baseline);
        pango_cairo_show_glyph_string(r->cr, item->analysis.font, glyphs);
        pango_glyph_string_free(glyphs);
        pango_item_free(item);
    }
    g_list_free(items);
    pango_attr_list_unref(attrs);
    g_free(pointAtByte);
    g_free(columnAtByte);
    g_array_free(points, TRUE);
    g_string_free(utf8, TRUE);
}

void tw_draw_text(TWRenderer *r, TWFont *f, const TWChar *text, int len, float x, float y, float w, float h, int align,
                  TWColor c) {
    if (!r || !r->drawing || !f || !text || len <= 0 || w <= 0 || c.a <= 0) return;
    char *s = tw_utf8(text, len);
    if (!s) return;
    PangoLayout *layout = pango_cairo_create_layout(r->cr);
    pango_layout_set_font_description(layout, f->desc);
    pango_layout_set_text(layout, s, -1);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    pango_layout_set_width(layout, (int)(w * PANGO_SCALE));
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
    pango_layout_set_alignment(layout, align == 1 ? PANGO_ALIGN_CENTER : align == 2 ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
    int textWidth = 0, textHeight = 0;
    pango_layout_get_pixel_size(layout, &textWidth, &textHeight);
    cairo_save(r->cr);
    cairo_rectangle(r->cr, x, y, w, h);
    cairo_clip(r->cr);
    setColor(r->cr, c);
    cairo_move_to(r->cr, x, y + floorf((h - textHeight) / 2));
    pango_cairo_show_layout(r->cr, layout);
    cairo_restore(r->cr);
    g_object_unref(layout);
    g_free(s);
}

float tw_measure_text(TWFont *f, const TWChar *text, int len) {
    if (!f || !text || len <= 0) return 0;
    char *s = tw_utf8(text, len);
    if (!s) return 0;
    PangoLayout *layout = pango_layout_new(pangoContext());
    pango_layout_set_font_description(layout, f->desc);
    pango_layout_set_text(layout, s, -1);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    PangoRectangle ink, logical;
    pango_layout_get_extents(layout, &ink, &logical);
    g_object_unref(layout);
    g_free(s);
    return logical.width / (float)PANGO_SCALE;
}
