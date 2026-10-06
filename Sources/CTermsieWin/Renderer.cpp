// Direct2D on a DirectComposition swap chain, and DirectWrite for text.
//
// Composition rather than a plain HWND render target, because it is the only way a Direct2D
// window can have translucent pixels: with premultiplied alpha the acrylic backdrop shows through
// wherever the terminal background is less than opaque, which is how the macOS app's opacity and
// blur settings carry over.
//
// Terminal text is drawn as DirectWrite glyph runs with every advance forced to the cell width,
// so a grid stays a grid however the font's own advances round. Characters the font lacks are
// drawn one by one through a text layout, which brings in DirectWrite's font fallback.

#include <windows.h>

#include "CTermsieWin.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <d2d1_1.h>
#include <d2d1_1helper.h>
#include <dwrite.h>
#include <dwrite_1.h>
#include <dcomp.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "dcomp.lib")
#pragma comment(lib, "windowscodecs.lib")

using Microsoft::WRL::ComPtr;

static ID2D1Factory1 *d2dFactory() {
    static ComPtr<ID2D1Factory1> factory;
    if (!factory) {
        D2D1_FACTORY_OPTIONS options = {};
        D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &options,
                          (void **)factory.GetAddressOf());
    }
    return factory.Get();
}

static IDWriteFactory *dwFactory() {
    static ComPtr<IDWriteFactory> factory;
    if (!factory) {
        DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                            (IUnknown **)factory.GetAddressOf());
    }
    return factory.Get();
}

static IDWriteFontCollection *systemFonts() {
    static ComPtr<IDWriteFontCollection> fonts;
    if (!fonts && dwFactory()) dwFactory()->GetSystemFontCollection(fonts.GetAddressOf(), FALSE);
    return fonts.Get();
}

static D2D1_COLOR_F color(TWColor c) {
    // Direct2D brushes take straight alpha and premultiply themselves.
    return D2D1::ColorF(c.r, c.g, c.b, c.a);
}

// ------------------------------------------------------------------------------------- fonts

struct TWFont {
    ComPtr<IDWriteTextFormat> format;
    ComPtr<IDWriteFontFace> face;
    std::wstring family;
    float size = 12;
    DWRITE_FONT_METRICS designMetrics = {};
    float advance = 0;  // design units
};

static ComPtr<IDWriteFont> findFont(const wchar_t *family, DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style) {
    IDWriteFontCollection *fonts = systemFonts();
    if (!fonts || !family) return nullptr;
    UINT32 index = 0;
    BOOL exists = FALSE;
    if (FAILED(fonts->FindFamilyName(family, &index, &exists)) || !exists) return nullptr;
    ComPtr<IDWriteFontFamily> fam;
    if (FAILED(fonts->GetFontFamily(index, &fam))) return nullptr;
    ComPtr<IDWriteFont> font;
    if (FAILED(fam->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, style, &font))) return nullptr;
    return font;
}

extern "C" int tw_font_family_exists(const wchar_t *family) {
    IDWriteFontCollection *fonts = systemFonts();
    if (!fonts || !family) return 0;
    UINT32 index = 0;
    BOOL exists = FALSE;
    return SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
}

extern "C" TWFont *tw_font_create(const wchar_t *family, float sizeDIP, int weight, int italic) {
    if (!dwFactory()) return nullptr;
    DWRITE_FONT_WEIGHT w = (DWRITE_FONT_WEIGHT)(weight > 0 ? weight : 400);
    DWRITE_FONT_STYLE s = italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
    const wchar_t *candidates[] = {family, L"Cascadia Mono", L"Consolas", L"Courier New", L"Segoe UI"};
    ComPtr<IDWriteFont> font;
    const wchar_t *chosen = nullptr;
    for (const wchar_t *c : candidates) {
        if (!c || !*c) continue;
        font = findFont(c, w, s);
        if (font) { chosen = c; break; }
    }
    if (!font) return nullptr;
    TWFont *f = new TWFont();
    f->family = chosen;
    f->size = sizeDIP > 1 ? sizeDIP : 1;
    font->CreateFontFace(&f->face);
    font->GetMetrics(&f->designMetrics);
    if (FAILED(dwFactory()->CreateTextFormat(chosen, nullptr, w, s, DWRITE_FONT_STRETCH_NORMAL, f->size, L"en-us",
                                             &f->format))) {
        delete f;
        return nullptr;
    }
    f->format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    // The advance of a wide, ordinary glyph defines the cell.
    UINT32 cp[2] = {L'M', L'0'};
    UINT16 glyphs[2] = {};
    f->face->GetGlyphIndicesW(cp, 2, glyphs);
    DWRITE_GLYPH_METRICS gm[2] = {};
    f->face->GetDesignGlyphMetrics(glyphs, 2, gm, FALSE);
    f->advance = (float)std::max(gm[0].advanceWidth, gm[1].advanceWidth);
    if (f->advance <= 0) f->advance = f->designMetrics.designUnitsPerEm * 0.6f;
    return f;
}

