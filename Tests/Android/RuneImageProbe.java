package dev.rune.probe;

import android.graphics.Bitmap;
import android.util.Base64;
import java.lang.reflect.Method;

/** Regression fixtures for the BitmapFactory path used before the NDK image decoder. */
public final class RuneImageProbe {
    private static final String GIF = "R0lGODlhAgABAIEAAAAAAP8AAAAAAAAAACH5BAEAAAAALAAAAAACAAEAAAgFAAMACAgAOw==";
    private static final String PNG = "iVBORw0KGgoAAAANSUhEUgAAAAYAAAABBAMAAAAP58LDAAAAElBMVEUAAAD/AAASoloAAP9/3in///+Yf2T5AAAABnRSTlMAf4BA/wFsxIaQAAAADElEQVR4nGNgVHYFAACSAGqArSEHAAAAAElFTkSuQmCC";
    // First ANMF is a 4×2 translucent pink rectangle at (2,2) in an 8×6 canvas.
    private static final String WEBP = "UklGRogAAABXRUJQVlA4WAoAAAASAAAABwAABQAAQU5JTQYAAAAAAAAAAwBBTk1GKgAAAAEAAAEAAAMAAAEAAFoAAAJWUDhMEQAAAC8DQAAQB9CQqlergIGI6H8AAEFOTUYqAAAAAAAAAAAAAQAAAQAAqgAAAlZQOEwRAAAALwFAAAAHUO4yNKr/gYjofwAA";

    private static Bitmap decode(Method method, String encoded, int limit, int w, int h) throws Exception {
        Bitmap image = (Bitmap)method.invoke(null, Base64.decode(encoded, Base64.DEFAULT), limit, 8192, new int[2]);
        if (image == null || image.getConfig() != Bitmap.Config.ARGB_8888 ||
            image.getWidth() != w || image.getHeight() != h) throw new AssertionError("Incorrect bitmap dimensions or format");
        return image;
    }

    private static void pixel(Bitmap image, int x, int y, int expected) {
        int actual = image.getPixel(x, y);
        if ((actual >>> 24) == (expected >>> 24)) {
            boolean close = true;
            for (int shift = 0; shift < 24; shift += 8)
                close &= Math.abs(((actual >>> shift) & 255) - ((expected >>> shift) & 255)) <= 2;
            if (close) return;
        }
        throw new AssertionError(String.format("(%d,%d) expected %08x, got %08x", x, y, expected, actual));
    }

    public static void run(ClassLoader target) throws Exception {
        Method method = target.loadClass("dev.rune.RuneImages")
            .getMethod("decode", byte[].class, int.class, int.class, int[].class);
        Bitmap gif = decode(method, GIF, 0, 2, 1);
        pixel(gif, 0, 0, 0xffff0000);
        pixel(gif, 1, 0, 0);
        gif.recycle();

        Bitmap png = decode(method, PNG, 0, 6, 1);
        int[] palette = {0, 0x7fff0000, 0x8012a25a, 0x400000ff, 0xff7fde29, 0x01ffffff};
        for (int x = 0; x < palette.length; ++x) pixel(png, x, 0, palette[x]);
        png.recycle();

        Bitmap poster = decode(method, WEBP, 0, 8, 6);
        pixel(poster, 1, 1, 0);
        pixel(poster, 2, 2, 0x80ea215a);
        pixel(poster, 5, 3, 0x80ea215a);
        pixel(poster, 6, 3, 0);
        poster.recycle();

        Bitmap thumbnail = decode(method, WEBP, 4, 4, 3);
        pixel(thumbnail, 0, 0, 0);
        // Android's AImageDecoder thumbnail samples this pixel as (233,32,90,128).
        pixel(thumbnail, 1, 1, 0x80e9205a);
        thumbnail.recycle();
    }
}
