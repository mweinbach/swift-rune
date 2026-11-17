package dev.rune;

import android.content.Context;
import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Environment;
import android.os.LocaleList;
import android.icu.lang.UCharacter;
import android.icu.lang.UProperty;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextDirectionHeuristic;
import android.text.TextDirectionHeuristics;
import android.text.TextPaint;
import android.util.Xml;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserException;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Locale;

/** Android line shaping and rasterization for the Rune R8 atlas. Called by the NDK bridge. */
public final class RuneText {
    private static final ArrayList<Face> faces = new ArrayList<>();
    private static HashMap<String, String> systemNames;
    private static File cacheDirectory;
    private static boolean bundledFontsReady;
    private final String text;
    private final TextPaint paint;
    private final int direction;
    private StaticLayout layout;
    private float origin;
    private float[] characterBounds;
    private final float[] metrics = new float[10];
    private final boolean mayHaveColor;
    private Tile lastTile;

    public static synchronized boolean initialize(Context context) {
        cacheDirectory = context.getCacheDir();
        if (bundledFontsReady) return true;
        AssetManager assets = context.getAssets();
        try {
            String[] files = assets.list("Fonts");
            int registered = 0;
            if (files != null) for (String name : files) {
                if (!name.toLowerCase(Locale.ROOT).endsWith(".ttf")) continue;
                String path = "Fonts/" + name;
                try (InputStream input = assets.open(path)) {
                    ByteArrayOutputStream data = new ByteArrayOutputStream();
                    byte[] buffer = new byte[8192];
                    int n;
                    while ((n = input.read(buffer)) != -1) data.write(buffer, 0, n);
                    Face face = Face.read(ByteBuffer.wrap(data.toByteArray()), Typeface.createFromAsset(assets, path));
                    if (face != null) { addFace(face); registered++; }
                }
            }
            bundledFontsReady = registered > 0;
        } catch (IOException | RuntimeException ignored) {
            // Applications may package only system fonts.
        }
        return bundledFontsReady;
    }

    private static void addFace(Face incoming) {
        for (int i = 0; i < faces.size(); i++) {
            Face old = faces.get(i);
            if (old.name.equalsIgnoreCase(incoming.name) && old.weight == incoming.weight && old.italic == incoming.italic) {
                faces.set(i, incoming);
                return;
            }
        }
        faces.add(incoming);
    }

    public static synchronized boolean registerFile(byte[] filename) {
        return addFile(new File(new String(filename, StandardCharsets.UTF_8)));
    }

    private static boolean addFile(File file) {
        try (FileInputStream input = new FileInputStream(file)) {
            FileChannel channel = input.getChannel();
            if (channel.size() < 12 || channel.size() > Integer.MAX_VALUE) return false;
            ByteBuffer data = channel.map(FileChannel.MapMode.READ_ONLY, 0, channel.size());
            Face face = Face.read(data, Typeface.createFromFile(file));
            if (face == null) return false;
            addFace(face);
            return true;
        } catch (IOException | RuntimeException e) {
            return false;
        }
    }

    public static synchronized boolean registerBytes(byte[] bytes) {
        if (cacheDirectory == null) return false;
        File font = null;
        try {
            font = File.createTempFile("rune-font-", ".ttf", cacheDirectory);
            try (FileOutputStream output = new FileOutputStream(font)) { output.write(bytes); }
            return addFile(font);
        } catch (IOException e) {
            return false;
        } finally {
            if (font != null) font.delete();
        }
    }

    private static Typeface styled(Typeface base, int weight, boolean italic) {
        if (Build.VERSION.SDK_INT >= 28) return Typeface.create(base, weight, italic);
        int style = (weight >= 600 ? Typeface.BOLD : 0) | (italic ? Typeface.ITALIC : 0);
        return Typeface.create(base, style);
    }

