#!/usr/bin/env python3
"""Build a debug instrumentation APK for RuneHostProbe using the target app's debug keystore."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("target", help="Installed Rune application's package name")
parser.add_argument("--keystore", type=Path, required=True, help="Android debug keystore used to sign the target")
parser.add_argument("--android-sdk", type=Path, default=os.environ.get("ANDROID_HOME"), required=not os.environ.get("ANDROID_HOME"))
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
sdk = args.android_sdk
jar = sdk / "platforms/android-35/android.jar"
tools = max((p for p in (sdk / "build-tools").iterdir() if (p / "d8").exists() and all(x.isdigit() for x in p.name.split("."))),
            key=lambda p: tuple(map(int, p.name.split("."))))
namespace = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", namespace)
with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    manifest = ET.Element("manifest", {"package": "dev.rune.probe"})
    ET.SubElement(manifest, "uses-sdk", {f"{{{namespace}}}minSdkVersion": "24", f"{{{namespace}}}targetSdkVersion": "35"})
    ET.SubElement(manifest, "application", {f"{{{namespace}}}label": "Rune host instrumentation"})
    ET.SubElement(manifest, "instrumentation", {f"{{{namespace}}}name": "dev.rune.probe.RuneHostProbe", f"{{{namespace}}}targetPackage": args.target})
    ET.ElementTree(manifest).write(work / "AndroidManifest.xml", encoding="utf-8", xml_declaration=True)
    classes = work / "classes"
    classes.mkdir()
    def run(*command):
        subprocess.run([str(x) for x in command], check=True)
    run("javac", "--release", "8", "-classpath", jar, "-d", classes, *sorted(Path(__file__).parent.glob("*.java")))
    run(tools / "d8", "--min-api", "24", "--lib", jar, "--output", work, *sorted(classes.rglob("*.class")))
    run(tools / "aapt2", "link", "-I", jar, "--manifest", work / "AndroidManifest.xml", "-o", work / "unsigned.apk")
    with zipfile.ZipFile(work / "unsigned.apk", "a") as apk:
        apk.write(work / "classes.dex", "classes.dex")
    args.out.parent.mkdir(exist_ok=True, parents=True)
    run(tools / "apksigner", "sign", "--ks", args.keystore, "--ks-key-alias", "androiddebugkey",
        "--ks-pass", "pass:android", "--out", args.out, work / "unsigned.apk")
