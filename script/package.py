#!/usr/bin/env python3
"""Build an Apple-silicon LiveWall Studio disk image from the release sources."""
import argparse
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
RENDERER = DIST / "renderer"
VERSION = (ROOT / "VERSION").read_text().strip()
BUILD = "135"
MINIMUM_MACOS = "15.0"
LIBRARIES = {
    "quickjs-ng": ["libqjs.0.dylib"],
    "lz4": ["liblz4.1.dylib"],
    "libpng": ["libpng16.16.dylib"],
    "brotli": ["libbrotlidec.1.dylib", "libbrotlicommon.1.dylib"],
}


def run(*arguments):
    subprocess.run([str(arg) for arg in arguments], check=True)


def plist(path, **values):
    path.write_bytes(plistlib.dumps(values))


def check_minimum(binary):
    build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
    minimum = tuple(map(int, MINIMUM_MACOS.split(".")))
    versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+)+)", build, re.MULTILINE)
    if not versions or any(tuple(map(int, version.split("."))) > minimum for version in versions):
        raise RuntimeError(f"{binary.name} has incompatible minimum OS metadata")
    architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    if architectures != ["arm64"]:
        raise RuntimeError(f"{binary.name} is not an arm64-only binary")


def link_and_sign(frameworks):
    libraries = list(frameworks.glob("*.dylib"))
    names = {path.name for path in libraries}
    for library in libraries:
        check_minimum(library)
        library.chmod(0o755)
        links = subprocess.check_output(["otool", "-L", str(library)], text=True).splitlines()[2:]
        changes = ["-id", f"@loader_path/{library.name}"]
        for line in links:
            dependency = line.strip().split(" (", 1)[0]
            name = Path(dependency).name
            if name in names:
                changes.extend(["-change", dependency, f"@loader_path/{name}"])
            elif not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise RuntimeError(f"Unbundled dependency: {dependency}")
        run("install_name_tool", *changes, library)
        run("codesign", "--force", "--sign", "-", library)


def copy_notice(notice, target):
    if notice.is_dir():
        shutil.copytree(notice, target)
    else:
        shutil.copy2(notice, target)


