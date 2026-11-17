package dev.rune;

import java.nio.BufferUnderflowException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;

/** Unhinted TrueType contours for glyph IDs already shaped by Android's font stack. */
final class RuneGlyphPaths {
    private static final int TTC = 0x74746366, HEAD = 0x68656164, MAXP = 0x6d617870;
    private static final int LOCA = 0x6c6f6361, GLYF = 0x676c7966, FVAR = 0x66766172;
    private static final int HHEA = 0x68686561, HMTX = 0x686d7478;
    private static final int MAX_POINTS = 65536, MAX_COMPONENTS = 1024, MAX_DEPTH = 16;
    private static final int CACHE_FLOATS = 65536;
    private static final float[] EMPTY = new float[0];
    final int unitsPerEm;
    final boolean variable;
    final boolean cjk;
    private final int glyphCount, metricCount;
    private final boolean longLocations;
    private final ByteBuffer locations, outlines, metrics;
    private final ByteBuffer post, names;
    private final int maxY;
    private boolean computedHintMetrics;
    private double[] hintMetrics;
    private final int[] axisTags;
    private final float[] axisDefaults;
    private final LinkedHashMap<Integer, float[]> paths = new LinkedHashMap<>(64, 0.75f, true);
    private int cachedFloats;

    private RuneGlyphPaths(int units, int glyphs, boolean longLocations, ByteBuffer loca, ByteBuffer glyf,
                           int metricCount, ByteBuffer metrics, ByteBuffer variations, boolean cjk,
                           int maxY, ByteBuffer post, ByteBuffer names) {
        this.unitsPerEm = units;
        this.glyphCount = glyphs;
        this.longLocations = longLocations;
        this.locations = loca;
        this.outlines = glyf;
        this.metricCount = metricCount;
        this.metrics = metrics;
        this.cjk = cjk;
        this.maxY = maxY;
        this.post = post;
        this.names = names;
        variable = variations != null;
        int axes = variable ? variations.getShort(8) & 0xffff : 0;
        if (axes > 256) throw new IllegalArgumentException();
        axisTags = new int[axes];
        axisDefaults = new float[axes];
        if (variable) {
            int offset = variations.getShort(4) & 0xffff, stride = variations.getShort(10) & 0xffff;
            if (variations.getInt(0) != 0x00010000 || offset < 16 || stride < 20 ||
                (long)offset + (long)axes * stride > variations.limit()) throw new IllegalArgumentException();
            for (int i = 0; i < axes; i++) {
                int at = offset + i * stride;
                axisTags[i] = variations.getInt(at);
                int value = variations.getInt(at + 8);
                if (value < variations.getInt(at + 4) || value > variations.getInt(at + 12))
                    throw new IllegalArgumentException();
                axisDefaults[i] = value / 65536.0f;
            }
        }
    }

    /** Axes absent from the file do not change its contours. */
    boolean matchesAxis(String tag, float value) {
        if (tag == null || tag.length() != 4 || Float.isNaN(value) || Float.isInfinite(value)) return false;
        int key = (tag.charAt(0) << 24) | (tag.charAt(1) << 16) | (tag.charAt(2) << 8) | tag.charAt(3);
        for (int i = 0; i < axisTags.length; i++) if (axisTags[i] == key) return value == axisDefaults[i];
        return true;
    }

    private static ByteBuffer range(ByteBuffer source, int start, int size) {
        if (start < 0 || size < 0 || start > source.limit() - size) throw new IllegalArgumentException();
        ByteBuffer region = source.duplicate();
        region.position(start);
        region.limit(start + size);
        return region.slice().order(ByteOrder.BIG_ENDIAN);
    }