extern "C" void tw_font_destroy(TWFont *f) { delete f; }

extern "C" void tw_font_metrics(TWFont *f, float dpi, TWFontMetrics *out) {
    if (!f || !out) return;
    float scale = f->size / (float)std::max<UINT16>(f->designMetrics.designUnitsPerEm, 1);
    float px = (dpi > 0 ? dpi : 96) / 96.0f;
    auto snap = [px](float dip) { return std::max(1.0f, std::round(dip * px)) / px; };
    float ascent = f->designMetrics.ascent * scale;
    float descent = f->designMetrics.descent * scale;
    float gap = f->designMetrics.lineGap * scale;
    out->cellWidth = snap(f->advance * scale);
    out->cellHeight = snap(ascent + descent + gap);
    out->baseline = std::round((ascent + gap / 2) * px) / px;
    out->underlinePosition = out->baseline - f->designMetrics.underlinePosition * scale;
    out->underlineThickness = std::max(1.0f / px, f->designMetrics.underlineThickness * scale);
}

extern "C" int tw_font_families(wchar_t *out, int outChars, int monospacedOnly) {
    IDWriteFontCollection *fonts = systemFonts();
    if (!fonts || !out || outChars <= 0) return 0;
    std::vector<std::wstring> names;
    UINT32 count = fonts->GetFontFamilyCount();
    for (UINT32 i = 0; i < count; i++) {
        ComPtr<IDWriteFontFamily> family;
        if (FAILED(fonts->GetFontFamily(i, &family))) continue;
        if (monospacedOnly) {
            ComPtr<IDWriteFont> font;
            ComPtr<IDWriteFont1> font1;
            if (FAILED(family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                                    DWRITE_FONT_STYLE_NORMAL, &font)) ||
                FAILED(font.As(&font1)) || !font1->IsMonospacedFont())
                continue;
        }
        ComPtr<IDWriteLocalizedStrings> localized;
        if (FAILED(family->GetFamilyNames(&localized))) continue;
        UINT32 index = 0;
        BOOL exists = FALSE;
        localized->FindLocaleName(L"en-us", &index, &exists);
        if (!exists) index = 0;
        UINT32 length = 0;
        localized->GetStringLength(index, &length);
        std::wstring name(length + 1, L'\0');
        localized->GetString(index, &name[0], length + 1);
        name.resize(length);
        if (!name.empty() && name[0] != L'@') names.push_back(name);
    }
    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());
    int written = 0, used = 0;
    for (const auto &n : names) {
        int need = (int)n.size() + 1;
        if (used + need >= outChars) break;
        wmemcpy(out + used, n.c_str(), n.size() + 1);
        used += need;
        written++;
    }
    if (used < outChars) out[used] = 0;
    return written;
}

// ---------------------------------------------------------------------------------- renderer

struct TWRenderer {
    HWND hwnd = nullptr;
    ComPtr<ID3D11Device> d3d;
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<ID2D1Device> device;
    ComPtr<ID2D1DeviceContext> dc;
    ComPtr<IDXGISwapChain1> swap;
    ComPtr<IDCompositionDevice> composition;
    ComPtr<IDCompositionTarget> compositionTarget;
    ComPtr<IDCompositionVisual> visual;
    ComPtr<ID2D1Bitmap1> target;
    ComPtr<ID2D1SolidColorBrush> brush;
    ComPtr<ID2D1Bitmap1> snapshot;
    UINT width = 1, height = 1;
    float dpi = 96;
    bool snapshotting = false;
    bool drawing = false;
};

