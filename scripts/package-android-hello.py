#!/usr/bin/env python3
"""Package an arm64 RuneHelloAndroid SwiftPM build as an installable, debug-signed APK."""
import argparse
import os
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def checked(*args):
    subprocess.run(list(map(str, args)), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path, help="SwiftPM-built libRuneHelloAndroid.so")
    parser.add_argument("--android-sdk", type=Path, default=os.environ.get("ANDROID_HOME"), required="ANDROID_HOME" not in os.environ)
    parser.add_argument("--ndk", type=Path, default=os.environ.get("ANDROID_NDK_HOME"), required="ANDROID_NDK_HOME" not in os.environ)
    parser.add_argument("--swift-sdk", type=Path, required=True, help="swift-*-RELEASE_android.artifactbundle")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=ROOT / "examples/android/AndroidManifest.xml",
                        help="Android manifest for a different NativeActivity host or test fixture")
    parser.add_argument("--keystore", type=Path, help="Reuse an Android debug keystore (alias androiddebugkey, password android)")
    args = parser.parse_args()
    sdk = args.android_sdk
    tools = max((p for p in (sdk / "build-tools").iterdir() if re.fullmatch(r"\d+\.\d+\.\d+", p.name)),
                key=lambda p: tuple(map(int, p.name.split("."))))
    jar = sdk / "platforms/android-35/android.jar"
    ndk = next((args.ndk / "toolchains/llvm/prebuilt").iterdir())
    swift = args.swift_sdk / "swift-android/swift-resources/usr/lib/swift-aarch64/android"
    sysroot = ndk / "sysroot/usr/lib/aarch64-linux-android"
    readelf = ndk / "bin/llvm-readelf"
    machine = subprocess.check_output([readelf, "--file-header", args.library], text=True)
    if not re.search(r"Machine:\s+AArch64", machine):
        parser.error("This APK requires an arm64-v8a build of RuneHelloAndroid.")
    output = args.out.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        classes = work / "classes"
        classes.mkdir()
        java = sorted((ROOT / "android/src/main/java").rglob("*.java"))
        checked("javac", "--release", "8", "-classpath", jar, "-d", classes, *java)
        checked(tools / "d8", "--min-api", "24", "--lib", jar, "--output", work, *sorted(classes.rglob("*.class")))
        unsigned = work / "unsigned.apk"
        checked(tools / "aapt2", "link", "-o", unsigned, "-I", jar, "--manifest", args.manifest)
        trimmed = work / "lib"
        trimmed.mkdir()
        with zipfile.ZipFile(unsigned, "a", compression=zipfile.ZIP_STORED) as apk:
            apk.write(work / "classes.dex", "classes.dex")
            for directory in ("GL", "Fonts"):
                for asset in sorted((ROOT / "Sources/Rune/Resources" / directory).iterdir()):
                    if asset.is_file():
                        apk.write(asset, f"assets/{directory}/{asset.name}")
            seen = set()
            pending = [args.library]
            while pending:
                lib = pending.pop()
                if lib.name in seen:
                    continue
                seen.add(lib.name)
                # NativeActivity maps aligned libraries from the APK. Keep debug information
                # in the SwiftPM build, and ship only the loaded sections and dynamic symbols.
                packaged = trimmed / lib.name
                checked(ndk / "bin/llvm-strip", "--strip-unneeded", "-o", packaged, lib)
                apk.write(packaged, f"lib/arm64-v8a/{lib.name}")
                dynamic = subprocess.check_output([readelf, "--dynamic", lib], text=True)
                for dep in re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic):
                    if (swift / dep).is_file():
                        pending.append(swift / dep)
                    elif dep == "libc++_shared.so":
                        pending.append(sysroot / dep)
                    elif not any(sysroot.glob("[0-9]*/" + dep)):
                        raise SystemExit(f"Cannot resolve {dep}, required by {lib.name}")
        aligned = work / "aligned.apk"
        checked(tools / "zipalign", "-P", "16", "-f", "4", unsigned, aligned)
        keystore = args.keystore or (work / "debug.keystore")
        if not keystore.exists():
            checked("keytool", "-genkeypair", "-keystore", keystore, "-storepass", "android", "-keypass", "android",
                    "-alias", "androiddebugkey", "-keyalg", "RSA", "-keysize", "2048", "-validity", "3650",
                    "-dname", "CN=Rune Android Debug")
        checked(tools / "apksigner", "sign", "--ks", keystore, "--ks-pass", "pass:android",
                "--ks-key-alias", "androiddebugkey", "--out", output, aligned)
        checked(tools / "apksigner", "verify", output)
    print(output)


if __name__ == "__main__":
    main()