    static RuneGlyphPaths open(ByteBuffer source, int ttcIndex, boolean hasNonDefaultVariations) {
        if (source == null || ttcIndex < 0 || hasNonDefaultVariations) return null;
        try {
            ByteBuffer data = source.asReadOnlyBuffer().order(ByteOrder.BIG_ENDIAN);
            data.position(0);
            int face = 0;
            if (data.getInt(0) == TTC) {
                int count = data.getInt(8);
                if (count < 1 || count > (data.limit() - 12) / 4 || ttcIndex >= count) return null;
                face = data.getInt(12 + ttcIndex * 4);
            } else if (ttcIndex != 0) return null;

            ByteBuffer directory = range(data, face, 12);
            int version = directory.getInt(0);
            if (version != 0x00010000 && version != 0x74727565) return null;
            int count = directory.getShort(4) & 0xffff;
            ByteBuffer tables = range(data, face + 12, 16 * count);
            ByteBuffer head = null, maxp = null, loca = null, glyf = null, variations = null, hhea = null, hmtx = null;
            ByteBuffer post = null, names = null;
            boolean cjk = false;
            for (int i = 0; i < count; i++) {
                int tag = tables.getInt();
                tables.getInt(); // checksum
                int offset = tables.getInt(), length = tables.getInt();
                if (offset < 0 || length < 0 || offset > data.limit() - length) return null;
                switch (tag) {
                    case 0x706f7374: post = range(data, offset, length); break;
                    case 0x6e616d65: names = range(data, offset, length); break;
                    case 0x4f532f32: // OS/2 ulUnicodeRange2: Han, kana or Hangul.
                        cjk = length >= 50 && (data.getInt(offset + 46) & ((1 << 17) | (1 << 24) | (1 << 27))) != 0;
                        break;
                    case HEAD: head = range(data, offset, length); break;
                    case MAXP: maxp = range(data, offset, length); break;
                    case LOCA: loca = range(data, offset, length); break;
                    case GLYF: glyf = range(data, offset, length); break;
                    case FVAR: variations = range(data, offset, length); break;
                    case HHEA: hhea = range(data, offset, length); break;
                    case HMTX: hmtx = range(data, offset, length); break;
                    case 0x56415243: /* VARC */ case 0x43464620: /* CFF  */ case 0x43464632: /* CFF2 */
                        return null;
                    // A single outline cannot represent a layered, bitmap or SVG palette glyph.
                    case 0x434f4c52: /* COLR */ case 0x53564720: /* SVG  */
                    case 0x73626978: /* sbix */ case 0x43424454: /* CBDT */
                    case 0x45424454: /* EBDT */ case 0x62646174: /* bdat */
                        return null;
                    default: break;
                }
            }
            if (head == null || maxp == null || loca == null || glyf == null || hhea == null || hmtx == null ||
                head.getInt(12) != 0x5f0f3cf5 || head.getShort(52) != 0 || maxp.getInt(0) != 0x00010000) return null;
            int units = head.getShort(18) & 0xffff, glyphs = maxp.getShort(4) & 0xffff;
            int format = head.getShort(50);
            int metricCount = hhea.getShort(34) & 0xffff;
            if (units < 16 || units > 16384 || glyphs == 0 || (format != 0 && format != 1) ||
                metricCount < 1 || metricCount > glyphs || hmtx.limit() < 2 * (glyphs + metricCount) ||
                loca.limit() < (glyphs + 1) * (format == 0 ? 2 : 4)) return null;
            return new RuneGlyphPaths(units, glyphs, format != 0, loca, glyf, metricCount, hmtx, variations, cjk,
                                      head.getShort(42), post, names);
        } catch (IllegalArgumentException | IndexOutOfBoundsException | BufferUnderflowException e) {
            return null;
        }
    }

    // Glyphs are identified by their PostScript names even when an authored cmap remaps o or X.
    private int namedGlyph(int standard, int character) {
        if (post == null || post.limit() < 4) return -1;
        int version = post.getInt(0);
        if (version == 0x10000) return standard < glyphCount ? standard : -1;
        if (version != 0x20000 || post.limit() < 34) return -1;
        int count = post.getShort(32) & 0xffff, strings = 34 + 2 * count;
        if (count != glyphCount || strings > post.limit()) return -1;
        for (int g = 0; g < count; g++) if ((post.getShort(34 + 2 * g) & 0xffff) == standard) return g;
        int nameIndex = 258;
        for (int p = strings; p < post.limit() && nameIndex <= 65535; nameIndex++) {
            int length = post.get(p++) & 0xff;
            if (length > post.limit() - p) return -1;
            if (length == 1 && post.get(p) == character) {
                for (int g = 0; g < count; g++) if ((post.getShort(34 + 2 * g) & 0xffff) == nameIndex) return g;
                return -1;
            }
            p += length;
        }
        return -1;
    }

