#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/dist/renderer"
cache="${LIVEWALL_RENDERER_CACHE:-$root/dist/renderer-cache}"
sources="$build/sources"
runtime="$build/runtime"
deployment=15.0
cmake="${CMAKE:-cmake}"
pkgconf="${PKG_CONFIG:-pkg-config}"
jobs="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
mkdir -p "$cache" "$sources" "$runtime"

while read -r name repository tag sha; do
    archive="$cache/$name.tar.gz"
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --silent --show-error --retry 2 \
            "https://codeload.github.com/$repository/tar.gz/refs/tags/$tag" -o "$archive"
    fi
    printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c -
    if [[ ! -d "$sources/$name" ]]; then
        staging="$(mktemp -d "$sources/.source.XXXXXX")"
        tar -xzf "$archive" -C "$staging" --strip-components=1
        if [[ "$name" == wallpapermachine ]]; then
            (cd "$staging" && patch -p1 < "$root/renderer/upstream.patch")
        fi
        mv "$staging" "$sources/$name"
    fi
done < "$root/renderer/sources.tsv"

build_dependency() {
    local name="$1" directory="$2"
    shift 2
    "$cmake" -S "$sources/$directory" -B "$build/deps/$name" \
        -DCMAKE_BUILD_TYPE=Release "-DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 "-DCMAKE_INSTALL_PREFIX=$runtime/$name" "$@"
    "$cmake" --build "$build/deps/$name" -j "$jobs"
    "$cmake" --install "$build/deps/$name"
}
build_dependency quickjs-ng quickjs-ng -DBUILD_SHARED_LIBS=ON
build_dependency lz4 lz4/build/cmake -DBUILD_SHARED_LIBS=ON -DLZ4_BUILD_CLI=OFF
build_dependency libpng libpng -DPNG_STATIC=OFF -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
build_dependency brotli brotli -DBUILD_SHARED_LIBS=ON -DBROTLI_DISABLE_TESTS=ON
build_dependency nlohmann-json nlohmann-json -DJSON_BuildTests=OFF
build_dependency argparse argparse -DARGPARSE_BUILD_TESTS=OFF -DARGPARSE_BUILD_SAMPLES=OFF

upstream="$sources/wallpapermachine"
(cd "$upstream/Renderer" && MACOSX_DEPLOYMENT_TARGET="$deployment" cargo build --locked --release -p wm-shader --features ffi)
mkdir -p "$build/rust-notices"
(cd "$upstream/Renderer" && cargo tree --locked --offline -p wm-shader --features ffi \
    --target aarch64-apple-darwin --prefix none --format '{p}') |
    awk '$2 ~ /^v[0-9]/ && $3 !~ /^\(\// { print $1 "-" substr($2, 2) }' |
    sort -u | while read -r crate; do
        for crate_source in "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/"$crate"; do
            [[ -d "$crate_source" ]] || continue
            for notice in "$crate_source"/LICENSE* "$crate_source"/COPYING* "$crate_source"/NOTICE*; do
                [[ -f "$notice" ]] || continue
                cp "$notice" "$build/rust-notices/$crate-${notice##*/}"
            done
        done
    done
prefix="$runtime/quickjs-ng;$runtime/lz4;$runtime/libpng;$runtime/brotli;$runtime/nlohmann-json;$runtime/argparse"
export PKG_CONFIG_PATH="$runtime/lz4/lib/pkgconfig:$runtime/libpng/lib/pkgconfig:$runtime/brotli/lib/pkgconfig"
"$cmake" -S "$root/renderer" -B "$build/engine" -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    "-DCMAKE_PREFIX_PATH=$prefix" "-DPKG_CONFIG_EXECUTABLE=$(command -v "$pkgconf")" \
    "-DWALLPAPER_MACHINE_SOURCE=$upstream" \
    "-DRUST_SHADER_STATICLIB=$upstream/Renderer/target/release/libwm_shader.a"
"$cmake" --build "$build/engine" --target LiveWallScene -j "$jobs"
