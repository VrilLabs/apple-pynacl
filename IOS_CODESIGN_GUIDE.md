# iOS Code Signing Guide for PyNaCl Native Extensions

## The Problem

On non-jailbroken iOS, `dlopen()` enforces **mandatory code signature validation** at the
kernel level (via AMFI — Apple Mobile File Integrity). Unlike macOS, iOS has **no opt-out**
for library validation. The requirements are:

1. **The library must be packaged as a framework** (`.framework` bundle) — iOS does not
   support loading "naked" `.dylib` or `.so` files via `dlopen()` (Apple DTS, thread 670761)
2. **The framework must be signed with a valid Apple-trusted certificate** that chains to
   Apple Root CA — neither ad-hoc (`codesign -s -`) nor `ldid -S` pseudo-signatures are accepted
3. **The framework must be signed by the same Team ID as the host app** — iOS enforces
   this at the kernel level with no entitlement-based opt-out

### Why `disable-library-validation` doesn't help on iOS

The `com.apple.security.cs.disable-library-validation` entitlement is a **macOS-only**
feature (macOS 10.7+). It is part of the **Hardened Runtime**, which is a macOS security
mechanism. iOS does not have the Hardened Runtime — it uses a different, stricter code
signing enforcement via the kernel (AMFI). There is no iOS entitlement that allows loading
libraries signed by a different team.

