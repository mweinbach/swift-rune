#if os(Android)
import Rune
import RuneHelloScene

// android.app.NativeActivity loads this entry point from libRuneHelloAndroid.so.
@_cdecl("ANativeActivity_onCreate")
public func runeHelloCreate(_ activity: UnsafeMutableRawPointer, _ savedState: UnsafeRawPointer?, _ size: Int) {
    let address = UInt(bitPattern: activity)
    MainActor.assumeIsolated {
        AndroidApp.attach(to: UnsafeMutableRawPointer(bitPattern: address)!, spec: RuneHelloScene.makeSpec())
    }
}
#endif