static void bindTarget(TWRenderer *r) {
    r->dc->SetTarget(nullptr);
    r->target.Reset();
    if (!r->swap) return;
    ComPtr<IDXGISurface> surface;
    if (FAILED(r->swap->GetBuffer(0, IID_PPV_ARGS(&surface)))) return;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), r->dpi, r->dpi);
    if (SUCCEEDED(r->dc->CreateBitmapFromDxgiSurface(surface.Get(), &props, &r->target))) {
        r->dc->SetTarget(r->target.Get());
    }
    r->dc->SetDpi(r->dpi, r->dpi);
}

static bool createDevice(TWRenderer *r) {
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                  D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3};
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, ARRAYSIZE(levels),
                                   D3D11_SDK_VERSION, &r->d3d, nullptr, nullptr);
    if (FAILED(hr)) {
        // No GPU (a VM, a CI runner, Remote Desktop without acceleration): software rendering.
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels, ARRAYSIZE(levels),
                               D3D11_SDK_VERSION, &r->d3d, nullptr, nullptr);
    }
    if (FAILED(hr) || FAILED(r->d3d.As(&r->dxgi)) || !d2dFactory()) return false;
    if (FAILED(d2dFactory()->CreateDevice(r->dxgi.Get(), &r->device))) return false;
    if (FAILED(r->device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &r->dc))) return false;

    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory2> factory;
    if (FAILED(r->dxgi->GetAdapter(&adapter)) || FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) return false;

    RECT rc = {};
    GetClientRect(r->hwnd, &rc);
    r->width = std::max<UINT>(1, rc.right - rc.left);
    r->height = std::max<UINT>(1, rc.bottom - rc.top);

    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = r->width;
    desc.Height = r->height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    desc.Scaling = DXGI_SCALING_STRETCH;
    // Without the desktop window manager (a service session, some remote sessions) there is no
    // composition. The renderer then draws nothing to the window but can still draw snapshots,
    // which is all a headless run needs.
    bool composed = SUCCEEDED(factory->CreateSwapChainForComposition(r->d3d.Get(), &desc, nullptr, &r->swap)) &&
                    SUCCEEDED(DCompositionCreateDevice(r->dxgi.Get(), IID_PPV_ARGS(&r->composition))) &&
                    SUCCEEDED(r->composition->CreateTargetForHwnd(r->hwnd, TRUE, &r->compositionTarget)) &&
                    SUCCEEDED(r->composition->CreateVisual(&r->visual));
    if (composed) {
        r->visual->SetContent(r->swap.Get());
        r->compositionTarget->SetRoot(r->visual.Get());
        r->composition->Commit();
        bindTarget(r);
    } else {
        OutputDebugStringW(L"Termsie: DirectComposition unavailable; drawing offscreen only.");
        r->swap.Reset();
        r->dc->SetDpi(r->dpi, r->dpi);
    }
    r->dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    return SUCCEEDED(r->dc->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &r->brush));
}

extern "C" TWRenderer *tw_renderer_create(TWWindowHandle hwnd_handle) {
    HWND hwnd = (HWND)hwnd_handle;
    if (!hwnd) return nullptr;
    TWRenderer *r = new TWRenderer();
    r->hwnd = hwnd;
    if (!createDevice(r)) {
        delete r;
        return nullptr;
    }
    return r;
}

extern "C" void tw_renderer_destroy(TWRenderer *r) { delete r; }

extern "C" void tw_renderer_resize(TWRenderer *r, UINT width, UINT height, float dpi) {
    if (!r) return;
    width = std::max<UINT>(1, width);
    height = std::max<UINT>(1, height);
    float newDpi = dpi > 0 ? dpi : 96;
    if (width == r->width && height == r->height && newDpi == r->dpi) return;
    r->width = width;
    r->height = height;
    r->dpi = newDpi;
    r->dc->SetTarget(nullptr);
    r->target.Reset();
    if (r->swap) r->swap->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0);
    bindTarget(r);
}

extern "C" int tw_renderer_begin(TWRenderer *r) {
    if (!r || !r->target || r->drawing) return 0;
    r->dc->SetTarget(r->target.Get());
    r->dc->SetDpi(r->dpi, r->dpi);
    r->dc->BeginDraw();
    r->dc->SetTransform(D2D1::Matrix3x2F::Identity());
    r->drawing = true;
    return 1;
}