    private double controlTop(int glyphIndex) {
        float[] path = glyph(glyphIndex);
        double top = Double.NEGATIVE_INFINITY;
        if (path != null) for (int at = 0; at < path.length; at += 7) {
            int verb = (int)path[at];
            if (verb == 4) continue;
            top = Math.max(top, path[at + 2]);
            if (verb == 2) top = Math.max(top, path[at + 4]);
        }
        return top;
    }

    private double descriptorStem() {
        if (names == null || names.limit() < 6) return 0;
        int count = names.getShort(2) & 0xffff, strings = names.getShort(4) & 0xffff;
        if (count > (names.limit() - 6) / 12) return 0;
        for (int i = 0; i < count; i++) {
            int at = 6 + 12 * i, platform = names.getShort(at) & 0xffff;
            if (names.getShort(at + 6) != 6 || platform > 3 || platform == 2) continue;
            int len = names.getShort(at + 8) & 0xffff, start = strings + (names.getShort(at + 10) & 0xffff);
            if (len == 0 || start > names.limit() - len) continue;
            ByteBuffer name = range(names, start, len);
            String value = (platform == 1 ? StandardCharsets.US_ASCII : StandardCharsets.UTF_16BE).decode(name).toString();
            if (value.startsWith(".SFNS")) return 79;
            if (value.equals("Helvetica")) return 85;
        }
        return 0;
    }

    /** Original glyf control bounds used by Rune's small-size CoreGraphics-style Y fit. */
    synchronized double[] appleHintMetrics() {
        if (!computedHintMetrics) {
            computedHintMetrics = true;
            double x = controlTop(namedGlyph(82, 'o')), cap = controlTop(namedGlyph(59, 'X'));
            if (Double.isFinite(x) && Double.isFinite(cap))
                hintMetrics = new double[] {unitsPerEm, x, cap, maxY, descriptorStem()};
        }
        return hintMetrics == null ? null : hintMetrics.clone();
    }

    /** Borrowed immutable command packet. An empty array denotes a real empty outline. */
    synchronized float[] glyph(int id) {
        if (id < 0 || id >= glyphCount) return null;
        float[] result = paths.get(id);
        if (result != null) return result;
        try {
            Points points = new Points();
            int dx = append(id, points, new int[MAX_DEPTH + 1], 0);
            if (dx != 0) for (int i = 0; i < points.count; i++) points.x[i] += dx;
            result = points.commands();
        } catch (IllegalArgumentException | IndexOutOfBoundsException | BufferUnderflowException e) {
            return null;
        }
        if (result.length <= CACHE_FLOATS) {
            Iterator<Map.Entry<Integer, float[]>> oldest = paths.entrySet().iterator();
            while (paths.size() >= 256 || cachedFloats + result.length > CACHE_FLOATS) {
                cachedFloats -= oldest.next().getValue().length;
                oldest.remove();
            }
            paths.put(id, result);
            cachedFloats += result.length;
        }
        return result;
    }

    private int location(int id) {
        return longLocations ? locations.getInt(id * 4) : 2 * (locations.getShort(id * 2) & 0xffff);
    }

