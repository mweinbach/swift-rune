package dev.rune;

import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;

/**
 * Host JVM regression. From the repository root:
 * javac -d /tmp/rune-glyf android/src/main/java/dev/rune/RuneGlyphPaths.java Tests/Android/GlyphPaths/CheckGlyphPaths.java
 * java -cp /tmp/rune-glyf dev.rune.CheckGlyphPaths
 */
public final class CheckGlyphPaths {
    private static void require(boolean result, String description) {
        if (!result) throw new AssertionError(description);
    }

    private static int table(ByteBuffer font, int tag) {
        int count = font.getShort(4) & 0xffff;
        for (int i = 0; i < count; i++) {
            int record = 12 + 16 * i;
            if (font.getInt(record) == tag) return record;
        }
        throw new AssertionError("missing table " + tag);
    }

    private static void hashWord(MessageDigest digest, int value) {
        digest.update((byte)(value >>> 24));
        digest.update((byte)(value >>> 16));
        digest.update((byte)(value >>> 8));
        digest.update((byte)value);
    }

    private static void referenceGeometry(ByteBuffer font) throws Exception {
        RuneGlyphPaths face = RuneGlyphPaths.open(font, 0, false);
        require(face != null && !face.variable && !face.cjk && face.unitsPerEm == 2048, "Inter font metadata");
        require(face.glyph(1777).length == 0, "space has a valid empty outline");
        int count = font.getShort(font.getInt(table(font, 0x6d617870) + 8) + 4) & 0xffff;
        require(face.glyph(-1) == null && face.glyph(count) == null, "invalid glyph indices");
        require(face.glyph(6) == face.glyph(6), "repeat composite access reuses its array");

        // Digest of FontTools' independent flattened contours for bundled Inter Regular.
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        for (int id = 0; id < count; id++) {
            float[] packet = face.glyph(id);
            require(packet != null, "valid glyph " + id);
            hashWord(digest, packet.length);
            for (float value : packet) hashWord(digest, Float.floatToIntBits(value));
        }
        StringBuilder hex = new StringBuilder();
        for (byte b : digest.digest()) hex.append(String.format("%02x", b & 0xff));
        require(hex.toString().equals("b71d970a37681c536594a53f8c678980db1f22e684415329dfed189b75858f89"),
            "positioned curves differ from the FontTools reference");
    }

    public static void main(String[] args) throws Exception {
        byte[] bytes = Files.readAllBytes(Paths.get("Sources/Rune/Resources/Fonts/Inter-Regular.ttf"));
        ByteBuffer font = ByteBuffer.wrap(bytes);
        referenceGeometry(font);
        require(RuneGlyphPaths.open(font, 1, false) == null, "standalone face index");
        require(RuneGlyphPaths.open(font, 0, true) == null, "active variations use native rasterization");
        for (int bit : new int[] {17, 24, 27}) {
            ByteBuffer marked = ByteBuffer.wrap(bytes.clone());
            int os2 = marked.getInt(table(marked, 0x4f532f32) + 8);
            marked.putInt(os2 + 46, marked.getInt(os2 + 46) | (1 << bit));
            require(RuneGlyphPaths.open(marked, 0, false).cjk, "CJK coverage bit " + bit);
        }
        require(RuneGlyphPaths.open((ByteBuffer)font.duplicate().limit(8), 0, false) == null, "short header");

        int glyf = table(font, 0x676c7966), loca = table(font, 0x6c6f6361);
        ByteBuffer invalid = ByteBuffer.wrap(bytes.clone());
        invalid.putInt(loca + 12, 2);
        require(RuneGlyphPaths.open(invalid, 0, false) == null, "truncated location table");
        invalid = ByteBuffer.wrap(bytes.clone());
        invalid.putInt(glyf, 0x434f4c52);
        require(RuneGlyphPaths.open(invalid, 0, false) == null, "color font uses native rasterization");

        // Inter Aacute is glyph 6 and uses long loca entries. Redirect its
        // first component to itself and ensure other glyphs still work.
        invalid = ByteBuffer.wrap(bytes.clone());
        int component = font.getInt(glyf + 8) + font.getInt(font.getInt(loca + 8) + 6 * 4);
        invalid.putShort(component + 12, (short)6);
        RuneGlyphPaths cyclic = RuneGlyphPaths.open(invalid, 0, false);
        require(cyclic.glyph(6) == null && cyclic.glyph(2) != null, "cyclic component fallback");
        System.out.println("All 2,937 Inter Regular glyphs and native fallback checks passed.");
    }
}