extern "C" int tw_renderer_end(TWRenderer *r) {
    if (!r || !r->drawing) return 1;
    r->drawing = false;
    HRESULT hr = r->dc->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) return 0;
    if (!r->swap) return 1;
    hr = r->swap->Present(1, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) return 0;
    return 1;
}

extern "C" int tw_snapshot_begin(TWRenderer *r, UINT width, UINT height, float dpi) {
    if (!r || r->drawing) return 0;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        dpi, dpi);
    r->snapshot.Reset();
    if (FAILED(r->dc->CreateBitmap(D2D1::SizeU(std::max<UINT>(1, width), std::max<UINT>(1, height)), nullptr, 0,
                                   &props, &r->snapshot)))
        return 0;
    r->dc->SetTarget(r->snapshot.Get());
    r->dc->SetDpi(dpi, dpi);
    r->dc->BeginDraw();
    r->dc->SetTransform(D2D1::Matrix3x2F::Identity());
    r->drawing = true;
    r->snapshotting = true;
    return 1;
}

static bool writePNG(const wchar_t *path, UINT width, UINT height, const BYTE *pixels, UINT stride) {
    ComPtr<IWICImagingFactory> wic;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))))
        return false;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    if (FAILED(wic->CreateStream(&stream)) || FAILED(stream->InitializeFromFilename(path, GENERIC_WRITE)) ||
        FAILED(wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
        FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
        FAILED(encoder->CreateNewFrame(&frame, nullptr)) || FAILED(frame->Initialize(nullptr)) ||
        FAILED(frame->SetSize(width, height)))
        return false;
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (FAILED(frame->SetPixelFormat(&format))) return false;
    // Un-premultiply, so translucent pixels keep their colour in the file.
    std::vector<BYTE> straight((size_t)stride * height);
    for (UINT y = 0; y < height; y++) {
        const BYTE *src = pixels + (size_t)y * stride;
        BYTE *dst = straight.data() + (size_t)y * stride;
        for (UINT x = 0; x < width; x++) {
            BYTE a = src[x * 4 + 3];
            for (int c = 0; c < 3; c++) {
                dst[x * 4 + c] = a ? (BYTE)std::min(255, (src[x * 4 + c] * 255 + a / 2) / a) : 0;
            }
            dst[x * 4 + 3] = a;
        }
    }
    return SUCCEEDED(frame->WritePixels(height, stride, (UINT)straight.size(), straight.data())) &&
           SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
}

extern "C" int tw_snapshot_end(TWRenderer *r, const wchar_t *pngPath) {
    if (!r || !r->snapshotting) return 0;
    r->drawing = false;
    r->snapshotting = false;
    HRESULT hr = r->dc->EndDraw();
    r->dc->SetTarget(r->target ? r->target.Get() : nullptr);
    r->dc->SetDpi(r->dpi, r->dpi);
    if (FAILED(hr) || !r->snapshot) return 0;
    D2D1_SIZE_U size = r->snapshot->GetPixelSize();
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
    ComPtr<ID2D1Bitmap1> readable;
    if (FAILED(r->dc->CreateBitmap(size, nullptr, 0, &props, &readable))) return 0;
    D2D1_POINT_2U origin = {0, 0};
    D2D1_RECT_U all = {0, 0, size.width, size.height};
    if (FAILED(readable->CopyFromBitmap(&origin, r->snapshot.Get(), &all))) return 0;
    D2D1_MAPPED_RECT mapped = {};
    if (FAILED(readable->Map(D2D1_MAP_OPTIONS_READ, &mapped))) return 0;
    bool ok = writePNG(pngPath, size.width, size.height, mapped.bits, mapped.pitch);
    readable->Unmap();
    r->snapshot.Reset();
    return ok ? 1 : 0;
}

// ---------------------------------------------------------------------------------- drawing

static ID2D1SolidColorBrush *brush(TWRenderer *r, TWColor c) {
    r->brush->SetColor(color(c));
    return r->brush.Get();
}

extern "C" void tw_clear(TWRenderer *r, TWColor c) {
    if (r && r->drawing) r->dc->Clear(color(c));
}

