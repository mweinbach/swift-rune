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
import android.graphics.fonts.FontStyle;
import android.graphics.fonts.FontVariationAxis;
import android.graphics.fonts.Font;
import android.graphics.text.PositionedGlyphs;
import android.graphics.text.TextRunShaper;
import android.os.Build;
import android.os.Environment;
import android.os.LocaleList;
import android.icu.lang.UCharacter;
import android.icu.lang.UProperty;
import android.icu.text.Bidi;
import android.icu.text.BidiRun;
import android.text.Layout;
import android.text.PrecomputedText;
import android.text.StaticLayout;
import android.text.TextDirectionHeuristic;
import android.text.TextDirectionHeuristics;
import android.text.TextPaint;
import android.util.LruCache;
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
import java.util.Arrays;
import java.util.HashMap;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicLong;

/** Android line shaping and rasterization for the Rune R8 atlas. Called by the NDK bridge. */
public final class RuneText {
    private static final ArrayList<Face> faces = new ArrayList<>();
    private static HashMap<String, String> systemNames;
    private static File cacheDirectory;
    private static boolean bundledFontsReady;
    private final String text;
    private final TextPaint paint;
    private final String automaticWeightAxis;
    private final int direction;
    private StaticLayout layout;
    private float origin;
    private float[] characterBounds;
    private final float[] metrics = new float[10];
    private final boolean mayHaveColor;
    private Tile lastTile;
    private ArrayList<DirectionalRun> inkRuns;
    private char[] inkChars;
    private android.icu.text.BreakIterator inkGraphemes;
    private ArrayList<InkSpan> inkSpans;
    private NativeGlyphBounds inkBounds;

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
            if (old.name.equalsIgnoreCase(incoming.name) && old.weight == incoming.weight && old.italic == incoming.italic &&
                old.minWeight == incoming.minWeight && old.maxWeight == incoming.maxWeight) {
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

    // CSS Fonts orders these groups before considering distance within each group.
    private static int weightGroup(float candidate, int target) {
        if (target < 400) return candidate <= target ? 0 : 1;
        if (target > 500) return candidate >= target ? 0 : 1;
        if (candidate >= target && candidate <= 500) return 0;
        return candidate < target ? 1 : 2;
    }

    private static boolean betterMatch(Face candidate, Face best, int weight, boolean italic) {
        if (candidate.italic != best.italic) return candidate.italic == italic;
        float proposed = candidate.matchWeight(weight), current = best.matchWeight(weight);
        int a = weightGroup(proposed, weight), b = weightGroup(current, weight);
        if (a != b) return a < b;
        return Math.abs(proposed - weight) < Math.abs(current - weight);
    }

    private static synchronized Face selectFace(String stack, int weight, boolean italic, boolean mono) {
        for (String name : familyList(stack)) {
            if (name.isEmpty()) continue;
            Face best = null;
            for (Face face : faces) {
                if (!face.name.equalsIgnoreCase(name)) continue;
                if (best == null || betterMatch(face, best, weight, italic)) best = face;
            }
            if (best != null) {
                if (best.italic == italic) return best;
                return new Face(best.name, best.weight, italic, styled(best.typeface, weight, italic), best.hasColor,
                                best.minWeight, best.maxWeight);
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
        final float minWeight, maxWeight;

        Face(String name, int weight, boolean italic, Typeface typeface, boolean hasColor) {
            this(name, weight, italic, typeface, hasColor, weight, weight);
        }

        Face(String name, int weight, boolean italic, Typeface typeface, boolean hasColor,
             float minWeight, float maxWeight) {
            this.name = name; this.weight = weight; this.italic = italic; this.typeface = typeface; this.hasColor = hasColor;
            this.minWeight = minWeight; this.maxWeight = maxWeight;
        }

        float matchWeight(int target) { return Math.max(minWeight, Math.min(maxWeight, target)); }

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
                ByteBuffer fvar = Build.VERSION.SDK_INT >= 26 ? table(font, 0x66766172) : null;
                if (fvar != null && fvar.remaining() >= 16 && fvar.getInt(0) == 0x10000) {
                    int start = fvar.getShort(4) & 0xffff, axes = fvar.getShort(8) & 0xffff, stride = fvar.getShort(10) & 0xffff;
                    if (start >= 16 && stride >= 20 && start <= fvar.limit() && axes <= (fvar.limit() - start) / stride) {
                        for (int i = 0; i < axes; i++) {
                            int at = start + i * stride;
                            if (fvar.getInt(at) != 0x77676874) continue;
                            float min = fvar.getInt(at + 4) / 65536f, max = fvar.getInt(at + 12) / 65536f;
                            if (min >= 1 && max <= 1000 && min < max)
                                return new Face(family, weight, italic, typeface, color, min, max);
                        }
                    }
                }
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
        automaticWeightAxis = selected.minWeight == selected.maxWeight ? "" : "'wght' " + selected.matchWeight(weight);
        if (Build.VERSION.SDK_INT >= 26 && !automaticWeightAxis.isEmpty())
            paint.setFontVariationSettings(automaticWeightAxis);
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
        if (inkSpans != null) return;
        if (!language.isEmpty()) paint.setTextLocales(LocaleList.forLanguageTags(language));
        if (!features.isEmpty()) paint.setFontFeatureSettings(settings(features));
        if (Build.VERSION.SDK_INT >= 26 && !variations.isEmpty()) {
            String axes = settings(variations);
            if (!automaticWeightAxis.isEmpty() && !axes.contains("'wght'"))
                axes = axes.isEmpty() ? automaticWeightAxis : axes + "," + automaticWeightAxis;
            paint.setFontVariationSettings(axes);
        }
        shape();
    }

    private void shape() {
        lastTile = null;
        inkRuns = null;
        inkChars = null;
        inkBounds = null;
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

    // getTextRunAdvances assigns a shaped cluster's width to its first logical
    // UTF-16 index, including in RTL runs. Caret widths can subdivide the same
    // ligature. Keep the shaping indices separate from the selection geometry.
    private static final class DirectionalRun {
        final int start, end;
        final boolean rtl;
        float left;
        float[] edges;
        CapturedGlyphs glyphs;
        boolean captured;
        DirectionalRun(int start, int end, boolean rtl) {
            this.start = start;
            this.end = end;
            this.rtl = rtl;
        }
        void measureAdvances(RuneText line) {
            if (edges != null) return;
            int count = end - start;
            edges = new float[count + 1];
            if (Build.VERSION.SDK_INT >= 29) {
                line.paint.getTextRunAdvances(line.inkChars, start, count, start, count, rtl, edges, 1);
            } else {
                float[] widths = new float[count];
                line.paint.getTextWidths(line.inkChars, start, count, widths);
                System.arraycopy(widths, 0, edges, 1, count);
            }
            for (int i = 1; i <= count; i++) edges[i] += edges[i - 1];
        }

        void measure(RuneText line) {
            if (captured) return;
            measureAdvances(line);
            left = Float.intBitsToFloat((int)(line.cell(start, end) >>> 32));
            if (Build.VERSION.SDK_INT >= 31) glyphs = CapturedGlyphs.capture(line, this);
            captured = true;
        }

        int nextOwner(int index) {
            while (index > start && index < end && edges[index - start + 1] == edges[index - start]) index++;
            return index;
        }
    }

    // A contextual substitution or a GPOS pair can change even when the cluster
    // itself survives re-shaping. Draw the original IDs at the original positions.
    private static final class CapturedGlyphs {
        final PositionedGlyphs shaped;
        final int[] ids, fences;
        final float[] positions;
        final byte[] synthetic;

        private CapturedGlyphs(PositionedGlyphs shaped, int[] fences, Typeface typeface) {
            this.shaped = shaped;
            this.fences = fences;
            int count = shaped.glyphCount();
            ids = new int[count];
            positions = new float[2 * count];
            synthetic = new byte[count];
            for (int i = 0; i < count; i++) {
                ids[i] = shaped.getGlyphId(i);
                positions[2 * i] = shaped.getGlyphX(i);
                positions[2 * i + 1] = shaped.getGlyphY(i);
                boolean bold, italic;
                if (Build.VERSION.SDK_INT >= 35) {
                    bold = shaped.getFakeBold(i);
                    italic = shaped.getFakeItalic(i);
                } else {
                    FontStyle actual = shaped.getFont(i).getStyle();
                    bold = typeface.getWeight() >= 600 && typeface.getWeight() - actual.getWeight() >= 200;
                    italic = typeface.isItalic() && actual.getSlant() == FontStyle.FONT_SLANT_UPRIGHT;
                }
                synthetic[i] = (byte)((bold ? 1 : 0) | (italic ? 2 : 0));
            }
        }

        static CapturedGlyphs capture(RuneText line, DirectionalRun run) {
            int length = run.end - run.start;
            PositionedGlyphs shaped = TextRunShaper.shapeTextRun(
                line.text, run.start, length, run.start, length, run.left, line.metrics[1], run.rtl, line.paint);
            int count = shaped.glyphCount(), clusters = 0;
            for (int at = run.start; at < run.end; at = run.nextOwner(at + 1)) clusters++;
            int[] fences = new int[length + 1];
            int used = 0;
            // Every positive-advance cluster contains at least one glyph.
            boolean onePerCluster = run.edges[1] != 0 && clusters == count;
            for (int at = run.start; at < run.end;) {
                int next = run.nextOwner(at + 1), n = 1;
                if (!onePerCluster) {
                    PositionedGlyphs probe = TextRunShaper.shapeTextRun(
                        line.text, at, next - at, run.start, length, 0, 0, run.rtl, line.paint);
                    n = probe.glyphCount();
                    if (n > count - used) return null;
                    int first = run.rtl ? count - used - n : used;
                    for (int j = 0; j < n; j++) {
                        if (probe.getGlyphId(j) != shaped.getGlyphId(first + j) ||
                            !probe.getFont(j).equals(shaped.getFont(first + j))) return null;
                    }
                }
                used += n;
                // A range ending inside the cluster already includes its owner.
                Arrays.fill(fences, at - run.start + 1, next - run.start + 1, used);
                at = next;
            }
            return used == count ? new CapturedGlyphs(shaped, fences, line.paint.getTypeface()) : null;
        }

        private int edge(InkSpan span, boolean first) {
            return edge(span.run, span.start, span.end, first);
        }

        private int edge(DirectionalRun run, int start, int end, boolean first) {
            int a = fences[start - run.start], b = fences[end - run.start];
            return run.rtl ? ids.length - (first ? b : a) : (first ? a : b);
        }

        private int single(DirectionalRun run, int owner) {
            if (owner != run.nextOwner(owner)) return -1;
            int next = run.nextOwner(owner + 1);
            int i = edge(run, owner, next, true);
            return edge(run, owner, next, false) == i + 1 ? i : -1;
        }

        private static void applyStyle(Paint paint, int synthetic) {
            paint.setFakeBoldText((synthetic & 1) != 0);
            paint.setTextSkewX((synthetic & 2) != 0 ? -0.25f : 0f);
        }

        void bounds(DirectionalRun run, int start, int end, Paint paint, RectF result, RectF glyph) {
            int limit = edge(run, start, end, false);
            for (int i = edge(run, start, end, true); i < limit; i++) {
                applyStyle(paint, synthetic[i]);
                shaped.getFont(i).getGlyphBounds(ids[i], paint, glyph);
                glyph.offset(positions[2 * i], positions[2 * i + 1]);
                result.union(glyph);
            }
            applyStyle(paint, 0);
        }

        void draw(Canvas canvas, InkSpan span, Paint paint) {
            int limit = edge(span, false);
            for (int i = edge(span, true); i < limit;) {
                Font font = shaped.getFont(i);
                int end = i + 1;
                while (end < limit && synthetic[i] == synthetic[end] && font.equals(shaped.getFont(end))) end++;
                applyStyle(paint, synthetic[i]);
                canvas.drawGlyphs(ids, i, positions, i * 2, end - i, font, paint);
                i = end;
            }
            applyStyle(paint, 0);
        }
    }

    private static final class InkSpan {
        final DirectionalRun run;
        final int start, end;
        final float x;
        InkSpan(DirectionalRun run, int start, int end) {
            this.run = run;
            this.start = start;
            this.end = end;
            x = run.left + (run.rtl ? run.edges[run.end - run.start] - run.edges[end - run.start]
                                    : run.edges[start - run.start]);
        }
    }

    private RuneText(RuneText parent, ArrayList<InkSpan> spans) {
        text = parent.text;
        automaticWeightAxis = parent.automaticWeightAxis;
        direction = parent.direction;
        paint = new TextPaint(parent.paint);
        mayHaveColor = parent.mayHaveColor;
        inkSpans = spans;
        System.arraycopy(parent.metrics, 0, metrics, 0, metrics.length);
        Rect bounds = new Rect();
        if (!spans.isEmpty()) {
            if (Build.VERSION.SDK_INT >= 28) {
                RectF positioned = new RectF(), glyph = new RectF();
                for (InkSpan span : spans) {
                    if (span.run.glyphs != null) span.run.glyphs.bounds(span.run, span.start, span.end, paint, positioned, glyph);
                    else {
                        if (parent.inkBounds == null) parent.inkBounds = new NativeGlyphBounds(parent);
                        parent.inkBounds.collect(span, metrics[1], positioned);
                    }
                }
                if (!positioned.isEmpty()) {
                    positioned.roundOut(bounds);
                    bounds.inset(-1, -1);
                }
            } else {
                // Older Androids expose rasterization and advances but no glyph
                // bounds. Scan bounded tiles so long lines never need a line bitmap.
                int left = (int)metrics[3], top = (int)metrics[4];
                int right = left + (int)metrics[5], bottom = top + (int)metrics[6];
                for (int y = top; y < bottom; y += 64) for (int x = left; x < right; x += 256) {
                    int w = Math.min(256, right - x), h = Math.min(64, bottom - y);
                    int[] pixels = raster(x, y, w, h, Color.WHITE);
                    for (int i = 0; i < pixels.length; i++) if ((pixels[i] >>> 24) != 0) {
                        int px = x + i % w, py = y + i / w;
                        bounds.union(px, py, px + 1, py + 1);
                    }
                }
            }
        }
        metrics[3] = bounds.left; metrics[4] = bounds.top;
        metrics[5] = bounds.width(); metrics[6] = bounds.height();
    }

    private static final class NativeGlyphBounds {
        final PrecomputedText paragraph;
        NativeGlyphBounds(RuneText line) {
            PrecomputedText.Params params = new PrecomputedText.Params.Builder(line.paint)
                .setTextDirection(line.layout.getParagraphDirection(0) < 0 ? TextDirectionHeuristics.RTL : TextDirectionHeuristics.LTR)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .build();
            paragraph = PrecomputedText.create(line.text, params);
        }
        void collect(InkSpan span, float baseline, RectF result) {
            Rect local = new Rect();
            paragraph.getBounds(span.start, span.end, local);
            RectF positioned = new RectF(local);
            positioned.offset(span.x, baseline);
            result.union(positioned);
        }
    }

    private void prepareInkRuns() {
        if (inkRuns != null) return;
        ArrayList<DirectionalRun> runs = new ArrayList<>();
        inkChars = text.toCharArray();
        Bidi bidi = new Bidi(text, layout.getParagraphDirection(0) < 0
            ? Bidi.DIRECTION_RIGHT_TO_LEFT : Bidi.DIRECTION_LEFT_TO_RIGHT);
        int visibleEnd = layout.getLineEnd(0);
        for (int offset = 0; offset < visibleEnd; ) {
            BidiRun run = bidi.getLogicalRun(offset);
            int limit = Math.min(run.getLimit(), visibleEnd);
            // Minikin shapes words on either side of U+0020 independently.
            // Capture them lazily so animating one word in a long label only
            // allocates native glyph positions for that word. StaticLayout
            // advances tabs to tab stops and never paints their ink.
            int startOfText = offset;
            for (int i = offset; i < limit; i++) {
                char separator = inkChars[i];
                if (separator != ' ' && separator != '\t' && separator != '\n') continue;
                if (startOfText < i) runs.add(new DirectionalRun(startOfText, i, run.isOddRun()));
                if (separator == ' ') runs.add(new DirectionalRun(i, i + 1, run.isOddRun()));
                startOfText = i + 1;
            }
            if (startOfText < limit) runs.add(new DirectionalRun(startOfText, limit, run.isOddRun()));
            offset = limit;
        }
        inkRuns = runs;
    }

    /** Retains the full directional context while selecting by logical cluster owner. */
    public synchronized RuneText extractInk(int start, int end) {
        if (inkSpans != null || start < 0 || start > end || end > text.length()) return null;
        prepareInkRuns();
        ArrayList<InkSpan> spans = new ArrayList<>();
        for (int i = firstInkRun(start); i < inkRuns.size(); i++) {
            DirectionalRun run = inkRuns.get(i);
            if (run.start >= end) break;
            run.measure(this);
            int first = run.nextOwner(Math.max(start, run.start));
            int limit = run.nextOwner(Math.min(end, run.end));
            if (first < limit) spans.add(new InkSpan(run, first, limit));
        }
        return new RuneText(this, spans);
    }

    private int firstInkRun(int owner) {
        int lo = 0, hi = inkRuns.size();
        while (lo < hi) {
            int mid = lo + (hi - lo) / 2;
            if (inkRuns.get(mid).end <= owner) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /** The first logical UTF-16 index of the shaping cluster supplying this position's ink. */
    public synchronized int clusterOwner(int index) {
        // Older APIs cannot measure the advances in an explicitly directed run.
        if (Build.VERSION.SDK_INT < 29 || inkSpans != null || index < 0 || index >= text.length()) return -1;
        prepareInkRuns();
        int slot = firstInkRun(index);
        if (slot == inkRuns.size()) return index;
        DirectionalRun run = inkRuns.get(slot);
        if (index <= run.start) return index;
        run.measureAdvances(this);
        if (run.edges[index - run.start] != run.edges[index - run.start + 1]) return index;
        int count = run.end - run.start;
        if (inkGraphemes == null) {
            inkGraphemes = android.icu.text.BreakIterator.getCharacterInstance(Locale.ROOT);
            inkGraphemes.setText(text);
        }
        if (!inkGraphemes.isBoundary(index)) index = Math.max(run.start, inkGraphemes.preceding(index));
        if (index <= run.start || run.edges[index - run.start] != run.edges[index - run.start + 1]) return index;
        // A zero-width grapheme (a format control or a zero-advance font glyph) can
        // have an independent owner. A ligature continuation has an advance when
        // its grapheme is shaped separately with the original context.
        int end = Math.min(run.end, inkGraphemes.following(index));
        if (paint.getTextRunAdvances(inkChars, index, end - index, run.start, count, run.rtl, null, 0) == 0) return index;
        do { index--; } while (index > run.start && run.edges[index - run.start] == run.edges[index - run.start + 1]);
        return index;
    }

    private DirectionalRun ownerRun(int owner) {
        if (Build.VERSION.SDK_INT < 31 || inkSpans != null || owner < 0 || owner >= text.length()) return null;
        prepareInkRuns();
        int index = firstInkRun(owner);
        if (index == inkRuns.size()) return null;
        DirectionalRun run = inkRuns.get(index);
        if (owner < run.start) return null;
        run.measure(this);
        return run.glyphs != null ? run : null;
    }

    /** Shares a single source glyph's packed GPU curves across independently shaped layouts. */
    public synchronized long[] outlineSingle(int owner) {
        DirectionalRun run = ownerRun(owner);
        if (run == null) return null;
        CapturedGlyphs ink = run.glyphs;
        int i = ink.single(run, owner);
        if (i < 0) return null;
        NativeOutlines.Face face = NativeOutlines.eligibleFace(ink, i);
        if (face == null) return null;
        long style = face.style(paint, (ink.synthetic[i] & 2) != 0);
        return new long[] {style, ink.ids[i], ((long)Float.floatToRawIntBits(ink.positions[2 * i]) << 32)
            | (Float.floatToRawIntBits(ink.positions[2 * i + 1]) & 0xffffffffL), face.paths.cjk ? 3 : 1};
    }

    public synchronized float[] outlineUnplaced(int owner) {
        DirectionalRun run = ownerRun(owner);
        if (run == null) return null;
        CapturedGlyphs ink = run.glyphs;
        int i = ink.single(run, owner);
        if (i < 0) return null;
        NativeOutlines.Face face = NativeOutlines.eligibleFace(ink, i);
        if (face == null) return null;
        float[] path = face.paths.glyph(ink.ids[i]);
        if (path == null || path.length > 7 * 65536) return null;
        float[] result = new float[path.length];
        NativeOutlines.writePath(result, 0, path, face.paths, paint, ink.synthetic[i], 0, 0);
        return result;
    }

    public synchronized double[] appleHintMetrics(int owner) {
        DirectionalRun run = ownerRun(owner);
        if (run == null) return null;
        CapturedGlyphs ink = run.glyphs;
        int i = ink.single(run, owner);
        if (i < 0 || ink.synthetic[i] != 0) return null;
        NativeOutlines.Face face = NativeOutlines.eligibleFace(ink, i);
        return face == null ? null : face.paths.appleHintMetrics();
    }

    /** Curves of the original native glyph IDs. The line origin is top left and y increases down. */
    public synchronized float[] outlineCommands() {
        if (Build.VERSION.SDK_INT < 31 || inkSpans == null) return null;
        return NativeOutlines.commands(inkSpans, paint);
    }

    /** Each record carries a UTF-16 cluster owner followed by the raw float bits of its ink bounds. */
    public synchronized int[] outlineRegions() {
        if (Build.VERSION.SDK_INT < 31 || inkSpans != null) return null;
        prepareInkRuns();
        int[] regions = new int[80];
        int used = 0;
        RectF bounds = new RectF(), glyph = new RectF();
        for (DirectionalRun run : inkRuns) {
            run.measure(this);
            if (run.glyphs == null) return null;
            for (int owner = run.start; owner < run.end;) {
                int next = run.nextOwner(owner + 1);
                bounds.setEmpty();
                run.glyphs.bounds(run, owner, next, paint, bounds, glyph);
                if (!bounds.isEmpty()) {
                    // Skia rounds these native glyph bounds for the mask. Include its filter gutter.
                    if (used > regions.length - 5) {
                        if (regions.length > Integer.MAX_VALUE / 2) return null;
                        regions = Arrays.copyOf(regions, regions.length * 2);
                    }
                    regions[used++] = owner;
                    regions[used++] = Float.floatToRawIntBits((float)Math.floor(bounds.left) - 1);
                    regions[used++] = Float.floatToRawIntBits((float)Math.floor(bounds.top) - 1);
                    regions[used++] = Float.floatToRawIntBits((float)Math.ceil(bounds.right) + 1);
                    regions[used++] = Float.floatToRawIntBits((float)Math.ceil(bounds.bottom) + 1);
                }
                owner = next;
            }
        }
        return Arrays.copyOf(regions, used);
    }

    // Kept in an API-31-only class so older Android releases can load the R8 bridge.
    private static final class NativeOutlines {
        private static final AtomicLong nextStyle = new AtomicLong(1);
        private static final class Face {
            final RuneGlyphPaths paths;
            // Unique IDs survive cache eviction. Existing frames can still reference their packed curves.
            final LruCache<Long, Long> styles = new LruCache<Long, Long>(32) {
                @Override protected Long create(Long key) { return nextStyle.getAndAdd(2); }
            };
            Face(Font font) {
                RuneGlyphPaths source = RuneGlyphPaths.open(font.getBuffer(), font.getTtcIndex(), false);
                FontVariationAxis[] axes = font.getAxes();
                if (source != null && axes != null) {
                    for (FontVariationAxis axis : axes) {
                        if (!source.matchesAxis(axis.getTag(), axis.getStyleValue())) { source = null; break; }
                    }
                }
                paths = source;
            }

            long style(Paint paint, boolean italic) {
                long key = ((long)Float.floatToRawIntBits(paint.getTextSize()) << 32)
                    | (Float.floatToRawIntBits(paint.getTextScaleX()) & 0xffffffffL);
                return styles.get(key) + (italic ? 1 : 0);
            }
        }
        private static final LruCache<Font, Face> faces = new LruCache<Font, Face>(12) {
            @Override protected Face create(Font font) { return new Face(font); }
        };

        private static Face eligibleFace(CapturedGlyphs ink, int i) {
            // Synthetic bold modifies the contour, so use Android's native glyph mask.
            if ((ink.synthetic[i] & 1) != 0) return null;
            Face face = faces.get(ink.shaped.getFont(i));
            if (face.paths == null) return null;
            if (Build.VERSION.SDK_INT >= 35) {
                float weight = ink.shaped.getWeightOverride(i);
                float italic = ink.shaped.getItalicOverride(i);
                if ((weight != PositionedGlyphs.NO_OVERRIDE && !face.paths.matchesAxis("wght", weight)) ||
                    (italic != PositionedGlyphs.NO_OVERRIDE && !face.paths.matchesAxis("ital", italic))) return null;
            } else if (face.paths.variable) {
                // The native per-glyph axis overrides became public in API 35.
                return null;
            }
            return face;
        }

        private static void writePath(float[] target, int at, float[] path, RuneGlyphPaths face,
                                      Paint paint, byte synthetic, float x, float y) {
            float sy = paint.getTextSize() / face.unitsPerEm;
            float sx = sy * paint.getTextScaleX();
            float skew = (synthetic & 2) == 0 ? 0 : -0.25f;
            for (int k = 0; k < path.length; k += 7, at += 7) {
                int verb = (int)path[k];
                target[at] = verb;
                int pairs = verb == 4 ? 0 : (verb == 2 ? 2 : (verb == 3 ? 3 : 1));
                for (int j = 0; j < pairs; j++) {
                    float dy = -sy * path[k + 2 + 2 * j];
                    target[at + 1 + 2 * j] = x + sx * path[k + 1 + 2 * j] + skew * dy;
                    target[at + 2 + 2 * j] = y + dy;
                }
            }
        }

        static float[] commands(ArrayList<InkSpan> spans, Paint paint) {
            float[] result = new float[0];
            int used = 0;
            for (InkSpan span : spans) {
                CapturedGlyphs ink = span.run.glyphs;
                if (ink == null) return null;
                int end = ink.edge(span, false);
                for (int i = ink.edge(span, true); i < end; i++) {
                    Face face = eligibleFace(ink, i);
                    if (face == null) return null;
                    float[] path = face.paths.glyph(ink.ids[i]);
                    // A huge cluster is still drawable through the native raster path.
                    if (path == null || path.length > 7 * 65536 - used) return null;
                    if (used + path.length > result.length) {
                        result = Arrays.copyOf(result, Math.max(used + path.length, Math.max(56, result.length * 2)));
                    }
                    writePath(result, used, path, face.paths, paint, ink.synthetic[i],
                              ink.positions[i * 2], ink.positions[i * 2 + 1]);
                    used += path.length;
                }
            }
            return Arrays.copyOf(result, used);
        }
    }

    /** Draws only the requested atlas tile, retaining the contextual glyph forms of the full line. */
    private int[] raster(int x, int y, int width, int height, int color) {
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            paint.setColor(color);
            Canvas canvas = new Canvas(bitmap);
            if (inkSpans == null) {
                canvas.translate(-x - origin, -y);
                layout.draw(canvas);
            } else {
                canvas.translate(-x, -y);
                for (InkSpan span : inkSpans) {
                    if (span.run.glyphs != null) span.run.glyphs.draw(canvas, span, paint);
                    else canvas.drawTextRun(text, span.start, span.end, span.run.start, span.run.end,
                                            span.x, metrics[1], span.run.rtl, paint);
                }
            }
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