    // Component points stay in design space. Only the completed glyph is
    // translated to its left phantom point (including inherited metrics).
    private int append(int id, Points points, int[] stack, int depth) {
        if (id >= glyphCount || depth > MAX_DEPTH || ++points.components > MAX_COMPONENTS)
            throw new IllegalArgumentException();
        for (int i = 0; i < depth; i++) if (stack[i] == id) throw new IllegalArgumentException();
        stack[depth] = id;
        int start = location(id), end = location(id + 1);
        if (start < 0 || end < start || end > outlines.limit()) throw new IllegalArgumentException();
        int metric = id < metricCount ? id * 4 + 2 : metricCount * 4 + (id - metricCount) * 2;
        int bearing = metrics.getShort(metric);
        if (start == end) return bearing;
        ByteBuffer record = range(outlines, start, end - start);
        int contours = record.getShort();
        int offset = bearing - record.getShort(2);
        record.position(10); // contour count followed by the design bounding box
        if (contours >= 0) {
            if (contours > 0) simple(record, contours, points);
        } else if (contours == -1) {
            offset = composite(record, points, stack, depth, offset);
        } else {
            throw new IllegalArgumentException();
        }
        return offset;
    }

    private static void skipInstructions(ByteBuffer record) {
        int count = record.getShort() & 0xffff;
        if (count > record.remaining()) throw new IllegalArgumentException();
        record.position(record.position() + count);
    }

    private static void simple(ByteBuffer record, int contours, Points points) {
        int base = points.count, prev = -1;
        if (contours > record.remaining() / 2) throw new IllegalArgumentException();
        for (int i = 0; i < contours; i++) {
            int last = record.getShort() & 0xffff;
            if (last <= prev || last >= MAX_POINTS - base) throw new IllegalArgumentException();
            points.endContour(base + last);
            prev = last;
        }
        int count = prev + 1;
        skipInstructions(record);
        points.reserve(base + count);
        for (int i = base; i < base + count;) {
            int flag = record.get() & 0xff;
            if ((flag & 0x80) != 0) throw new IllegalArgumentException();
            int repeat = (flag & 8) == 0 ? 1 : 1 + (record.get() & 0xff);
            if (repeat > base + count - i) throw new IllegalArgumentException();
            Arrays.fill(points.flags, i, i + repeat, (byte)flag);
            i += repeat;
        }
        for (int axis = 0; axis < 2; axis++) {
            int position = 0, shortBit = 2 << axis, sameBit = 16 << axis;
            double[] coordinates = axis == 0 ? points.x : points.y;
            for (int i = base; i < base + count; i++) {
                int flag = points.flags[i];
                if ((flag & shortBit) != 0) {
                    int delta = record.get() & 0xff;
                    position += (flag & sameBit) != 0 ? delta : -delta;
                } else if ((flag & sameBit) == 0) position += record.getShort();
                if (position < Short.MIN_VALUE || position > Short.MAX_VALUE) throw new IllegalArgumentException();
                coordinates[i] = position;
            }
        }
        points.count = base + count;
    }

    private int composite(ByteBuffer record, Points p, int[] stack, int depth, int offset) {
        final int base = p.count;
        int flags;
        boolean instructions = false;
        do {
            flags = record.getShort() & 0xffff;
            if ((flags & 0xe010) != 0 || (flags & 0x1800) == 0x1800) throw new IllegalArgumentException();
            int id = record.getShort() & 0xffff;
            boolean xy = (flags & 2) != 0, words = (flags & 1) != 0;
            int a = words ? record.getShort() : record.get();
            int b = words ? record.getShort() : record.get();
            if (!xy) { a &= words ? 0xffff : 0xff; b &= words ? 0xffff : 0xff; }
            double xx = 1, xyScale = 0, yx = 0, yy = 1;
            switch (flags & 0xc8) {
                case 0: break;
                case 8: xx = yy = record.getShort() / 16384.0; break;
                case 0x40: xx = record.getShort() / 16384.0; yy = record.getShort() / 16384.0; break;
                case 0x80:
                    xx = record.getShort() / 16384.0; xyScale = record.getShort() / 16384.0;
                    yx = record.getShort() / 16384.0; yy = record.getShort() / 16384.0; break;
                default: throw new IllegalArgumentException();
            }
            int child = p.count;
            int childOffset = append(id, p, stack, depth + 1);
            if ((flags & 0x200) != 0) offset = childOffset; // USE_MY_METRICS
            for (int i = child; i < p.count; i++) {
                double x = p.x[i], y = p.y[i];
                p.x[i] = xx * x + yx * y;
                p.y[i] = xyScale * x + yy * y;
            }
            double dx, dy;
            if (!xy) {
                if (a >= child - base || b >= p.count - child) throw new IllegalArgumentException();
                dx = p.x[base + a] - p.x[child + b];
                dy = p.y[base + a] - p.y[child + b];
            } else if ((flags & 0x1800) == 0x0800) {
                // FreeType scales an offset by the length of each matrix row,
                // then rounds it in design units before device-space scaling.
                dx = scaledComponentOffset(a, xx, yx);
                dy = scaledComponentOffset(b, yy, xyScale);
            } else {
                dx = a; dy = b;
            }
            for (int i = child; i < p.count; i++) { p.x[i] += dx; p.y[i] += dy; }
            instructions |= (flags & 0x100) != 0;
        } while ((flags & 0x20) != 0);
        if (instructions) skipInstructions(record);
        return offset;
    }

