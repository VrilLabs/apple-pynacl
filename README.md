# apple-pynacl — PyNaCl wheels for Apple platforms

Custom-built PyNaCl 1.6.2 wheels for macOS and iOS, linked against a custom-compiled libsodium. All wheels contain the native `_sodium` extension — not pure-Python.

## Available wheels

| Wheel | Target | Python | Extension | Use case |
|-------|--------|--------|-----------|----------|
| `pynacl-1.6.2-cp314-cp314-macosx_26_0_x86_64.whl` | macOS x86_64 | 3.14 | `_sodium.abi3.so` | Intel Macs |
| `pynacl-1.6.2-cp313-cp313-ios_arm64.whl` | iOS arm64 (generic) | 3.13 | `_sodium.abi3.so` | Intermediate build — may not install on all iOS Python distributions |
| `pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl` | iOS arm64 (a-Shell) | 3.13 | `_sodium.cpython-313-iphoneos.so` | **Recommended for a-Shell on iPad/iPhone** |

> **Which iOS wheel?** Use the `ios_14_arm64_iphoneos` wheel for a-Shell. The `ios_arm64` wheel uses a generic platform tag and `.abi3.so` suffix that a-Shell's pip does not recognize. The `iphoneos` wheel matches a-Shell's `sysconfig.get_platform()` (`ios-14-arm64-iphoneos`) and `EXT_SUFFIX` (`.cpython-313-iphoneos.so`).

## Installation — macOS (Intel)

```sh
pip install dist/pynacl-1.6.2-cp314-cp314-macosx_26_0_x86_64.whl
```

If another version is already installed:

```sh
pip install --force-reinstall dist/pynacl-1.6.2-cp314-cp314-macosx_26_0_x86_64.whl
```

## Installation — iOS (a-Shell)

### Step 1: Create a virtual environment

Using a venv keeps PyNaCl and its dependencies isolated from the system Python. This is strongly recommended on iOS to avoid conflicts with a-Shell's bundled packages.

```sh
python3 -m venv ~/venv
source ~/venv/bin/activate
```

> **Tip**: Add `source ~/venv/bin/activate` to your a-Shell startup file (`~/.profile` or `~/.zshrc`) so the venv is active every time you open a-Shell.

### Step 2: Transfer the wheel to iOS

Copy the `.whl` file to your iOS device. Options:

- **a-Shell `pickFolder`**: Open a-Shell, run `pickFolder` to open the iOS document picker, then copy the wheel into the selected folder.
- **iCloud Drive**: Save to `~/Library/Mobile Documents/com~apple~CloudDocs/`, then access from a-Shell at the same path.
- **SSH/SCP**: If a-Shell's SSH server is enabled, `scp` the wheel directly.

### Step 3: Install dependencies

a-Shell's bundled Python may not include `cffi` or `six`. Install them first:

```sh
pip install cffi six
```

If `pip` can't fetch from PyPI on-device, download the wheels on another machine and transfer them the same way:

```sh
pip download cffi six --platform ios_arm64 --python-version 313 --only-binary=:all: -d ./deps/
```

Then install from local files:

```sh
pip install ./deps/cffi-*.whl ./deps/six-*.whl
```

### Step 4: Install the PyNaCl wheel

```sh
pip install pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl
```

If another version of PyNaCl is already installed, force reinstall:

```sh
pip install --force-reinstall pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl
```

If pip rejects the platform tag entirely:

```sh
pip install --force-reinstall --no-deps pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl
```

### Step 5: Verify installation

Quick smoke test:

```sh
python3 -c "import nacl; print(nacl.__version__); from nacl.public import PrivateKey; k = PrivateKey.generate(); print('PyNaCl OK')"
```

Expected output:

```
1.6.2
PyNaCl OK
```

Full validation suite — tests key generation, encryption, signing, and hashing:

