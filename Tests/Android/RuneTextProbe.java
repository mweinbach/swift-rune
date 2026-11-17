package dev.rune.probe;

import android.app.Activity;

import android.content.Context;
import android.icu.text.BreakIterator;
import android.os.Build;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Locale;

/** Device instrumentation for Rune's shipped Android font, bidi geometry and glyph atlas tiles. */
public final class RuneTextProbe {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static float width(Class<?> type, String family) throws Exception {
        Object line = type.getConstructor(byte[].class, byte[].class, float.class, int.class,
            boolean.class, boolean.class, int.class).newInstance("iiiWW Latin".getBytes(StandardCharsets.UTF_8),
                family.getBytes(StandardCharsets.UTF_8), 28.25f, 400, false, false, 0);
        return ((float[])type.getMethod("metrics").invoke(line))[0];
    }

    private static void checkGlyphOwnership(Class<?> type, String text, String family, int owner, int limit)
        throws Exception {
        checkGlyphOwnership(type, text, family, owner, limit, false);
    }

    private static void checkGlyphOwnership(Class<?> type, String text, String family, int owner, int limit,
        boolean italic) throws Exception {
        Object line = type.getConstructor(byte[].class, byte[].class, float.class, int.class,
            boolean.class, boolean.class, int.class).newInstance(text.getBytes(StandardCharsets.UTF_8),
                family.getBytes(StandardCharsets.UTF_8), 48f, 400, italic, false, 0);
        type.getMethod("configure", String.class, String.class, String.class).invoke(line, "", "liga=1", "");
        Method metrics = type.getMethod("metrics"), extract = type.getMethod("extractInk", int.class, int.class);
        Method mask = type.getMethod("mask", int.class, int.class, int.class, int.class, boolean.class);
        float[] original = (float[])metrics.invoke(line);
        int x = (int)original[3], y = (int)original[4], w = (int)original[5], h = (int)original[6];
        byte[] reference = (byte[])mask.invoke(line, x, y, w, h, false);
        byte[] composite = new byte[w * h];
        boolean foundOwner = false;
        for (int start = 0; start < text.length();) {
            int end = start + Character.charCount(text.codePointAt(start));
            Object view = extract.invoke(line, start, end);
            float[] box = (float[])metrics.invoke(view);
            require(box[0] == original[0] && box[1] == original[1] && box[2] == original[2],
                "Extraction changed line metrics: " + text);
            if (start > owner && start < limit)
                require(box[5] == 0 && box[6] == 0, "Ligature continuation has ink: " + text);
            byte[] part = (byte[])mask.invoke(view, x, y, w, h, false);
            for (int i = 0; i < part.length; i++) {
                int alpha = part[i] & 255;
                if (alpha != 0) {
                    int px = x + i % w, py = y + i / w;
                    require(px >= box[3] && px < box[3] + box[5] && py >= box[4] && py < box[4] + box[6],
                        "Glyph overhang fell outside its atlas bounds: " + text);
                    if (start == owner) foundOwner = true;
                }
                composite[i] = (byte)(alpha + ((255 - alpha) * (composite[i] & 255) + 127) / 255);
            }
            start = end;
        }
        require(foundOwner, "Shaping cluster lost its glyph: " + text);
        for (int i = 0; i < composite.length; i++)
            require(Math.abs((reference[i] & 255) - (composite[i] & 255)) <= 1,
                "Combining independent glyphs changed the full raster: " + text);
    }

    // RuneHostProbe discovers this entry point on its Activity by reflection.
    public static void run(Activity activity) throws Exception { run((Context)activity); }

