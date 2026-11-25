# Rune on Android

The Hello app uses the same Swift view and state as the desktop executable. Android loads the Swift shared library through `dev.rune.RuneActivity`, a `NativeActivity` with a virtual accessibility tree and an IME input connection. Rune creates an EGL window surface and draws the production frame with OpenGL ES 3. The minimum Android version for this host is API 24.

Install the matching Swift toolchain and Swift SDK for Android, then configure its NDK sysroot. The verified pair uses Swift 6.4.2 and NDK r30. [Swift SDK for Android setup](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)

From the package root, set `ANDROID_HOME` to the Android SDK directory, `ANDROID_NDK_HOME` to the NDK directory, and `RUNE_SWIFT_SDK` to the installed Android `.artifactbundle` directory. The packaging command uses Android platform 35, SDK build-tools, a JDK, and Python 3.

```sh
swift build --build-system native --swift-sdk swift-6.4.2-RELEASE_android \
  --triple aarch64-unknown-linux-android24 -Xlinker --no-undefined --product RuneHelloAndroid
python3 scripts/package-android-hello.py \
  .build/aarch64-unknown-linux-android24/debug/libRuneHelloAndroid.so \
  --swift-sdk "$RUNE_SWIFT_SDK" --keystore .build/rune-android-debug.jks \
  --out .build/RuneHello.apk
adb install -r .build/RuneHello.apk
adb shell am start -n org.swift.rune.hello/dev.rune.RuneActivity
adb logcat -s SwiftRune
```

The APK includes the arm64 application, its Swift runtime dependencies, Java host classes, fonts, and shared shader sources. The debug keystore at the supplied path lets later builds update the same installation. The first successful swap logs the adapter name and drawable size. Tap the switch to change “Lights off” to “Lights on”.

To embed a different Rune app, export `ANativeActivity_onCreate` from the app's Swift dynamic library as shown in `Sources/Examples/RuneHelloAndroid/Activity.swift`, call `AndroidApp.attach(to:spec:)` or `AndroidApp.attach(to:app:)`, and set the manifest's `android.app.lib_name` to that library's name. The Activity main looper owns the Runtime and GL context through backgrounding, resizes, and surface replacement.

The instrumentation tests activate Rune controls through Android accessibility services and exercise the system input connection with editable and secure fields. [Android host tests](../../Tests/Android/README.md)