    private static ArrayList<String> familyList(String stack) {
        ArrayList<String> names = new ArrayList<>();
        StringBuilder name = new StringBuilder();
        char quote = 0;
        for (int i = 0; i < stack.length(); i++) {
            char c = stack.charAt(i);
            if (c == '\\' && i + 1 < stack.length()) name.append(stack.charAt(++i));
            else if (quote != 0) { if (c == quote) quote = 0; else name.append(c); }
            else if (c == '\'' || c == '"') quote = c;
            else if (c == ',') { names.add(name.toString().trim()); name.setLength(0); }
            else name.append(c);
        }
        names.add(name.toString().trim());
        return names;
    }

    private static void readSystemNames(File file, HashMap<String, String> names) {
        try (FileInputStream stream = new FileInputStream(file)) {
            XmlPullParser parser = Xml.newPullParser();
            parser.setInput(stream, null);
            for (int event = parser.next(); event != XmlPullParser.END_DOCUMENT; event = parser.next()) {
                if (event != XmlPullParser.START_TAG) continue;
                String tag = parser.getName();
                if (!tag.equals("alias") && !tag.equals("family") && !tag.equals("family-list")) continue;
                String name = parser.getAttributeValue(null, "name");
                if (name != null) names.put(name.toLowerCase(Locale.ROOT), name);
            }
        } catch (IOException | SecurityException | XmlPullParserException ignored) {
            // OEMs may omit the customization file or use a different vendor font configuration.
        }
    }

    private static Typeface systemTypeface(String name) {
        String key = name.toLowerCase(Locale.ROOT);
        if (key.equals("system-ui") || key.equals("ui-sans-serif") || key.equals("sans-serif")) return Typeface.SANS_SERIF;
        if (key.equals("ui-monospace")) return Typeface.MONOSPACE;
        if (key.equals("ui-serif")) return Typeface.SERIF;
        Typeface result = Typeface.create(name, Typeface.NORMAL);
        if (!result.equals(Typeface.DEFAULT)) return result;
        if (!key.equals(name)) {
            result = Typeface.create(key, Typeface.NORMAL);
            if (!result.equals(Typeface.DEFAULT)) return result;
        }
        // Typeface.create returns the same object for both an unknown name and a valid
        // alias of the default face. Consult Android's named families only for that case.
        if (systemNames == null) {
            HashMap<String, String> names = new HashMap<>();
            readSystemNames(new File(Environment.getRootDirectory(), "etc/fonts.xml"), names);
            String product = System.getenv("ANDROID_PRODUCT_ROOT");
            readSystemNames(new File(product == null ? "/product" : product, "etc/fonts_customization.xml"), names);
            systemNames = names;
        }
        String canonical = systemNames.get(key);
        return canonical == null ? null : Typeface.create(canonical, Typeface.NORMAL);
    }

    private static synchronized Face selectFace(String stack, int weight, boolean italic, boolean mono) {
        for (String name : familyList(stack)) {
            if (name.isEmpty()) continue;
            Face best = null;
            int distance = Integer.MAX_VALUE;
            for (Face face : faces) {
                if (!face.name.equalsIgnoreCase(name)) continue;
                int score = Math.abs(face.weight - weight) + (face.italic != italic ? 1000 : 0);
                if (score < distance) { best = face; distance = score; }
            }
            if (best != null) {
                if (best.italic == italic) return best;
                return new Face(best.name, weight, italic, styled(best.typeface, weight, italic), best.hasColor);
            }
            Typeface nativeFace = systemTypeface(name);
            if (nativeFace != null)
                return new Face(name, weight, italic, styled(nativeFace, weight, italic), false);
        }
        Typeface fallback = mono ? Typeface.MONOSPACE : Typeface.DEFAULT;
        return new Face("", weight, italic, styled(fallback, weight, italic), false);
    }

    // Family/subfamily names are inside the font and need not match its filename.
    private static final class Face {
        final String name;
        final int weight;
        final boolean italic;
        final Typeface typeface;
        final boolean hasColor;

