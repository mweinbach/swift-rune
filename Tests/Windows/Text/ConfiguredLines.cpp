// Build and run this probe with Run.ps1 from a Visual Studio developer PowerShell.
#include "RuneDesktopText.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

struct TextCase {
    const char *name, *text, *family, *language, *features, *axes;
    int mono = 0, direction = 0;
};

using Line = std::unique_ptr<RuneDesktopLine, decltype(&rune_desktop_line_destroy)>;
static constexpr char diffFeatures[] = "liga=0,clig=0,calt=0,dlig=0";

static Line create(const TextCase &c, bool configured, int lcd, const std::string &text) {
    const int size = static_cast<int>(text.size());
    RuneDesktopLine *raw;
    if (configured) {
        raw = rune_windows_line_create_configured(text.data(), size, c.family, 24, 400, 0,
            c.mono, c.direction, lcd, c.language, c.features, c.axes);
    } else {
        raw = rune_windows_line_create(text.data(), size, c.family, 24, 400, 0, c.mono, c.direction, lcd);
        if (raw && ((c.language && *c.language) || (c.features && *c.features) || (c.axes && *c.axes)))
            rune_desktop_line_configure(raw, c.language, c.features, c.axes);
    }
    return Line(raw, rune_desktop_line_destroy);
}

static void require(bool condition, const char *sample, const char *part) {
    if (!condition) {
        std::fprintf(stderr, "FAIL %s: %s\n", sample, part);
        std::exit(1);
    }
}

static void compareInk(const char *sample, const RuneDesktopLine *a, const RuneDesktopLine *b) {
    auto m = rune_desktop_line_metrics(a);
    auto n = rune_desktop_line_metrics(b);
    static_assert(sizeof(m) == 10 * sizeof(float));
    require(!std::memcmp(&m, &n, sizeof(m)), sample, "metrics or ink bounds");
    require(rune_desktop_line_has_color(a) == rune_desktop_line_has_color(b), sample, "color flag");
    const int w = m.ink_width + 2, h = m.ink_height + 2;
    using Draw = decltype(&rune_desktop_line_mask);
    auto raster = [&](Draw draw, int channels) {
        std::vector<uint8_t> left(size_t(w) * h * channels), right(left.size());
        const int ok = draw(a, m.ink_x - 1, m.ink_y - 1, w, h, left.data());
        require(ok == draw(b, m.ink_x - 1, m.ink_y - 1, w, h, right.data()), sample, "raster support");
        if (ok) require(left == right, sample, "raster pixels");
        return ok;
    };
    require(raster(rune_desktop_line_mask, 1) != 0, sample, "A8 render");
    raster(rune_windows_line_lcd, 3);
    require(raster(rune_desktop_line_color, 4) != 0, sample, "RGBA render");
}

static void compare(const TextCase &c, int lcd) {
    std::string text(c.text);
    auto a = create(c, false, lcd, text), b = create(c, true, lcd, text);
    require(a && b, c.name, "line creation");
    compareInk(c.name, a.get(), b.get());
    for (int i = 0; i <= int(text.size()); ++i)
        require(rune_desktop_line_caret(a.get(), i) == rune_desktop_line_caret(b.get(), i), c.name, "caret");
    for (int lo = 0; lo < int(text.size());) {
        int end = lo + 1;
        while (end < int(text.size()) && (static_cast<unsigned char>(text[end]) & 0xc0) == 0x80) ++end;
        float x1, x2, w1, w2;
        int first = rune_desktop_line_cell(a.get(), lo, end, &x1, &w1);
        require(first == rune_desktop_line_cell(b.get(), lo, end, &x2, &w2) && x1 == x2 && w1 == w2,
                c.name, "cell direction, origin or advance");
        Line ink1(rune_desktop_line_extract_ink(a.get(), lo, end), rune_desktop_line_destroy);
        Line ink2(rune_desktop_line_extract_ink(b.get(), lo, end), rune_desktop_line_destroy);
        require(ink1 && ink2, c.name, "cluster extraction");
        compareInk(c.name, ink1.get(), ink2.get());
        lo = end;
    }
    // A second explicit reconfiguration must also use the new line's shaped layout.
    rune_desktop_line_configure(a.get(), "en-US", "kern=0,liga=1", nullptr);
    rune_desktop_line_configure(b.get(), "en-US", "kern=0,liga=1", nullptr);
    compareInk(c.name, a.get(), b.get());
}

static void benchmark(const char *family) {
    TextCase c{"diff", "", family, nullptr, diffFeatures, nullptr, 1, 1};
    std::vector<double> us[2];
    std::vector<std::string> text;
    for (int i = 0; i < 600; ++i) {
        auto number = std::to_string(12001 + i);
        text.push_back("let value_" + number + " = compute(" + number + ");");
    }
    using Clock = std::chrono::steady_clock;
    auto timeLine = [&](bool configured, int index) {
        auto start = Clock::now();
        auto line = create(c, configured, 1, text[index]);
        require(line && rune_desktop_line_metrics(line.get()).advance > 0, c.name, "timed line");
        return std::chrono::duration<double, std::micro>(Clock::now() - start).count();
    };
    for (int i = 0; i < 32; ++i) { timeLine(false, i); timeLine(true, i); }
    // Alternate which implementation sees each input first. Each line is newly shaped.
    for (int i = 0; i < int(text.size()); ++i) {
        const int first = i % 2;
        us[first].push_back(timeLine(first, i));
        us[1 - first].push_back(timeLine(!first, i));
    }
    for (int i = 0; i < 2; ++i) {
        auto &v = us[i];
        std::sort(v.begin(), v.end());
        std::printf("%s count=%zu p50_us=%.3f p95_us=%.3f\n", i ? "configured" : "legacy", v.size(),
                    (v[299] + v[300]) * 0.5, v[569]);
    }
}

int main(int argc, char **argv) {
    require(argc <= 2, "arguments", "expected optional IBM Plex Mono path");
    const char *family = "Consolas";
    if (argc == 2) {
        require(rune_desktop_register_font_file(argv[1]) != 0, "app font", "registration");
        family = "IBM Plex Mono";
    }
    TextCase cases[] = {
        {"diff", "let value_24001 = compute(24001);", family, nullptr, diffFeatures, nullptr, 1, 1},
        {"font fallback", "ffi != -> AV", "Missing Rune Face, Segoe UI", "en-US", "liga=1,kern=0", nullptr},
        {"default", "Plain default", nullptr, nullptr, nullptr, nullptr},
        {"bidi", u8"אבג 42 fi مرحباً", "Segoe UI", "he-IL", "kern=0", nullptr, 0, 2},
        {"combining and emoji", u8"x e\u0301 🚀 👩‍💻", "Segoe UI Emoji", "en-US", "liga=0", nullptr},
        {"axes", "Variable! fi", "Segoe UI Variable", "en-US", "kern=1", "wght=620"},
        {"ignored settings", "?", "Segoe UI", nullptr, "bad,nonsense=1,liga=-3", "bad,toolong=xyz"},
        {"empty", "", family, "en-US", diffFeatures, "wght=500", 1, 1},
    };
    for (const auto &c : cases) for (int lcd : {0, 1}) compare(c, lcd);
    std::printf("PASS cases=%zu mask_modes=2 font=%s\n", sizeof(cases) / sizeof(cases[0]), family);
    benchmark(family);
    return 0;
}