def make_app(stage, scene_assets=None):
    app = stage / "LiveWall.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    frameworks = contents / "Frameworks"
    licenses = resources / "Licenses"
    for path in [macos, licenses, frameworks]:
        path.mkdir(parents=True)

    target = "arm64-apple-macosx15.0"
    run("xcrun", "swiftc", "-swift-version", "5", "-O", "-target", target,
        *sorted((ROOT / "LiveWall").rglob("*.swift")), "-o", macos / "LiveWall")
    check_minimum(macos / "LiveWall")
    plist(contents / "Info.plist",
          CFBundleExecutable="LiveWall", CFBundleIdentifier="com.livewall.app",
          CFBundleName="LiveWall", CFBundleDisplayName="LiveWall", CFBundlePackageType="APPL",
          CFBundleShortVersionString=VERSION, CFBundleVersion=BUILD,
          CFBundleDevelopmentRegion="zh_CN", CFBundleLocalizations=["zh-Hans", "en"],
          LSMinimumSystemVersion=MINIMUM_MACOS, LSUIElement=True, NSPrincipalClass="NSApplication",
          CFBundleIconFile="AppIcon", LSApplicationCategoryType="public.app-category.entertainment",
          NSAudioCaptureUsageDescription="LiveWall 读取电脑正在播放的声音，用于实时绘制场景壁纸的频谱。音频不会保存或上传。")
    icons = stage.parent / "AppIcon.iconset"
    icons.mkdir()
    for icon in (ROOT / "LiveWall/Resources/Assets.xcassets/AppIcon.appiconset").glob("*.png"):
        shutil.copy2(icon, icons / icon.name)
    run("iconutil", "-c", "icns", icons, "-o", resources / "AppIcon.icns")

    saver = resources / "LiveWallSaver.saver"
    (saver / "Contents/MacOS").mkdir(parents=True)
    executable = saver / "Contents/MacOS/LiveWallSaver"
    run("xcrun", "swiftc", "-swift-version", "5", "-O", "-emit-library", "-target", target,
        ROOT / "LiveWallSaver/LiveWallSaverView.swift", "-o", executable)
    check_minimum(executable)
    plist(saver / "Contents/Info.plist",
          CFBundleExecutable="LiveWallSaver", CFBundleIdentifier="com.livewall.app.saver",
          CFBundleName="LiveWallSaver", CFBundlePackageType="BNDL",
          CFBundleShortVersionString=VERSION, CFBundleVersion=BUILD,
          LSMinimumSystemVersion=MINIMUM_MACOS, NSPrincipalClass="LiveWallSaverView")

    source = RENDERER / "sources"
    shutil.copy2(ROOT / "LICENSE", licenses / "LiveWall-MIT.txt")
    shutil.copy2(ROOT / "renderer/COPYING", licenses / "GPL-3.0.txt")
    shutil.copy2(ROOT / "renderer/UPSTREAM-LICENSING.md", licenses / "WallpaperMachine.md")
    third_party = source / "wallpapermachine/ThirdParty"
    for vendor in ("freetype", "harfbuzz", "miniaudio", "msdfgen", "naga", "stb_image", "stb_vorbis"):
        directory = third_party / vendor
        for notice in list(directory.glob("LICENSE*")) + list(directory.glob("COPYING*")):
            copy_notice(notice, licenses / f"{vendor}-{notice.name}")
    shutil.copytree(third_party / "freetype/docs", licenses / "freetype-docs",
                    ignore=lambda _, names: [name for name in names if name not in {"FTL.TXT", "GPLv2.TXT"}])
    shutil.copytree(RENDERER / "rust-notices", licenses / "Rust")
    for vendor in (*LIBRARIES, "nlohmann-json", "argparse"):
        for notice in (source / vendor).glob("LICENSE*"):
            copy_notice(notice, licenses / f"{vendor}-{notice.name}")

    shutil.copy2(RENDERER / "engine/libLiveWallScene.dylib", frameworks)
    for vendor, names in LIBRARIES.items():
        for name in names:
            shutil.copy2(RENDERER / "runtime" / vendor / "lib" / name, frameworks)
    link_and_sign(frameworks)
    if scene_assets is not None:
        shutil.copytree(scene_assets, resources / "SceneAssets", ignore=shutil.ignore_patterns(".DS_Store"))
    run("codesign", "--force", "--sign", "-", saver)
    run("codesign", "--force", "--sign", "-", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    return app


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--personal-assets", type=Path,
                        help="Bundle a local Wallpaper Engine assets folder in a personal-use disk image.")
    args = parser.parse_args()
    assets = args.personal_assets
    if assets is not None and not (assets / "shaders/genericimage2.frag").is_file():
        parser.error("--personal-assets must point to a complete Wallpaper Engine assets folder.")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Run the package build on an Apple-silicon Mac.")
    if not (RENDERER / "engine/libLiveWallScene.dylib").is_file():
        raise SystemExit("Build the native renderer with script/build-renderer.sh first.")
    output_directory = DIST if assets is None else DIST / "personal"
    output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="livewall-package-") as temporary:
        stage = Path(temporary) / "disk"
        stage.mkdir()
        app = make_app(stage, assets)
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        suffix = "" if assets is None else "-personal"
        filename = f"LiveWall-Studio-{VERSION}-macOS-arm64{suffix}.dmg"
        image = Path(temporary) / filename
        run("hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO",
            "-volname", f"LiveWall Studio {VERSION}", "-srcfolder", stage, image)
        run("hdiutil", "verify", image)
        output = output_directory / filename
        shutil.move(image, output)
        print(output)


if __name__ == "__main__":
    main()
