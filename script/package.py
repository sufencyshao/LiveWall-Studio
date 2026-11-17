#!/usr/bin/env python3
"""Build an isolated application bundle from this repository's sources."""
import os, platform, plistlib, shutil, subprocess
from pathlib import Path
root = Path(__file__).resolve().parent.parent
out = root / 'dist'
version = '1.2.1'
arch = os.environ.get('LIVEWALL_ARCH', platform.machine())
env = dict(os.environ)
if not env.get('DEVELOPER_DIR') and Path('/Library/Developer/CommandLineTools').exists():
    env['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
def run(*args): subprocess.run([str(a) for a in args], check=True, env=env)
app = out / 'LiveWall.app'
if app.exists(): shutil.rmtree(app)
macos = app / 'Contents/MacOS'; resources = app / 'Contents/Resources'
macos.mkdir(parents=True); resources.mkdir()
run('xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', f'{arch}-apple-macosx14.0', *sorted((root/'LiveWall').rglob('*.swift')), '-o', macos/'LiveWall')
info = dict(CFBundleExecutable='LiveWall', CFBundleIdentifier='com.livewall.app', CFBundleName='LiveWall', CFBundleDisplayName='LiveWall Studio', CFBundlePackageType='APPL', CFBundleShortVersionString=version, CFBundleVersion='121', CFBundleDevelopmentRegion='zh_CN', CFBundleLocalizations=['zh-Hans'], LSMinimumSystemVersion='14.0', LSUIElement=True, NSPrincipalClass='NSApplication', CFBundleIconFile='AppIcon')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
icons = out/'AppIcon.iconset'
icons.mkdir(exist_ok=True)
for p in (root/'LiveWall/Resources/Assets.xcassets/AppIcon.appiconset').glob('*.png'): shutil.copy2(p, icons/p.name)
run('iconutil', '-c', 'icns', icons, '-o', resources/'AppIcon.icns')
saver = resources/'LiveWallSaver.saver/Contents'
(saver/'MacOS').mkdir(parents=True)
run('xcrun','swiftc','-swift-version','5','-O','-emit-library','-target',f'{arch}-apple-macosx14.0',root/'LiveWallSaver/LiveWallSaverView.swift','-o',saver/'MacOS/LiveWallSaver')
(saver/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='LiveWallSaver',CFBundleIdentifier='com.livewall.app.saver',CFBundleName='LiveWallSaver',CFBundlePackageType='BNDL',CFBundleShortVersionString=version,CFBundleVersion='121',LSMinimumSystemVersion='14.0',NSPrincipalClass='LiveWallSaverView')))
shutil.copy2(root/'LICENSE', resources/'LICENSE')
run('codesign','--force','--sign','-',resources/'LiveWallSaver.saver')
run('codesign','--force','--sign','-',app)
run('codesign','--verify','--deep','--strict',app)
zip_path=out/f'LiveWall-Studio-{version}-macOS-{arch}.zip'
if zip_path.exists(): zip_path.unlink()
run('ditto','-c','-k','--keepParent',app,zip_path)
print(zip_path)
