package dev.rune;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Extracts a still poster for releases whose BitmapFactory only reads static WebP. */
final class WebPPoster {
    private WebPPoster() {}

    private static boolean tag(byte[] data, int offset, String name) {
        for (int i = 0; i < 4; ++i) if (data[offset + i] != name.charAt(i)) return false;
        return true;
    }

    static boolean matches(byte[] data) {
        return data.length >= 30 && tag(data, 0, "RIFF") && tag(data, 8, "WEBP") &&
               tag(data, 12, "VP8X") && (data[20] & 2) != 0;
    }

    private static int uint24(byte[] data, int i) {
        return (data[i] & 255) | (data[i + 1] & 255) << 8 | (data[i + 2] & 255) << 16;
    }

    static Bitmap decode(byte[] data, int limit, int sideCap, int[] metadata) {
        ByteBuffer riff = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
        long end = 8L + (riff.getInt(4) & 0xffffffffL);
        if (end < 30 || end > data.length || riff.getInt(16) != 10) return null;
        int width = 1 + uint24(data, 24), height = 1 + uint24(data, 27);
        int longest = Math.max(width, height);
        int fitted = limit > 0 ? Math.min(longest, limit) : longest;
        if (fitted > sideCap || (long) width * height > 0xffffffffL) return null;

        int profile = 0, profileSize = 0;
        for (int start = 30; start + 8L <= end; ) {
            int size = riff.getInt(start + 4);
            long next = start + 8L + size + (size & 1);
            if (size < 0 || next > end) return null;
            if (tag(data, start, "ICCP")) {
                profile = start;
                profileSize = (int)next - start;
            } else if (tag(data, start, "ANMF")) {
                if (size <= 16) return null;
                int frame = start + 8;
                int x = 2 * uint24(data, frame), y = 2 * uint24(data, frame + 3);
                int w = 1 + uint24(data, frame + 6), h = 1 + uint24(data, frame + 9);
                if (x + w > width || y + h > height ||
                    !validFrameSize(data, riff, frame + 16, frame + size, w, h)) return null;
                // ANMF contains the same padded ALPH/VP8/VP8L chunks as a still.
                // Keep ICCP and replace the extended header's canvas with the frame dimensions.
                long length = 30L + profileSize + size - 16;
                if (length > 4L * sideCap * sideCap || length > Integer.MAX_VALUE) return null;
                byte[] still = new byte[(int)length];
                System.arraycopy(data, 0, still, 0, 30);
                ByteBuffer.wrap(still).order(ByteOrder.LITTLE_ENDIAN).putInt(4, still.length - 8);
                still[20] = (byte)((data[20] & 0x10) | (profileSize > 0 ? 0x20 : 0));
                System.arraycopy(data, frame + 6, still, 24, 6);
                System.arraycopy(data, profile, still, 30, profileSize);
                System.arraycopy(data, frame + 16, still, 30 + profileSize, size - 16);
                Bitmap result = compose(still, width, height, x, y, w, h, fitted, sideCap, metadata);
                if (result != null) metadata[0] = RuneImages.orientation(data, "image/webp");
                return result;
            }
            start = (int)next;
        }
        return null;
    }

    private static boolean validFrameSize(byte[] data, ByteBuffer riff, int start, int end, int w, int h) {
        boolean found = false;
        while (start + 8L <= end) {
            int size = riff.getInt(start + 4), payload = start + 8;
            long next = payload + (long)size + (size & 1);
            if (size < 0 || next > end) return false;
            if (tag(data, start, "VP8L")) {
                if (found || size < 5 || data[payload] != 0x2f) return false;
                int bits = riff.getInt(payload + 1);
                if (w != 1 + (bits & 0x3fff) || h != 1 + ((bits >>> 14) & 0x3fff)) return false;
                found = true;
            } else if (tag(data, start, "VP8 ")) {
                if (found || size < 10 || (data[payload] & 1) != 0 ||
                    (riff.getShort(payload + 6) & 0x3fff) != w || (riff.getShort(payload + 8) & 0x3fff) != h)
                    return false;
                found = true;
            }
            start = (int)next;
        }
        return found && start == end;
    }

    private static Bitmap compose(byte[] frame, int width, int height, int x, int y, int w, int h,
                                  int fitted, int sideCap, int[] metadata) {
        int longest = Math.max(width, height);
        boolean scaled = fitted < longest;
        boolean fullCanvas = w == width && h == height;
        int patchLimit = RuneImages.fit(Math.max(w, h), longest, fitted);
        Bitmap patch = RuneImages.decodeStill(frame, patchLimit, sideCap, metadata, scaled && !fullCanvas);
        if (patch == null) return null;
        if (patch.getWidth() != RuneImages.fit(w, Math.max(w, h), patchLimit) ||
            patch.getHeight() != RuneImages.fit(h, Math.max(w, h), patchLimit)) {
            patch.recycle();
            return null;
        }
        if (fullCanvas) return patch;
        int outWidth = RuneImages.fit(width, longest, fitted), outHeight = RuneImages.fit(height, longest, fitted);
        Bitmap poster = Bitmap.createBitmap(outWidth, outHeight, Bitmap.Config.ARGB_8888);
        if (scaled) {
            float sx = (float)outWidth / width, sy = (float)outHeight / height;
            new Canvas(poster).drawBitmap(patch, null, new RectF(x * sx, y * sy, (x + w) * sx, (y + h) * sy),
                                          new Paint(Paint.FILTER_BITMAP_FLAG));
        } else {
            // Copy straight RGBA without losing low-alpha color through Canvas premultiplication.
            poster.setPremultiplied(false);
            int[] row = new int[w];
            for (int i = 0; i < h; ++i) {
                patch.getPixels(row, 0, w, 0, i, w, 1);
                poster.setPixels(row, 0, w, x, y + i, w, 1);
            }
        }
        patch.recycle();
        metadata[1] = poster.isPremultiplied() ? 1 : 0;
        return poster;
    }
}