    public static void run(Context context) throws Exception {
        Class<?> type = context.getClassLoader().loadClass("dev.rune.RuneText");
        require((Boolean)type.getMethod("initialize", Context.class).invoke(null, context), "Missing bundled fonts");
        float inter = width(type, "Inter"), mono = width(type, "IBM Plex Mono"), serif = width(type, "serif");
        require(inter != mono && serif != mono, "Family fixture must distinguish the fallback faces");
        require(width(type, "Absent Rune Font, Inter, serif") == inter, "Missing family should fall through to Inter");
        require(width(type, "\"IBM Plex Mono\", Inter") == mono, "First registered family should win");
        require(width(type, "Absent Rune Font, serif, Inter") == serif, "System face should keep its place in the stack");
        require(width(type, "sans-serif, IBM Plex Mono") == width(type, "sans-serif"), "Explicit system default should win");
        String text = "AV office e\u0301漢 😄 אב مرحبا";
        Object line = type.getConstructor(byte[].class, byte[].class, float.class, int.class,
                boolean.class, boolean.class, int.class).newInstance(text.getBytes(StandardCharsets.UTF_8),
                "Inter".getBytes(StandardCharsets.UTF_8), 28.25f, 400, false, false, 0);
        type.getMethod("configure", String.class, String.class, String.class).invoke(line, "en", "kern=1", "");
        float[] metrics = (float[])type.getMethod("metrics").invoke(line);
        require(metrics[0] > 100 && metrics[7] > metrics[9] && metrics[8] > 0, "Invalid face metrics");

        BreakIterator characters = BreakIterator.getCharacterInstance(Locale.ROOT);
        characters.setText(text);
        Method cell = type.getMethod("cell", int.class, int.class);
        int count = 0, rtl = 0, start = characters.first();
        float sum = 0;
        for (int end = characters.next(); end != BreakIterator.DONE; start = end, end = characters.next()) {
            long packed = (Long)cell.invoke(line, start, end);
            float left = Float.intBitsToFloat((int)(packed >>> 32));
            float advance = Float.intBitsToFloat((int)packed);
            require(left >= -0.5f && left + Math.abs(advance) <= metrics[0] + 0.5f, "Cell outside the line");
            sum += Math.abs(advance);
            if (advance < 0) rtl++;
            count++;
        }
        require(count == 23 && rtl >= 7 && Math.abs(sum - metrics[0]) < 0.5f, "Grapheme/bidi advance sum");

        Method tile = type.getMethod("mask", int.class, int.class, int.class, int.class, boolean.class);
        int x = (int)metrics[3], y = (int)metrics[4], w = (int)metrics[5], h = (int)metrics[6];
        byte[] mask = (byte[])tile.invoke(line, x, y, w, h, false);
        byte[] rgba = (byte[])tile.invoke(line, x, y, w, h, true);
        require(mask.length == w * h && rgba.length == w * h * 4, "Tile dimension mismatch");
        int fractional = 0, color = 0, overlap = 0;
        for (int i = 0; i < mask.length; i++) {
            int alpha = mask[i] & 255;
            if (alpha > 0 && alpha < 255) fractional++;
            if (rgba[i * 4 + 3] != 0) {
                if (rgba[i * 4] != rgba[i * 4 + 1] || rgba[i * 4] != rgba[i * 4 + 2]) color++;
                if (alpha > 0) overlap++;
            }
        }
        require(fractional > 50 && color > 25 && overlap < 25, "Monochrome and intrinsic emoji color separation");
        checkGlyphOwnership(type, "سلام", "sans-serif", 1, 3);
        checkGlyphOwnership(type, "X لا Z", "sans-serif", 2, 4);
        checkGlyphOwnership(type, "لو لا", "sans-serif", 3, 5);
        // The bundled Inter has two- and three-character ASCII arrow ligatures.
        checkGlyphOwnership(type, "=>", "Inter", 0, 2);
        checkGlyphOwnership(type, "x-->y", "Inter", 1, 4);
        checkGlyphOwnership(type, "क्षि", "sans-serif", 0, 4);
        checkGlyphOwnership(type, "A\tلا\tZ", "sans-serif", 2, 4);
        checkGlyphOwnership(type, "AV To", "serif", 0, 1);
        if (Build.VERSION.SDK_INT >= 31) {
            // Inter substitutes punctuation in context and Rune packages only its upright faces.
            checkGlyphOwnership(type, ":-)", "Inter", 0, 1);
            checkGlyphOwnership(type, ":-)", "Inter", 0, 1, true);
        }

        String joinedEmoji = "👩‍💻";
        Object emoji = type.getConstructor(byte[].class, byte[].class, float.class, int.class,
            boolean.class, boolean.class, int.class).newInstance(joinedEmoji.getBytes(StandardCharsets.UTF_8),
                new byte[0], 48f, 400, false, false, 0);
        Method extract = type.getMethod("extractInk", int.class, int.class);
        Object owner = extract.invoke(emoji, 0, 2);
        float[] bounds = (float[])type.getMethod("metrics").invoke(owner);
        x = (int)bounds[3]; y = (int)bounds[4]; w = (int)bounds[5]; h = (int)bounds[6];
        require(w > 0 && h > 0, "Joined emoji owner lost its color glyph");
        byte[] wholeColor = (byte[])tile.invoke(emoji, x, y, w, h, true);
        byte[] ownedColor = (byte[])tile.invoke(owner, x, y, w, h, true);
        require(Arrays.equals(wholeColor, ownedColor), "Joined emoji palette changed during extraction");
        require(!Arrays.equals(ownedColor, new byte[ownedColor.length]), "Joined emoji did not rasterize in color");
        float[] continuation = (float[])type.getMethod("metrics").invoke(extract.invoke(emoji, 2, joinedEmoji.length()));
        require(continuation[5] == 0 && continuation[6] == 0, "Joined emoji continuation duplicated the color glyph");
    }
}
