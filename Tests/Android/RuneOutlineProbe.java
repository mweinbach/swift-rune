package dev.rune.probe;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.os.Build;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;

/** Compares the shaped glyph outlines to Android's independent StaticLayout rasterization. */
public final class RuneOutlineProbe {
    private static void require(boolean ok, String reason) {
        if (!ok) throw new AssertionError(reason);
    }

    private static Object line(Class<?> type, String text, String family) throws Exception {
        return line(type, text, family, 64f);
    }

    private static Object line(Class<?> type, String text, String family, float size) throws Exception {
        return line(type, text, family, size, 400);
    }

    private static Object line(Class<?> type, String text, String family, float size, int weight) throws Exception {
        return type.getConstructor(byte[].class, byte[].class, float.class, int.class,
            boolean.class, boolean.class, int.class).newInstance(text.getBytes(StandardCharsets.UTF_8),
                family.getBytes(StandardCharsets.UTF_8), size, weight, false, false, 0);
    }

    private static Path path(float[] commands) {
        require(commands != null && commands.length % 7 == 0, "missing or malformed glyph outline");
        Path path = new Path();
        for (int i = 0; i < commands.length; i += 7) {
            switch ((int)commands[i]) {
                case 0: path.moveTo(commands[i + 1], commands[i + 2]); break;
                case 1: path.lineTo(commands[i + 1], commands[i + 2]); break;
                case 2: path.quadTo(commands[i + 1], commands[i + 2], commands[i + 3], commands[i + 4]); break;
                case 3: path.cubicTo(commands[i + 1], commands[i + 2], commands[i + 3], commands[i + 4],
                                      commands[i + 5], commands[i + 6]); break;
                case 4: path.close(); break;
                default: throw new AssertionError("Unknown outline operation " + commands[i]);
            }
        }
        return path;
    }

    private static void checkPlacement(Class<?> type, Object line, int owner, float[] placed) throws Exception {
        long[] source = (long[])type.getMethod("outlineSingle", int.class).invoke(line, owner);
        if (source == null) return;
        float[] unplaced = (float[])type.getMethod("outlineUnplaced", int.class).invoke(line, owner);
        require(unplaced != null && unplaced.length == placed.length, "Single glyph changed command count");
        float x = Float.intBitsToFloat((int)(source[2] >>> 32));
        float y = Float.intBitsToFloat((int)source[2]);
        for (int i = 0; i < placed.length; i += 7) {
            int command = (int)placed[i];
            require(placed[i] == unplaced[i], "Single glyph changed command");
            int points = command == 4 ? 0 : command == 3 ? 3 : command == 2 ? 2 : 1;
            for (int j = 0; j < points; j++) {
                int k = i + 1 + 2 * j;
                require(Math.abs(unplaced[k] + x - placed[k]) < .0001f &&
                        Math.abs(unplaced[k + 1] + y - placed[k + 1]) < .0001f, "Single glyph changed placement");
            }
        }
    }