extern "C" void tw_fill_rect(TWRenderer *r, float x, float y, float w, float h, TWColor c) {
    if (!r || !r->drawing || w <= 0 || h <= 0 || c.a <= 0) return;
    r->dc->FillRectangle(D2D1::RectF(x, y, x + w, y + h), brush(r, c));
}

extern "C" void tw_fill_rounded_rect(TWRenderer *r, float x, float y, float w, float h, float radius, TWColor c) {
    if (!r || !r->drawing || w <= 0 || h <= 0 || c.a <= 0) return;
    r->dc->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + w, y + h), radius, radius), brush(r, c));
}

extern "C" void tw_stroke_rect(TWRenderer *r, float x, float y, float w, float h, float width, TWColor c) {
    if (!r || !r->drawing || c.a <= 0) return;
    r->dc->DrawRectangle(D2D1::RectF(x, y, x + w, y + h), brush(r, c), width);
}

extern "C" void tw_stroke_rounded_rect(TWRenderer *r, float x, float y, float w, float h, float radius, float width,
                                       TWColor c) {
    if (!r || !r->drawing || c.a <= 0) return;
    r->dc->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + w, y + h), radius, radius), brush(r, c),
                                width);
}

extern "C" void tw_draw_line(TWRenderer *r, float x1, float y1, float x2, float y2, float width, TWColor c) {
    if (!r || !r->drawing || c.a <= 0) return;
    r->dc->DrawLine(D2D1::Point2F(x1, y1), D2D1::Point2F(x2, y2), brush(r, c), width);
}

extern "C" void tw_fill_ellipse(TWRenderer *r, float cx, float cy, float rx, float ry, TWColor c) {
    if (!r || !r->drawing || c.a <= 0) return;
    r->dc->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), rx, ry), brush(r, c));
}

extern "C" void tw_draw_shadow(TWRenderer *r, float x, float y, float w, float h, float radius, float spread,
                               float opacity) {
    if (!r || !r->drawing || spread <= 0 || opacity <= 0) return;
    // Concentric outlines fading outward approximate a Gaussian shadow at a fraction of the cost
    // of the shadow effect, which would need the pane rendered to a bitmap first.
    int steps = (int)std::min(12.0f, std::max(3.0f, spread / 1.5f));
    for (int i = steps; i >= 1; i--) {
        float t = (float)i / steps;
        float grow = spread * t;
        float alpha = opacity * (1 - t) * (1 - t) * 0.35f;
        TWColor c = {0, 0, 0, alpha};
        tw_fill_rounded_rect(r, x - grow, y - grow * 0.6f, w + 2 * grow, h + 2 * grow, radius + grow, c);
    }
}

extern "C" void tw_push_clip(TWRenderer *r, float x, float y, float w, float h) {
    if (!r || !r->drawing) return;
    r->dc->PushAxisAlignedClip(D2D1::RectF(x, y, x + std::max(0.0f, w), y + std::max(0.0f, h)),
                               D2D1_ANTIALIAS_MODE_ALIASED);
}

extern "C" void tw_pop_clip(TWRenderer *r) {
    if (r && r->drawing) r->dc->PopAxisAlignedClip();
}

extern "C" void tw_push_rounded_clip(TWRenderer *r, float x, float y, float w, float h, float radius) {
    if (!r || !r->drawing) return;
    ComPtr<ID2D1RoundedRectangleGeometry> geometry;
    d2dFactory()->CreateRoundedRectangleGeometry(
        D2D1::RoundedRect(D2D1::RectF(x, y, x + std::max(0.0f, w), y + std::max(0.0f, h)), radius, radius),
        &geometry);
    r->dc->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), geometry.Get()), nullptr);
}

extern "C" void tw_pop_rounded_clip(TWRenderer *r) {
    if (r && r->drawing) r->dc->PopLayer();
}

// ------------------------------------------------------------------------------------- text