> Source: [Apple Developer Documentation — Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
> "A Boolean value that indicates whether the app loads arbitrary plug-ins or frameworks,
> without requiring code signing. **macOS 10.7+**"

### Why previous signing attempts failed

| Signing method                  | Signature type   | iOS verdict              | Reason                                |
| ------------------------------- | ---------------- | ------------------------ | ------------------------------------- |
| None                            | Unsigned         | "completely unsigned"    | No `LC_CODE_SIGNATURE` load command   |
| `codesign -s -`                 | Adhoc (macOS)    | "code signature invalid" | Adhoc doesn't chain to Apple Root CA  |
| `ldid -S`                       | Pseudo-signature | "code signature invalid" | No Apple-trusted certificate chain    |
| Apple Dev cert (same team)      | Valid CA-chained | ✅ passes                | Chains to Apple Root CA, same Team ID |
| Apple Dev cert (different team) | Valid CA-chained | ❌ rejected              | Different Team ID, no opt-out on iOS  |

### Why a-Shell can't load custom `.so` files

a-Shell (App Store version, team **AsheKube**) loads its own Python extensions because
they are:

1. Packaged as **frameworks** inside the app bundle
2. Signed with the **same team** (AsheKube) during the Xcode build

When you `pip install` a package with a native `.so` extension, the `.so` is placed in
`site-packages` as a naked shared library — not in a framework, and not signed by
AsheKube. iOS rejects it at `dlopen()` time.

a-Shell's own documentation confirms this limitation:

> "For Python, you can install more packages with pip install packagename, but only if
> they are pure Python. The C compiler is not yet able to produce dynamic libraries that
> could be used by Python."

---

## Solutions

There are **three viable paths**, in order of practicality:

---

### Option A: Build a Custom a-Shell Signed with Your Team (Recommended)

Since iOS requires the framework to be signed by the **same team** as the host app, the
solution is to build a-Shell from source using **your** Apple Developer signing identity.
Then sign the PyNaCl framework with the **same** identity. Both will have the same Team ID,
and iOS will allow the load.

> **Note**: Adding `disable-library-validation` to the entitlements is **not necessary**
> and **does not work on iOS**. The key is simply that both the app and the framework are
> signed by the same team.

#### Prerequisites

- Apple Developer account (you have one as VLABS, LLC)
- Xcode 15+ installed on your Mac
- Your signing identity installed in Keychain

#### Step 1: Install your signing identity

```sh
# Verify your signing identities are installed
security find-identity -v -p codesigning

# You should see something like:
# 1) ABC123... "Apple Development: your@email.com (XXXXXXXXXX)"
# 2) DEF456... "Developer ID Application: VLABS, LLC (XXXXXXXXXX)"
```

If no identities are found, install them from Xcode:

1. Open Xcode → Settings → Accounts
2. Add your Apple ID
3. Select your team → Manage Certificates → add signing certificate

#### Step 2: Clone and configure a-Shell

```sh
git clone https://github.com/holzschu/a-shell.git
cd a-shell
git submodule update --init --recursive

# Download prebuilt frameworks (saves hours of compilation)
./downloadFrameworks.sh
```

#### Step 3: Add the `allow-unsigned-executable-memory` entitlement

Edit `a-Shell/a-Shell.entitlements` and add this entitlement inside the top-level `<dict>`
(this IS valid on iOS and is needed for FFI/JIT-style code):

```xml
<!-- Allow loading libraries with unsigned executable memory (needed for Python CFFI) -->
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
```

> **Do NOT add `disable-library-validation`** — it is macOS-only and has no effect on iOS.

#### Step 4: Configure signing in Xcode

1. Open `a-Shell.xcodeproj` in Xcode
2. Select the **a-Shell** target
3. **Signing & Capabilities** tab:
   - Team: **VLABS, LLC** (your team)
   - Bundle Identifier: change to something unique, e.g., `com.vrlabs.a-Shell`
4. Repeat for the **a-Shell-Intents** and **a-Shell-IntentsUI** targets
5. For **a-Shell-mini** target (if needed), same changes

#### Step 5: Build and deploy

1. Connect your iPad
2. Select your device as the run destination
3. Product → Build (⌘B)
4. Product → Run (⌘R) — this installs on the device

#### Step 6: Wrap the PyNaCl `.so` in a framework and sign it

iOS requires the binary to be in a `.framework` bundle. Create the framework structure,
sign it with **the same team identity**, and place it where a-Shell's Python can find it.

```sh
# Extract the wheel
WHL="pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl"
TMPDIR=$(mktemp -d)
python3 -m zipfile -e "$WHL" "$TMPDIR/root"
cd "$TMPDIR/root"

# The .so file
SO_FILE="nacl/_sodium.cpython-313-iphoneos.so"

# Create framework structure
FRAMEWORK_NAME="nacl._sodium"
FRAMEWORK_DIR="${FRAMEWORK_NAME}.framework"
mkdir -p "$FRAMEWORK_DIR"

# Copy the binary into the framework (must be MH_DYLIB, not MH_BUNDLE)
cp "$SO_FILE" "$FRAMEWORK_DIR/$FRAMEWORK_NAME"

# Create Info.plist (required for iOS framework)
cat > "$FRAMEWORK_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>nacl._sodium</string>
  <key>CFBundleIdentifier</key>
  <string>com.vrlabs.nacl._sodium</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>MinimumOSVersion</key>
  <string>14.0</string>
</dict>
</plist>
EOF

# Sign with your developer identity (same team as the custom a-Shell)
SIGN_IDENTITY="Apple Development: your@email.com (XXXXXXXXXX)"
codesign -s "$SIGN_IDENTITY" --force --timestamp=none \
    "$FRAMEWORK_DIR/$FRAMEWORK_NAME"

# Verify
codesign -dvvv "$FRAMEWORK_DIR/$FRAMEWORK_NAME"
```

#### Step 7: Deploy the framework to the iPad

Transfer the framework to the iPad and place it in a-Shell's Library directory. Then
configure Python to find it.

On the iPad in a-Shell:

```sh
# Find a-Shell's Library directory
SITE_PACKAGES=$(python3 -c "import site; print(site.getusersitepackages())")
echo $SITE_PACKAGES

# Copy the framework there (via AirDrop, iCloud, etc.)
# Then configure Python's sys.path or use a .pth file
```

Alternatively, add the framework to the a-Shell Xcode project as "Embed & Sign" and
rebuild — this is the most reliable approach.

---

### Option B: Use the Official Python-on-iOS Framework Approach

This is the approach recommended by Python's official documentation (PEP 730 / Python 3.14+).
It wraps each `.so` into an individual `.framework` bundle and uses a custom import loader.

This is only viable if you are building your **own** iOS app that embeds Python — it does
not work with the App Store version of a-Shell.

#### How it works

1. Each `.so` is converted to a framework: `Frameworks/nacl._sodium.framework/nacl._sodium`
2. Each framework has an `Info.plist` with `CFBundleExecutable` and `CFBundleIdentifier`
3. The original `.so` location gets a `.fwork` text file pointing to the framework
4. Python's `AppleFrameworkLoader` reads `.fwork` files and loads from Frameworks/
5. All frameworks are signed with the app's signing identity during the Xcode build

#### Quick reference

```sh
# Create framework structure
FRAMEWORK_NAME="nacl._sodium"
FRAMEWORK_DIR="Frameworks/${FRAMEWORK_NAME}.framework"
mkdir -p "${FRAMEWORK_DIR}"

# Copy the binary
cp nacl/_sodium.cpython-313-iphoneos.so "${FRAMEWORK_DIR}/${FRAMEWORK_NAME}"

# Create Info.plist
cat > "${FRAMEWORK_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>nacl._sodium</string>
  <key>CFBundleIdentifier</key>
  <string>com.vrlabs.nacl._sodium</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
</dict>
</plist>
EOF

# Create .fwork marker file at the original .so location
echo "Frameworks/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
    > nacl/_sodium.cpython-313-iphoneos.fwork

# Create .origin file in the framework
echo "../../nacl/_sodium.cpython-313-iphoneos.fwork" \
    > "${FRAMEWORK_DIR}/nacl._sodium.origin"
```

Then add the framework to your Xcode project with "Embed & Sign", and add a build phase
that processes Python libraries (see Python 3.14 docs for details).

---

### Option C: Jailbroken Device

On a jailbroken device, the kernel's code signature enforcement is patched out, so
`ldid -S` pseudo-signatures work fine. No Xcode or developer certificate needed.

```sh
# On the build Mac, sign with ldid and repackage
ldid -S nacl/_sodium.cpython-313-iphoneos.so
```

This is the simplest approach but requires a jailbreak, which most users don't have.

---

## Summary

| Approach                  | Works with stock a-Shell? | Requires jailbreak? | Requires Xcode? | Key requirement                  |
| ------------------------- | ------------------------- | ------------------- | --------------- | -------------------------------- |
| **A: Custom a-Shell**     | No (use custom build)     | No                  | Yes             | Same Team ID for app + framework |
| **B: Framework wrapping** | No (own app only)         | No                  | Yes             | Same Team ID for app + framework |
| **C: Jailbreak + ldid**   | Yes                       | Yes                 | No              | Kernel enforcement disabled      |

**Recommendation**: If you want to use PyNaCl in a-Shell on your iPad, **Option A**
(building a custom a-Shell with your VLABS signing identity) is the most practical
path. The critical insight is that **both the app and the framework must share the same
Team ID** — this is an iOS kernel-level requirement with no opt-out.

---

## Key Apple Sources

1. **Apple DTS (Quinn "The Eskimo")** — [Thread 670761](https://developer.apple.com/forums/thread/670761):

   > "iOS does not support 'naked' shared libraries (that is, .dylib files). If you want
   > to create a shared library for iOS, you must package the code as a framework."

2. **Apple DTS** — [Thread 670761](https://developer.apple.com/forums/thread/670761):

   > "Last I checked iOS has no problem loading a framework dynamically using dlopen."

3. **Apple Developer Documentation** — [Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation):

   > Platform: **macOS 10.7+** (not iOS)

4. **Apple DTS** — [Thread 706437](https://developer.apple.com/forums/thread/706437):

   > "Library validation is enabled by the Hardened Runtime but you may opt out of it
   > using the Disable Library Validation Entitlement." (macOS only — Hardened Runtime
   > does not exist on iOS)

5. **Python 3.14 Documentation** — [Using Python on iOS](https://docs.python.org/3/using/ios.html):

   > "The iOS App Store requires that all binary modules in an iOS app must be dynamic
   > libraries, contained in a framework with appropriate metadata, stored in the
   > Frameworks folder of the packaged app."

6. **Successful user report** — [Thread 670761](https://developer.apple.com/forums/thread/670761):
   > "I signed it with the same bundle identifier as the application, created a framework
   > for it... I then load the dylib directly from C++ code using dlopen... I can then
   > obtain a pointer to the simple function and execute it successfully."

---

## Quick-Start: Sign with VLABS Identity

Once you have your signing identity installed on the build Mac:

```sh
# 1. Find your identity
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "VLABS" | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "Using identity: $SIGN_IDENTITY"

# 2. Extract, wrap in framework, sign
WHL="/path/to/pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl"
TMPDIR=$(mktemp -d)
python3 -m zipfile -e "$WHL" "$TMPDIR/root"
cd "$TMPDIR/root"

# Create framework
FRAMEWORK_NAME="nacl._sodium"
mkdir -p "${FRAMEWORK_NAME}.framework"
cp nacl/_sodium.cpython-313-iphoneos.so "${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"

# Add Info.plist (see full instructions above for content)
# ...

# Sign with same identity as the custom a-Shell
codesign -s "$SIGN_IDENTITY" --force --timestamp=none \
    "${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"

# Verify
codesign -v "${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
```

This framework will load in a custom a-Shell signed with the same VLABS identity.
