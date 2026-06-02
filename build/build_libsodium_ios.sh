#!/usr/bin/env bash
# Build libsodium for iPhoneOS arm64
# Run from the root of this repository after downloading libsodium source.
set -euo pipefail

LIBSODIUM_VERSION="${1:-1.0.19}"
LIBSODIUM_SRC="libsodium-${LIBSODIUM_VERSION}"
PREFIX="$(pwd)/build/libsodium"

if [ ! -d "$LIBSODIUM_SRC" ]; then
    echo "Downloading libsodium ${LIBSODIUM_VERSION}..."
    curl -L "https://download.libsodium.org/libsodium/releases/libsodium-${LIBSODIUM_VERSION}.tar.gz" -o libsodium.tar.gz
    tar xzf libsodium.tar.gz
    rm libsodium.tar.gz
fi

cd "$LIBSODIUM_SRC"

export IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos --find clang)"
export CFLAGS="-arch arm64 -isysroot $IOS_SDK -miphoneos-version-min=14.0"
export LDFLAGS="-arch arm64 -isysroot $IOS_SDK -miphoneos-version-min=14.0"

echo "=== Configuring libsodium for iPhoneOS arm64 ==="
echo "CC=$CC"
echo "CFLAGS=$CFLAGS"
echo "Prefix=$PREFIX"

./configure \
    --build="$(./build-aux/config.guess)" \
    --host="arm-apple-darwin" \
    --prefix="$PREFIX" \
    --disable-shared

echo "=== Building ==="
make -j1

echo "=== Installing ==="
make install

echo "=== Verifying ==="
lipo -info "$PREFIX/lib/libsodium.a"
echo "Done. libsodium installed to $PREFIX"
