"""Compare Rune's shipped TTFs. Run with Python fontTools and HarfBuzz's hb-shape on PATH."""
import json
from pathlib import Path
import subprocess
import unittest

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont


FONTS = Path(__file__).resolve().parents[2] / "Sources/Rune/Resources/Fonts"
STYLES = [("Inter-Regular", 26), ("Inter-Medium", 30), ("Inter-SemiBold", 48)]
COMMON = [
    "Rune → office “quotes” fi ffl AVAWAY 1/2 ½ €100 ™ — …",
    "Ýüñçø Łódź Čeština Ştefan Øresund Œuvre ß",
    "⌘⇧⌥⌃ ⌫ ⎋ ↩ ⏎ «guillemets» ‹›",
    "Ωμέγα Ελληνικά ΐΰ ϊϋ ς; Άλφα",
    "Привет, мир! Ґанок ЇЄІ Ђорђе Љубљана ЎЏ",
]
NATIVE = ["Rune → office “quotes” fi ffl AVAWAY 1/2 ½ €100", "Ýüñçø Ωμέγα Привет", "fn main() { let x = a != b; } // -> =>"]
LATE = ["Tiếng Việt", "ἀρχή", "Әліппе"]


def outlines(font):
    glyphs = font.getGlyphSet()
    result = {}
    for name in font.getGlyphOrder():
        pen = DecomposingRecordingPen(glyphs)
        glyphs[name].draw(pen)
        result[name] = (font["hmtx"][name], pen.value)
    return result


def shape(path, size, text):
    raw = subprocess.check_output(["hb-shape", "--no-glyph-names", "--output-format=json",
                                   f"--font-size={size * 64}", f"--font-ppem={size}", str(path), text])
    return json.loads(raw)


class WebFontAssets(unittest.TestCase):
    def test_native_and_full(self):
        # Unhinted glyph geometry and all mappings stay intact in the smaller web files,
        # including glyphs that have no corresponding Unicode scalar.
        shaped_count = 0
        for family, size in STYLES:
            native_path = FONTS / (family + ".ttf")
            full_path = FONTS / "web" / native_path.name
            self.assertLess(full_path.stat().st_size, native_path.stat().st_size * 3 // 4)
            with TTFont(native_path) as native, TTFont(full_path) as full:
                for tag in ["fpgm", "prep", "cvt "]:
                    self.assertNotIn(tag, full)
                for tag in ["OS/2", "hhea", "hmtx"]:
                    self.assertEqual(native.getTableData(tag), full.getTableData(tag), family + " " + tag)
                def cmap(font):
                    return {scalar: font.getGlyphID(glyph) for scalar, glyph in font.getBestCmap().items()}
                self.assertEqual(cmap(native), cmap(full), family)
                a, b = native.getTableData("head"), full.getTableData("head")
                self.assertEqual(a[:8] + a[12:], b[:8] + b[12:])  # The file checksum changes.
                for field in ["italicAngle", "underlinePosition", "underlineThickness", "isFixedPitch"]:
                    self.assertEqual(getattr(native["post"], field), getattr(full["post"], field))
                self.assertEqual(native["maxp"].numGlyphs, full["maxp"].numGlyphs)
                original, web = outlines(native), outlines(full)
                for gid, name in enumerate(native.getGlyphOrder()):
                    self.assertEqual(original[name], web[full.getGlyphName(gid)], (family, gid))
                for sample in NATIVE:
                    a, b = shape(native_path, size, sample), shape(full_path, size, sample)
                    self.assertEqual(a, b, (family, sample))
                    shaped_count += len(a)
        # Both builds use this very same IBM Plex Mono face for the monospace style.
        shaped_count += sum(len(shape(FONTS / "IBMPlexMono-Regular.ttf", 26, text)) for text in NATIVE)
        self.assertGreater(shaped_count, 300)

    def test_first_and_full(self):
        shaped_count = 0
        for family, size in STYLES:
            full_path = FONTS / "web" / (family + ".ttf")
            first_path = full_path.parent / "first" / full_path.name
            with TTFont(first_path) as first, TTFont(full_path) as full:
                a, b = outlines(first), outlines(full)
                cmap = full.getBestCmap()
                for scalar, glyph in first.getBestCmap().items():
                    self.assertEqual(a[glyph], b[cmap[scalar]], (family, scalar))
                for sample in COMMON:
                    x, y = shape(first_path, size, sample), shape(full_path, size, sample)
                    self.assertEqual(len(x), len(y))
                    for p, q in zip(x, y):
                        first_id, full_id = p.pop("g"), q.pop("g")
                        self.assertNotEqual(first_id, 0)
                        self.assertEqual(a[first.getGlyphName(first_id)], b[full.getGlyphName(full_id)])
                        self.assertEqual(p, q, (family, sample))  # Cluster, offset and advance.
                    shaped_count += len(x)
                for sample in LATE:
                    self.assertTrue(any(g["g"] == 0 for g in shape(first_path, size, sample)), (family, sample))
                    self.assertTrue(all(g["g"] != 0 for g in shape(full_path, size, sample)), (family, sample))
        self.assertGreater(shaped_count, 400)


if __name__ == "__main__":
    unittest.main()