```sh
python3 << 'EOF'
import nacl
print(f"PyNaCl version: {nacl.__version__}")

# --- Public-key encryption (Box) ---
from nacl.public import PrivateKey, Box
sk_a = PrivateKey.generate()
sk_b = PrivateKey.generate()
box = Box(sk_a, sk_b.public_key)
plaintext = b"Hello from iOS!"
encrypted = box.encrypt(plaintext)
decrypted = Box(sk_b, sk_a.public_key).decrypt(encrypted)
assert decrypted == plaintext
print(f"[PASS] Box encrypt/decrypt ({len(plaintext)} bytes)")

# --- Sealed box ---
from nacl.public import SealedBox
sealed = SealedBox(sk_b.public_key)
sealed_ct = sealed.encrypt(plaintext)
sealed_pt = SealedBox(sk_b).decrypt(sealed_ct)
assert sealed_pt == plaintext
print("[PASS] SealedBox encrypt/decrypt")

# --- Secret-key encryption (SecretBox) ---
from nacl.secret import SecretBox
key = SecretBox.KEY_SIZE * b"\x01"
box = SecretBox(key)
ciphertext = box.encrypt(plaintext)
assert SecretBox(key).decrypt(ciphertext) == plaintext
print("[PASS] SecretBox encrypt/decrypt")

# --- Digital signatures ---
from nacl.signing import SigningKey
sign_key = SigningKey.generate()
signed = sign_key.sign(plaintext)
from nacl.signing import VerifyKey
verified = VerifyKey(sign_key.verify_key).verify(signed)
assert verified == plaintext
print("[PASS] Signing/verify")

# --- Hashing ---
from nacl.hash import sha256
from nacl.encoding import HexEncoder
digest = sha256(plaintext, encoder=HexEncoder)
print(f"[PASS] SHA-256: {digest[:16]}...")

# --- Random bytes ---
from nacl.utils import random
rand = random(32)
assert len(rand) == 32
print(f"[PASS] random(32) -> {len(rand)} bytes")

print("\nAll tests passed!")
EOF
```

## Troubleshooting

### `ImportError: dlopen(...) symbol not found`

The native extension was built for a specific architecture. If you see symbol errors, the on-device Python ABI may not match. Check:

```sh
python3 -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))"
```

- **a-Shell iOS**: should be `.cpython-313-iphoneos.so`
- **macOS**: should be `.cpython-314-darwin.so` or `.abi3.so`

### `ModuleNotFoundError: No module named '_cffi_backend'`

cffi's compiled backend is missing. Reinstall cffi from source on-device:

```sh
pip install --no-binary cffi --no-cache-dir cffi
```

### `OSError: cannot load library`

Verify the extension is the right architecture:

```sh
file $(python3 -c "import nacl._sodium as m; print(m.__file__)")
```

- **iOS arm64 wheel**: should show `Mach-O 64-bit bundle arm64`
- **macOS x86_64 wheel**: should show `Mach-O 64-bit bundle x86_64`

If the architecture doesn't match your device, use the correct wheel.

### pip refuses the platform tag (iOS)

If pip still rejects the `ios_14_arm64_iphoneos` wheel, extract manually:

```sh
mkdir -p $(python3 -c "import site; print(site.getusersitepackages())")
unzip pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl -d $(python3 -c "import site; print(site.getusersitepackages())")
```

## Building from source

These instructions reproduce the wheels in `dist/`. You need a macOS host with Xcode and Homebrew Python.

### Prerequisites

- macOS with Xcode (includes iPhoneOS SDK)
- Homebrew: `brew install python@3.13 python@3.14`
- Command line tools: `xcode-select --install`

### Build libsodium for iOS

```sh
cd build
chmod +x build_libsodium_ios.sh
./build_libsodium_ios.sh 1.0.19
```

This downloads libsodium, cross-compiles it for iPhoneOS arm64, and installs to `build/libsodium/`. Verify:

```sh
lipo -info build/libsodium/lib/libsodium.a
# → Non-fat file ... is architecture: arm64
```

