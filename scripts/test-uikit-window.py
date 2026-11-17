#!/usr/bin/env python3
"""Run the production RuneHello scene through UIKit and Metal on a Mac, in a Catalyst window."""
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    build = [
        "xcrun", "swift", "build", "--package-path", str(root / "Tests/Apple/UIKitWindow"),
        "--sdk", sdk, "--triple", f"{platform.machine()}-apple-ios17.0-macabi", "--product", "RuneUIKitWindow",
    ]
    subprocess.run(build, check=True)
    products = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip())
    # Swift Build can report the configuration directory without its Catalyst suffix.
    if not (products / "RuneUIKitWindow").is_file():
        products = products.with_name(f"{products.name}-maccatalyst")
    with tempfile.TemporaryDirectory(prefix="rune-uikit-") as tmp:
        app = Path(tmp) / "RuneUIKitWindow.app"
        contents = app / "Contents"
        executable = contents / "MacOS/RuneUIKitWindow"
        executable.parent.mkdir(parents=True)
        shutil.copy2(products / executable.name, executable)
        for bundle in products.glob("*.bundle"):
            shutil.copytree(bundle, contents / "Resources" / bundle.name)
        scene = {"UISceneConfigurationName": "Probe", "UISceneDelegateClassName": "ProbeScene"}
        info = {
            "CFBundleIdentifier": "org.rune.tests.UIKitWindow", "CFBundleExecutable": executable.name,
            "CFBundleName": "RuneUIKitWindow", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True, "UILaunchScreen": {},
            "UIApplicationSceneManifest": {
                "UIApplicationSupportsMultipleScenes": False,
                "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [scene]},
            },
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", app], check=True)
        # An occluded background process receives skipped drawables. Launch a foreground scene to measure presentation.
        result = Path(tmp) / "passed"
        stdout, stderr = Path(tmp) / "stdout", Path(tmp) / "stderr"
        launch = ["open", "-n", "-W", "--stdout", str(stdout), "--stderr", str(stderr),
                  "--env", "RUNE_GPU_INFO=1", "--env", f"RUNE_UIKIT_TEST_RESULT={result}"]
        if path := os.environ.get("RUNE_UIKIT_TEST_TRACE"):
            launch.extend(["--env", f"RUNE_UIKIT_TEST_TRACE={path}"])
        subprocess.run([*launch, str(app)], check=True, timeout=60)
        if stdout.exists():
            sys.stdout.write(stdout.read_text())
        if stderr.exists():
            sys.stderr.write(stderr.read_text())
        if not result.is_file():
            raise SystemExit("The Catalyst window probe did not complete")


if __name__ == "__main__":
    main()
