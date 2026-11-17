package dev.rune;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ColorSpace;
import android.media.ExifInterface;
import android.os.Build;

import java.io.ByteArrayInputStream;
import java.io.IOException;

/** Framework bitmap decoder for Android versions preceding the NDK image decoder. */
public final class RuneImages {
    private RuneImages() {}

    static int orientation(byte[] bytes, String mime) {
        boolean supported = "image/jpeg".equals(mime) ||
            (Build.VERSION.SDK_INT >= 28 && ("image/heif".equals(mime) || "image/heic".equals(mime))) ||
            (Build.VERSION.SDK_INT >= 30 && ("image/webp".equals(mime) || "image/png".equals(mime)));
        if (!supported) return ExifInterface.ORIENTATION_NORMAL;
        try {
            ExifInterface exif = new ExifInterface(new ByteArrayInputStream(bytes));
            return exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
        } catch (IOException ignored) {
            return ExifInterface.ORIENTATION_NORMAL;
        }
    }

    // Keep API 26 ColorSpace references out of the class verified on API 24.
    private static final class Srgb {
        static void request(BitmapFactory.Options options) {
            options.inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB);
        }
    }

    public static Bitmap decode(byte[] bytes, int limit, int sideCap, int[] metadata) {
        if (WebPPoster.matches(bytes)) return WebPPoster.decode(bytes, limit, sideCap, metadata);
        return decodeStill(bytes, limit, sideCap, metadata, false);
    }

    static int fit(int value, int longest, int fitted) {
        return (int) Math.max(1L, ((long) value * fitted + longest / 2) / longest);
    }

    static Bitmap decodeStill(byte[] bytes, int limit, int sideCap, int[] metadata, boolean forDrawing) {
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        int width = options.outWidth;
        int height = options.outHeight;
        if (width <= 0 || height <= 0) return null;

        int longest = Math.max(width, height);
        int fitted = limit > 0 ? Math.min(longest, limit) : longest;
        if (fitted > sideCap) return null;
        int targetWidth = fit(width, longest, fitted);
        int targetHeight = fit(height, longest, fitted);
        // BitmapFactory decoders can subsample by powers of two, keeping the
        // intermediate near the requested size even for a camera-sized JPEG.
        int sample = Integer.highestOneBit(longest / fitted);
        while ((longest + (long) sample - 1) / sample > sideCap) sample *= 2;
        options.inJustDecodeBounds = false;
        options.inSampleSize = sample;
        options.inScaled = false;
        options.inPreferredConfig = Bitmap.Config.ARGB_8888;
        options.inPremultiplied = fitted < longest || forDrawing;
        if (Build.VERSION.SDK_INT >= 26) Srgb.request(options);
        metadata[0] = orientation(bytes, options.outMimeType);
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        if (bitmap == null) return null;
        // Android 7 can return an indexed GIF bitmap even when ARGB_8888 was requested.
        if (bitmap.getConfig() != Bitmap.Config.ARGB_8888) {
            // Bitmap.copy also rejects unpremultiplied indexed bitmaps on Android 7.
            int w = bitmap.getWidth();
            Bitmap rgba = Bitmap.createBitmap(w, bitmap.getHeight(), Bitmap.Config.ARGB_8888);
            rgba.setPremultiplied(options.inPremultiplied);
            int[] row = new int[w];
            for (int y = 0; y < bitmap.getHeight(); ++y) {
                bitmap.getPixels(row, 0, w, 0, y, w, 1);
                rgba.setPixels(row, 0, w, 0, y, w, 1);
            }
            bitmap.recycle();
            bitmap = rgba;
        }
        if (bitmap.getWidth() != targetWidth || bitmap.getHeight() != targetHeight) {
            Bitmap thumbnail = Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true);
            if (thumbnail != bitmap) bitmap.recycle();
            bitmap = thumbnail;
        }
        metadata[1] = bitmap.isPremultiplied() ? 1 : 0;
        return bitmap;
    }
}