### Build PyNaCl for iOS (a-Shell)

```sh
cd build
chmod +x build_pynacl_ios.sh
./build_pynacl_ios.sh 1.6.2
```

This script:
1. Downloads PyNaCl source
2. Creates a Python 3.13 venv with cffi
3. Cross-compiles the `_sodium` extension against the custom libsodium
4. Builds a wheel with `_PYTHON_HOST_PLATFORM=ios-arm64`
5. Repackages the wheel with the `ios_14_arm64_iphoneos` tag and `.cpython-313-iphoneos.so` suffix for a-Shell compatibility

Output: `dist/pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl`

### Build PyNaCl for macOS

```sh
cd build
chmod +x build_pynacl_macos.sh
./build_pynacl_macos.sh 1.6.2
```

This builds PyNaCl with the bundled libsodium for macOS x86_64 using Python 3.14.

Output: `dist/pynacl-1.6.2-cp314-cp314-macosx_26_0_x86_64.whl`

### Key build variables (iOS)

For manual builds or customization, these are the critical environment variables:

| Variable | Value | Purpose |
|----------|-------|---------|
| `CC` | `$(xcrun --sdk iphoneos --find clang)` | iOS SDK compiler |
| `SDKROOT` | `$(xcrun --sdk iphoneos --show-sdk-path)` | iPhoneOS SDK path |
| `CFLAGS` | `-arch arm64 -isysroot $SDKROOT -miphoneos-version-min=14.0` | iOS target flags |
| `LDFLAGS` | `-arch arm64 -isysroot $SDKROOT -miphoneos-version-min=14.0` | iOS linker flags |
| `_PYTHON_HOST_PLATFORM` | `ios-arm64` | Controls wheel platform tag |
| `SODIUM_INSTALL` | `system` | Use external libsodium (not bundled) |
| `SODIUMINCL` | `-I$PWD/build/libsodium/include` | Custom libsodium headers |
| `SODIUMLIB` | `-L$PWD/build/libsodium/lib` | Custom libsodium library |

### Why the repackaging step for a-Shell?

Standard `setuptools` produces wheels with `.abi3.so` extensions and a generic `ios_arm64` platform tag. a-Shell's Python expects:
- Extension suffix: `.cpython-313-iphoneos.so` (from `sysconfig.get_config_var('EXT_SUFFIX')`)
- Platform tag: `ios_14_arm64_iphoneos` (from `sysconfig.get_platform()` → `ios-14-arm64-iphoneos`)

The build script repackages the wheel to match these expectations, renaming the extension file and updating the `WHEEL` and `RECORD` metadata.

## Build details

| | macOS x86_64 | iOS arm64 (a-Shell) |
|---|---|---|
| **libsodium** | 1.0.19, host-built (bundled) | 1.0.19, cross-compiled (`--host=arm-apple-darwin`) |
| **Compiler** | Homebrew clang | Xcode clang via `xcrun --sdk iphoneos` |
| **Host Python** | 3.14 | 3.13.13 (Homebrew) |
| **Platform tag** | `macosx_26_0_x86_64` | `ios_14_arm64_iphoneos` |
| **Extension suffix** | `.abi3.so` | `.cpython-313-iphoneos.so` |
| **Mach-O target** | x86_64 macOS | arm64 iPhoneOS 14.0+ |
| **`_PYTHON_HOST_PLATFORM`** | _(default)_ | `ios-arm64` |
| **iOS SDK** | — | `iPhoneOS26.5.sdk` |
| **Min iOS version** | — | 14.0 |

## Acknowledgments

- [PyNaCl](https://github.com/pyca/pynacl) — upstream Python binding (Apache-2.0)
- [libsodium](https://github.com/jedisct1/libsodium) — NaCl cryptographic library (ISC License)
- [a-Shell](https://github.com/holzschu/a-Shell) — iOS POSIX terminal with Python