extern "C" void tw_draw_cells(TWRenderer *r, TWFont *f, const wchar_t *text, int len, const uint8_t *cells, float x,
                              float y, float cellWidth, float cellHeight, float baseline, TWColor c) {
    if (!r || !r->drawing || !f || !text || len <= 0 || c.a <= 0) return;
    ID2D1SolidColorBrush *b = brush(r, c);

    std::vector<UINT32> codepoints;
    std::vector<float> columns;   // starting column of each code point
    std::vector<int> widths;      // cells each code point covers
    codepoints.reserve(len);
    float col = 0;
    for (int i = 0; i < len; i++) {
        UINT32 cp = text[i];
        int units = 1;
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len && text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (text[i + 1] - 0xDC00);
            units = 2;
        }
        // 0 is a combining mark: drawn over the previous cell, advancing nothing.
        int width = cells ? cells[i] : 1;
        codepoints.push_back(cp);
        columns.push_back(col);
        widths.push_back(width);
        col += width;
        i += units - 1;
    }

    std::vector<UINT16> glyphs(codepoints.size());
    f->face->GetGlyphIndicesW(codepoints.data(), (UINT32)codepoints.size(), glyphs.data());

    // Glyphs the font has go out as runs with every advance pinned to the grid. A missing glyph
    // ends the run and is drawn alone through a layout, which picks a fallback font.
    size_t start = 0;
    auto flush = [&](size_t end) {
        if (end <= start) return;
        std::vector<FLOAT> advances(end - start);
        for (size_t i = start; i < end; i++) advances[i - start] = widths[i] * cellWidth;
        DWRITE_GLYPH_RUN run = {};
        run.fontFace = f->face.Get();
        run.fontEmSize = f->size;
        run.glyphCount = (UINT32)(end - start);
        run.glyphIndices = glyphs.data() + start;
        run.glyphAdvances = advances.data();
        r->dc->DrawGlyphRun(D2D1::Point2F(x + columns[start] * cellWidth, y + baseline), &run, b);
    };
    for (size_t i = 0; i < codepoints.size(); i++) {
        if (glyphs[i] != 0) continue;
        flush(i);
        start = i + 1;
        UINT32 cp = codepoints[i];
        wchar_t units[2];
        UINT32 n = 1;
        if (cp >= 0x10000) {
            units[0] = (wchar_t)(0xD800 + ((cp - 0x10000) >> 10));
            units[1] = (wchar_t)(0xDC00 + ((cp - 0x10000) & 0x3FF));
            n = 2;
        } else {
            units[0] = (wchar_t)cp;
        }
        float left = x + columns[i] * cellWidth;
        float w = widths[i] * cellWidth;
        ComPtr<IDWriteTextLayout> layout;
        if (SUCCEEDED(dwFactory()->CreateTextLayout(units, n, f->format.Get(), w * 2, cellHeight, &layout))) {
            DWRITE_TEXT_METRICS m = {};
            layout->GetMetrics(&m);
            // Centre the fallback glyph in its cells.
            float dx = (w - m.widthIncludingTrailingWhitespace) / 2;
            r->dc->DrawTextLayout(D2D1::Point2F(left + dx, y), layout.Get(), b,
                                  D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
        }
    }
    flush(codepoints.size());
}

extern "C" void tw_draw_text(TWRenderer *r, TWFont *f, const wchar_t *text, int len, float x, float y, float w,
                             float h, int align, TWColor c) {
    if (!r || !r->drawing || !f || !text || len <= 0 || w <= 0 || c.a <= 0) return;
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwFactory()->CreateTextLayout(text, (UINT32)len, f->format.Get(), w, h, &layout))) return;
    layout->SetTextAlignment(align == 1 ? DWRITE_TEXT_ALIGNMENT_CENTER
                             : align == 2 ? DWRITE_TEXT_ALIGNMENT_TRAILING
                                          : DWRITE_TEXT_ALIGNMENT_LEADING);
    layout->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
    ComPtr<IDWriteInlineObject> ellipsis;
    dwFactory()->CreateEllipsisTrimmingSign(f->format.Get(), &ellipsis);
    layout->SetTrimming(&trimming, ellipsis.Get());
    r->dc->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), brush(r, c),
                          D2D1_DRAW_TEXT_OPTIONS_CLIP | D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
}

extern "C" float tw_measure_text(TWFont *f, const wchar_t *text, int len) {
    if (!f || !text || len <= 0) return 0;
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwFactory()->CreateTextLayout(text, (UINT32)len, f->format.Get(), 100000, 1000, &layout))) return 0;
    DWRITE_TEXT_METRICS m = {};
    layout->GetMetrics(&m);
    return m.widthIncludingTrailingWhitespace;
}