        Face(String name, int weight, boolean italic, Typeface typeface, boolean hasColor) {
            this.name = name; this.weight = weight; this.italic = italic; this.typeface = typeface; this.hasColor = hasColor;
        }

        static ByteBuffer table(ByteBuffer font, int tag) {
            // Android's default face in a TrueType collection is index zero. Table
            // offsets in a collection remain relative to the complete font file.
            int directory = font.getInt(0) == 0x74746366 ? font.getInt(12) : 0;
            if (directory < 0 || directory > font.limit() - 12) return null;
            int count = font.getShort(directory + 4) & 0xffff;
            if (count > (font.limit() - directory - 12) / 16) return null;
            for (int i = 0; i < count; i++) {
                int at = directory + 12 + 16 * i;
                if (font.getInt(at) != tag) continue;
                int pos = font.getInt(at + 8), len = font.getInt(at + 12);
                if (pos < 0 || len < 0 || pos > font.limit() - len) return null;
                ByteBuffer result = font.duplicate();
                result.position(pos).limit(pos + len);
                return result.slice().order(ByteOrder.BIG_ENDIAN);
            }
            return null;
        }

        static Face read(ByteBuffer font, Typeface typeface) {
            try {
                ByteBuffer names = table(font, 0x6e616d65);
                if (names == null || names.limit() < 6) return null;
                int count = names.getShort(2) & 0xffff, strings = names.getShort(4) & 0xffff;
                int rank = -1;
                String family = null;
                for (int i = 0; i < count; i++) {
                    int entry = 6 + i * 12, platform = names.getShort(entry) & 0xffff;
                    int id = names.getShort(entry + 6) & 0xffff;
                    if ((id != 1 && id != 16) || (platform != 0 && platform != 3)) continue;
                    int score = (id == 16 ? 2 : 0) + (names.getShort(entry + 4) == 0x409 ? 1 : 0);
                    if (score <= rank) continue;
                    int size = names.getShort(entry + 8) & 0xffff;
                    int start = strings + (names.getShort(entry + 10) & 0xffff);
                    if (size < 2 || start > names.limit() - size) continue;
                    byte[] value = new byte[size];
                    ByteBuffer source = names.duplicate();
                    source.position(start); source.get(value);
                    family = new String(value, StandardCharsets.UTF_16BE);
                    rank = score;
                }
                if (family == null || family.isEmpty()) return null;
                ByteBuffer os2 = table(font, 0x4f532f32);
                int weight = os2 == null || os2.limit() < 6 ? 400 : os2.getShort(4) & 0xffff;
                boolean italic = os2 == null || os2.limit() < 64 ? typeface.isItalic() : (os2.getShort(62) & 1) != 0;
                boolean color = table(font, 0x434f4c52) != null || table(font, 0x43424454) != null ||
                    table(font, 0x73626978) != null || table(font, 0x53564720) != null;
                return new Face(family, weight, italic, typeface, color);
            } catch (IndexOutOfBoundsException | IllegalArgumentException e) {
                return null;
            }
        }
    }

    public RuneText(byte[] content, byte[] family, float size, int weight, boolean italic,
                    boolean mono, int direction) {
        this.text = new String(content, StandardCharsets.UTF_8);
        this.direction = direction;
        paint = new TextPaint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
        paint.setTextSize(size);
        paint.setColor(Color.WHITE);
        String familyName = new String(family, StandardCharsets.UTF_8);
        Face selected = selectFace(familyName, Math.max(1, Math.min(1000, weight)), italic, mono);
        paint.setTypeface(selected.typeface);
        mayHaveColor = selected.hasColor || needsColorProbe(text);
        shape();
    }