    public static String check(Class<?> type, String text, String family, int continuation) throws Exception {
        Object line = line(type, text, family);
        type.getMethod("configure", String.class, String.class, String.class).invoke(line, "", "liga=1", "");
        float[] m = (float[])type.getMethod("metrics").invoke(line);
        int x = (int)m[3], y = (int)m[4], w = (int)m[5], h = (int)m[6];
        byte[] nativeMask = (byte[])type.getMethod("mask", int.class, int.class, int.class, int.class, boolean.class)
            .invoke(line, x, y, w, h, false);
        int[] regions = (int[])type.getMethod("outlineRegions").invoke(line);
        require(regions != null && regions.length > 0 && regions.length % 5 == 0, "missing regions for " + text);
        boolean[] owners = new boolean[text.length()];
        for (int i = 0; i < regions.length; i += 5) {
            int owner = regions[i];
            require(owner >= 0 && owner < text.length() && !Character.isLowSurrogate(text.charAt(owner)), "bad owner " + owner);
            require(!owners[owner], text + " repeated owner " + owner);
            require(Float.intBitsToFloat(regions[i + 1]) < Float.intBitsToFloat(regions[i + 3]) &&
                    Float.intBitsToFloat(regions[i + 2]) < Float.intBitsToFloat(regions[i + 4]), "empty bounds");
            owners[owner] = true;
        }
        Bitmap design = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        try {
            Canvas canvas = new Canvas(design);
            canvas.translate(-x, -y);
            Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
            paint.setColor(Color.WHITE);
            int ops = 0;
            for (int start = 0; start < text.length();) {
                int end = start + Character.charCount(text.codePointAt(start));
                Object cell = type.getMethod("extractInk", int.class, int.class).invoke(line, start, end);
                float[] geometry = (float[])type.getMethod("outlineCommands").invoke(cell);
                Path path = path(geometry);
                checkPlacement(type, line, start, geometry);
                if (!path.isEmpty()) {
                    require(owners[start], text + " unmapped glyph at " + start);
                    require(start != continuation, text + " duplicate outline in ligature at " + start);
                    canvas.drawPath(path, paint);
                }
                ops += geometry.length / 7;
                start = end;
            }
            require(ops > 0, text + " has no drawable curves");
            int[] rgba = new int[w * h];
            design.getPixels(rgba, 0, w, 0, 0, w, h);
            int intersection = 0, union = 0;
            for (int i = 0; i < rgba.length; i++) {
                boolean a = (rgba[i] >>> 24) > 127, b = (nativeMask[i] & 255) > 127;
                if (a && b) intersection++;
                if (a || b) union++;
            }
            // Android grid-fits native masks. The design outline should cover the same shapes in place.
            double iou = intersection / (double)Math.max(1, union);
            require(union > 100 && iou > .85, text + " shape overlap " + iou);
            return family + " " + text + " ops=" + ops + " owners=" + regions.length / 5 + " maskIoU=" + iou;
        } finally {
            design.recycle();
        }
    }

    public static String run(Context context) throws Exception {
        if (Build.VERSION.SDK_INT < 31) return "API lacks positioned glyph IDs";
        Class<?> type = context.getClassLoader().loadClass("dev.rune.RuneText");
        require((Boolean)type.getMethod("initialize", Context.class).invoke(null, context), "Missing bundled fonts");
        String a = check(type, "Café AV", "IBM Plex Mono", -1);
        String b = check(type, "x-->y", "Inter", 2);
        String c = check(type, ":-)", "Inter", -1);
        String d = check(type, "x\u0301", "Inter", 1);
        Method single = type.getMethod("outlineSingle", int.class);
        long[] original = (long[])single.invoke(line(type, "A", "IBM Plex Mono"), 0);
        long[] shifted = (long[])single.invoke(line(type, "mA", "IBM Plex Mono"), 1);
        long[] larger = (long[])single.invoke(line(type, "A", "IBM Plex Mono", 96f), 0);
        require(original != null && shifted != null && larger != null, "Single glyph missing a cache identity");
        require(original[0] == shifted[0] && original[1] == shifted[1] && original[2] != shifted[2],
                "Matching source glyphs in two layouts should share curves at their own pens");
        require(original[0] != larger[0] && original[1] == larger[1], "Different pixel sizes shared scaled curves");
        long regular = ((long[])single.invoke(line(type, "A", "Inter", 64, 400), 0))[0];
        long medium = ((long[])single.invoke(line(type, "A", "Inter", 64, 500), 0))[0];
        long semibold = ((long[])single.invoke(line(type, "A", "Inter", 64, 600), 0))[0];
        require(regular != medium && medium != semibold && regular != semibold, "Inter faces should be distinct");
        int[] weights = {350, 399, 400, 401, 440, 480, 499, 500, 501, 550, 650, 800};
        for (int weight : weights) {
            long expected = weight <= 400 ? regular : weight <= 500 ? medium : semibold;
            long actual = ((long[])single.invoke(line(type, "A", "Inter", 64, weight), 0))[0];
            require(actual == expected, "Wrong positioned Inter face at CSS weight " + weight);
        }
        Object emoji = line(type, "👩‍💻", "");
        Object view = type.getMethod("extractInk", int.class, int.class).invoke(emoji, 0, 2);
        require(type.getMethod("outlineCommands").invoke(view) == null, "Color emoji must retain native color");
        return a + "\n" + b + "\n" + c + "\n" + d + "\nInter CSS weight selection passed for 12 requests";
    }

    private RuneOutlineProbe() {}
}
