package dev.rune.probe;

import android.app.Activity;
import android.content.Context;
import android.icu.text.BreakIterator;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/** Device instrumentation for Rune's shipped Android font, bidi geometry and glyph atlas tiles. */
public final class RuneTextProbe {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void run(Activity activity) throws Exception {
        Class<?> type = activity.getClassLoader().loadClass("dev.rune.RuneText");
        require((Boolean)type.getMethod("initialize", Context.class).invoke(null, activity), "Missing bundled fonts");
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
    }
}