    private static boolean needsColorProbe(String text) {
        for (int i = 0; i < text.length(); ) {
            int cp = text.codePointAt(i);
            if (cp == 0x20e3 || cp == 0xfe0f ||
                (cp >= 0xa9 && (cp >= 0x1f000 || UCharacter.hasBinaryProperty(cp, UProperty.EMOJI)))) return true;
            i += Character.charCount(cp);
        }
        return false;
    }

    // Rune sends comma-separated OpenType tag=value records. Android expects CSS syntax.
    private static String settings(String rune) {
        StringBuilder css = new StringBuilder();
        for (String item : rune.split(",")) {
            int split = item.indexOf('=');
            if (split != 4) continue;
            if (css.length() != 0) css.append(',');
            css.append('\'').append(item, 0, 4).append("' ").append(item.substring(5));
        }
        return css.toString();
    }

    public void configure(String language, String features, String variations) {
        if (!language.isEmpty()) paint.setTextLocales(LocaleList.forLanguageTags(language));
        if (!features.isEmpty()) paint.setFontFeatureSettings(settings(features));
        if (Build.VERSION.SDK_INT >= 26 && !variations.isEmpty()) paint.setFontVariationSettings(settings(variations));
        shape();
    }

    private void shape() {
        lastTile = null;
        TextDirectionHeuristic heuristic = direction == 1 ? TextDirectionHeuristics.LTR :
            direction == 2 ? TextDirectionHeuristics.RTL : TextDirectionHeuristics.FIRSTSTRONG_LTR;
        // Rune wraps at grapheme boundaries. Android positions and shapes each resulting line.
        double desired = Math.ceil(Layout.getDesiredWidth(text, paint) + Math.max(2f, paint.getTextSize()));
        int width = (int)Math.max(1, Math.min(Integer.MAX_VALUE / 4, desired));
        StaticLayout.Builder builder = StaticLayout.Builder.obtain(text, 0, text.length(), paint, width)
            .setTextDirection(heuristic).setIncludePad(false).setMaxLines(1)
            .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE);
        if (Build.VERSION.SDK_INT >= 28) builder.setUseLineSpacingFromFallbacks(true);
        layout = builder.build();
        float advance = layout.getLineWidth(0);
        origin = layout.getParagraphDirection(0) < 0 ? width - advance : 0;
        if (Build.VERSION.SDK_INT >= 34 && !text.isEmpty()) {
            // Query advances for the entire line at once. Re-shaping a long line
            // for each character turns editor caret and selection layout quadratic.
            characterBounds = new float[Math.multiplyExact(text.length(), 4)];
            layout.fillCharacterBounds(0, text.length(), characterBounds, 0);
        }
        int baseline = layout.getLineBaseline(0);
        Rect ink = new Rect();
        paint.getTextBounds(text, 0, text.length(), ink);
        metrics[0] = advance;
        metrics[1] = baseline;
        metrics[2] = layout.getLineBottom(0) - baseline;
        Paint.FontMetrics fm = paint.getFontMetrics();
        metrics[7] = -fm.ascent; metrics[8] = fm.descent;
        Path outline = new Path();
        RectF cap = new RectF();
        paint.getTextPath("H", 0, 1, 0, 0, outline);
        outline.computeBounds(cap, true);
        metrics[9] = Math.max(0, -cap.top);
        if (ink.isEmpty()) {
            metrics[3] = metrics[4] = metrics[5] = metrics[6] = 0;
        } else {
            int x = Math.min(ink.left, 0) - 1;
            int y = Math.min(ink.top + baseline, 0) - 1;
            metrics[3] = x; metrics[4] = y;
            metrics[5] = Math.max(ink.right, (int)Math.ceil(advance)) + 1 - x;
            metrics[6] = Math.max(ink.bottom + baseline, layout.getLineBottom(0)) + 1 - y;
        }
    }

    public float[] metrics() { return metrics; }
    public boolean hasColor() { return mayHaveColor; }

    public float caret(int offset) {
        if (characterBounds != null && offset > 0 && offset < text.length()) {
            float before = characterBounds[4 * (offset - 1) + (layout.isRtlCharAt(offset - 1) ? 0 : 2)];
            float after = characterBounds[4 * offset + (layout.isRtlCharAt(offset) ? 2 : 0)];
            if (Math.abs(before - after) < 0.001f) return after - origin;
        }
        // Android resolves the strong caret at a bidi run boundary.
        return layout.getPrimaryHorizontal(offset) - origin;
    }

    public long cell(int start, int end) {
        float left, advance;
        if (characterBounds != null) {
            float lo = characterBounds[4 * start], hi = characterBounds[4 * start + 2];
            for (int i = start + 1; i < end; i++) {
                lo = Math.min(lo, characterBounds[4 * i]);
                hi = Math.max(hi, characterBounds[4 * i + 2]);
            }
            left = lo - origin;
            advance = hi - lo;
        } else {
            Path path = new Path();
            RectF bounds = new RectF();
            layout.getSelectionPath(start, end, path);
            path.computeBounds(bounds, true);
            left = path.isEmpty() ? caret(start) : bounds.left - origin;
            advance = bounds.width();
        }
        if (layout.isRtlCharAt(start)) advance = -advance;
        return ((long)Float.floatToRawIntBits(left) << 32) | (Float.floatToRawIntBits(advance) & 0xffffffffL);
    }

    /** Draws only the requested atlas tile, retaining the contextual glyph forms of the full line. */
    private int[] raster(int x, int y, int width, int height, int color) {
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            paint.setColor(color);
            Canvas canvas = new Canvas(bitmap);
            canvas.translate(-x - origin, -y);
            layout.draw(canvas);
            int[] rgba = new int[width * height];
            bitmap.getPixels(rgba, 0, width, 0, 0, width, height);
            return rgba;
        } finally {
            paint.setColor(Color.WHITE);
            bitmap.recycle();
        }
    }

    private static final class Tile {
        final int x, y, width, height;
        final byte[] alpha, rgba;
        Tile(int x, int y, int width, int height, boolean color) {
            this.x = x; this.y = y; this.width = width; this.height = height;
            alpha = new byte[width * height];
            rgba = color ? new byte[width * height * 4] : null;
        }
    }

    public synchronized byte[] mask(int x, int y, int width, int height, boolean color) {
        if (lastTile == null || lastTile.x != x || lastTile.y != y ||
            lastTile.width != width || lastTile.height != height) {
            Tile tile = new Tile(x, y, width, height, mayHaveColor);
            int[] white = raster(x, y, width, height, Color.WHITE);
            int[] black = mayHaveColor ? raster(x, y, width, height, Color.BLACK) : null;
            for (int i = 0; i < white.length; i++) {
                int pixel = white[i], alpha = pixel >>> 24;
                if (black == null || alpha == 0) {
                    tile.alpha[i] = (byte)alpha;
                    continue;
                }
                // Monochrome ink follows Paint's foreground. Native color glyphs are
                // invariant. Separate them even when a single styled run contains both.
                int dark = black[i], sum = 0;
                for (int shift = 0; shift <= 16; shift += 8)
                    sum += Math.max(0, ((pixel >>> shift) & 255) - ((dark >>> shift) & 255));
                int monochrome = (sum * alpha + 382) / 765;
                int intrinsic = alpha - monochrome;
                tile.alpha[i] = (byte)monochrome;
                if (intrinsic == 0) continue;
                for (int channel = 0; channel < 3; channel++) {
                    int component = (dark >>> (16 - 8 * channel)) & 255;
                    tile.rgba[i * 4 + channel] = (byte)Math.min(255, (component * alpha + intrinsic / 2) / intrinsic);
                }
                tile.rgba[i * 4 + 3] = (byte)intrinsic;
            }
            lastTile = tile;
        }
        return color ? lastTile.rgba : lastTile.alpha;
    }
}
