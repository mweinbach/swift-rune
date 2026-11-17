# Android host instrumentation

Install the debug-signed Rune Hello APK and use the same debug keystore to sign the instrumentation APK. Run these commands with Android SDK 35, its build tools, an arm64 emulator or device, and `ANDROID_HOME` set.

```sh
python3 Tests/Android/build-probe.py org.swift.rune.hello --keystore "$KEYSTORE" --out /tmp/rune-hello-probe.apk
adb install -r /tmp/rune-hello-probe.apk
adb shell am instrument -w -e mode hello dev.rune.probe/dev.rune.probe.RuneHostProbe
adb shell am instrument -w -e mode virtual-bounds dev.rune.probe/dev.rune.probe.RuneHostProbe
adb shell am instrument -w -e mode text dev.rune.probe/dev.rune.probe.RuneHostProbe
adb shell am instrument -w -e mode outlines dev.rune.probe/dev.rune.probe.RuneHostProbe
adb shell am instrument -w -e mode images dev.rune.probe/dev.rune.probe.RuneHostProbe
```

The Hello check finds the virtual switch through Android's accessibility service, activates it, and reads the changed label and checked state. It also captures the displayed switch before and after activation and checks its pixels changed. The text check exercises Android font fallback and glyph masks.

On API 31 and newer the outline check compares vector paths from the positioned glyphs against Android's full-line text raster. It covers accents, ligatures, contextual punctuation, and color emoji fallback.

The virtual-bounds check projects a deep-scrolled list into the Android node provider and verifies screen bounds, parent-relative bounds and visibility throughout the visible rows’ ancestor chain.

The image check exercises the Android 7-compatible decoder on the device. It checks indexed PNG and GIF pixels and the first frame of an offset animated WebP at full size and thumbnail size.

The editor fixture uses the same Swift runtime and Android activity as an application. Set `SWIFT_ANDROID_SDK` to the installed Swift SDK identifier, `SWIFT_ANDROID_BUNDLE` to its artifact bundle directory, and `ANDROID_NDK_HOME` to its matching NDK.

```sh
swift build --package-path Tests/Android/EditingFixture --build-system native --swift-sdk "$SWIFT_ANDROID_SDK" --triple aarch64-unknown-linux-android24 --product RuneImeProbe
python3 scripts/package-android-hello.py Tests/Android/EditingFixture/.build/aarch64-unknown-linux-android24/debug/libRuneImeProbe.so \
  --swift-sdk "$SWIFT_ANDROID_BUNDLE" --manifest Tests/Android/EditingFixture/AndroidManifest.xml --keystore "$KEYSTORE" --out /tmp/rune-editor.apk
adb install -r /tmp/rune-editor.apk
python3 Tests/Android/build-probe.py org.swift.rune.imeprobe --keystore "$KEYSTORE" --out /tmp/rune-editor-probe.apk
adb install -r /tmp/rune-editor-probe.apk
adb shell am instrument -w -e mode editor dev.rune.probe/dev.rune.probe.RuneHostProbe
```

The editor check focuses a Rune field through Android accessibility, sends marked and committed Japanese text through its input connection, deletes an emoji by code point, replaces a UTF-16 selection, and reads the result and caret position from the accessibility service. On API 34 and newer it also exercises autocorrect range replacement. It edits a password through a new input connection and confirms the previous connection cannot write into it. The test verifies that both accessibility and the IME receive no password text.