    private static double scaledComponentOffset(int distance, double a, double b) {
        long fixedScale = Math.round(Math.hypot(a, b) * 65536);
        long magnitude = (Math.abs((long)distance) * fixedScale + 32768) >> 16;
        return distance < 0 ? -magnitude : magnitude;
    }

    /** Keeps the original control points until all point-indexed component transforms are applied. */
    private static final class Points {
        double[] x = new double[16], y = new double[16];
        byte[] flags = new byte[16];
        int[] ends = new int[4];
        int count, contours, components;

        void reserve(int needed) {
            if (needed <= x.length) return;
            int capacity = Math.max(needed, Math.min(MAX_POINTS, x.length * 2));
            x = Arrays.copyOf(x, capacity);
            y = Arrays.copyOf(y, capacity);
            flags = Arrays.copyOf(flags, capacity);
        }
        void endContour(int last) {
            if (contours >= MAX_POINTS) throw new IllegalArgumentException();
            if (contours == ends.length) ends = Arrays.copyOf(ends, ends.length * 2);
            ends[contours++] = last;
        }

        float[] commands() {
            if (count == 0) return EMPTY;
            float[] out = new float[(count + 2 * contours) * 7];
            int at = 0, first = 0;
            for (int c = 0; c < contours; c++) {
                int last = ends[c];
                // Start on the first real on-curve point. All-off-curve contours
                // start midway between the last and first controls.
                int start = first;
                while (start <= last && (flags[start] & 1) == 0) start++;
                boolean implied = start > last;
                double sx = implied ? (x[first] + x[last]) * 0.5 : x[start];
                double sy = implied ? (y[first] + y[last]) * 0.5 : y[start];
                out[at] = 0; out[at + 1] = (float)sx; out[at + 2] = (float)sy;
                at += 7;
                int i = implied ? first : start == last ? first : start + 1;
                int remaining = last - first + (implied ? 1 : 0);
                int control = -1;
                for (int n = 0; n < remaining; n++) {
                    boolean on = (flags[i] & 1) != 0;
                    if (control >= 0) {
                        out[at] = 2; out[at + 1] = (float)x[control]; out[at + 2] = (float)y[control];
                        out[at + 3] = (float)(on ? x[i] : (x[control] + x[i]) * 0.5);
                        out[at + 4] = (float)(on ? y[i] : (y[control] + y[i]) * 0.5);
                        at += 7;
                    } else if (on) {
                        out[at] = 1; out[at + 1] = (float)x[i]; out[at + 2] = (float)y[i];
                        at += 7;
                    }
                    control = on ? -1 : i;
                    i = i == last ? first : i + 1;
                }
                if (control >= 0) {
                    out[at] = 2; out[at + 1] = (float)x[control]; out[at + 2] = (float)y[control];
                    out[at + 3] = (float)sx; out[at + 4] = (float)sy; at += 7;
                }
                out[at] = 4; at += 7;
                first = last + 1;
            }
            return Arrays.copyOf(out, at);
        }
    }
}
