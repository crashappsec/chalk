#!/bin/bash
# release-macos.sh — produce a signed, notarized chalk binary tarball
# and a signed, notarized, stapled .pkg installer for macOS.
#
# Usage:
#   ./scripts/release-macos.sh                  # full pipeline
#   ./scripts/release-macos.sh --no-notarize    # skip notarize (dev speed)
#   ./scripts/release-macos.sh --no-pkg         # binary tarball only
#   ./scripts/release-macos.sh --help
#
# Env overrides (auto-detected from the keychain when unset):
#   APPLICATION_IDENTITY  "Developer ID Application: Crash Override, Inc (...)"
#   INSTALLER_IDENTITY    "Developer ID Installer:   Crash Override, Inc (...)"
#   NOTARY_PROFILE        notarytool keychain-profile name
#                         default: CRAYON_NOTARY (shared crash-override
#                         credentials; override or set empty to skip notarize)
#   BUNDLE_ID             pkg bundle id (default: com.crashoverride.chalk)
#   INSTALL_PREFIX        pkg install prefix (default: /usr/local)
#
# Build env (caller's responsibility — script does NOT modify these):
#   PATH                  must contain a working nim/nimble + openssl3
#   SDKROOT               must be set to xcrun --show-sdk-path output
#                         (clang's -target flag disables SDK auto-detection)
#
# Outputs (in dist/):
#   chalk-<version>-<arch>.tar.gz  notarized raw binary
#   chalk-<version>-<arch>.pkg     signed + notarized + stapled installer

set -euo pipefail

# --------------------------------------------------------------------
# Args + env
# --------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    cat >&2 <<'EOF'
error: don't run release under sudo.

Notarization uses your login keychain (where the Developer ID certs
and the notary profile live); root's keychain is different and won't
have them. Re-run as your own user.
EOF
    exit 1
fi

NO_NOTARIZE=0
NO_PKG=0
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NO_NOTARIZE=1 ;;
        --no-pkg)      NO_PKG=1 ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \?//' | head -40
            exit 0 ;;
        *)
            echo "unknown flag: $arg" >&2
            echo "usage: $0 [--no-notarize] [--no-pkg]" >&2
            exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(make -s version)"
ARCH="$(uname -m)"
BUNDLE_ID="${BUNDLE_ID:-com.crashoverride.chalk}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
DIST="$ROOT/dist"
mkdir -p "$DIST"

TAR_NAME="chalk-${VERSION}-${ARCH}.tar.gz"
PKG_NAME="chalk-${VERSION}-${ARCH}.pkg"
TAR_OUT="$DIST/$TAR_NAME"
PKG_OUT="$DIST/$PKG_NAME"

echo "==> chalk version : $VERSION"
echo "==> arch          : $ARCH"
echo "==> bundle id     : $BUNDLE_ID"
echo "==> install prefix: $INSTALL_PREFIX"

# --------------------------------------------------------------------
# Identities
# --------------------------------------------------------------------

if [[ -z "${APPLICATION_IDENTITY:-}" ]]; then
    APPLICATION_IDENTITY=$(security find-identity -v -p basic 2>/dev/null \
        | awk -F'"' '/"Developer ID Application:/ { print $2; exit }')
    if [[ -z "$APPLICATION_IDENTITY" ]]; then
        cat >&2 <<EOF
error: no Developer ID Application identity found in your keychain.

Install one via Xcode → Settings → Accounts → Manage Certificates → +
→ "Developer ID Application", or set APPLICATION_IDENTITY=... explicitly.

Available identities:
$(security find-identity -v -p basic)
EOF
        exit 1
    fi
fi
echo "==> Application identity: $APPLICATION_IDENTITY"

if (( ! NO_PKG )) && [[ -z "${INSTALLER_IDENTITY:-}" ]]; then
    INSTALLER_IDENTITY=$(security find-identity -v -p basic 2>/dev/null \
        | awk -F'"' '/"Developer ID Installer:/ { print $2; exit }')
    if [[ -z "$INSTALLER_IDENTITY" ]]; then
        cat >&2 <<EOF
error: no Developer ID Installer identity found in your keychain.

Without it the .pkg cannot be signed. Either install one (Xcode →
Settings → Accounts → Manage Certificates → + → "Developer ID
Installer") or pass --no-pkg to skip pkg generation.
EOF
        exit 1
    fi
    echo "==> Installer identity:   $INSTALLER_IDENTITY"
fi

# Default to CRAYON_NOTARY (pre-existing profile under same Apple Dev
# team). --no-notarize clears it to suppress notarize on both artifacts.
NOTARY_PROFILE="${NOTARY_PROFILE-CRAYON_NOTARY}"
if (( NO_NOTARIZE )); then
    NOTARY_PROFILE=""
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Notary profile:       $NOTARY_PROFILE"
fi

# --------------------------------------------------------------------
# Stage 1: build
# --------------------------------------------------------------------
echo
echo "===================================================================="
echo "== [1] make release"
echo "===================================================================="

if [[ ! -x ./chalk || ! -f ./chalk.bck ]]; then
    make DOCKER= release
fi

if [[ ! -x ./chalk ]]; then
    echo "error: build did not produce ./chalk" >&2
    exit 1
fi

# chalk.bck is the canonical "default-config-loaded" build state —
# nimble's `after build` hook runs `chalk load default` against the
# freshly compiled binary, then the Makefile snapshots the result as
# chalk.bck.  That's the binary we want to ship: it has the default
# config embedded but no later user-config drift.
#
# Until chalk grew a native Mach-O codec, `chalk load default` on
# macOS produced a bash-script trampoline around a base64'd Mach-O,
# which Apple's notary refused.  The native codec (src/plugins/
# codecMacho.nim) marks via LC_NOTE in place, so chalk.bck is a real
# Mach-O now.  We sanity-check that below.
SRC_BIN="$ROOT/chalk.bck"
if [[ ! -x "$SRC_BIN" ]]; then
    echo "error: $SRC_BIN missing — make release should have produced it" >&2
    exit 1
fi
echo "==> source binary: $SRC_BIN"
file "$SRC_BIN"

# Defensive: ensure the binary is real Mach-O, not a script wrapper.
# If this fires, the native codec failed to handle this build (refused
# at scan time, hit no-slack, etc.) and the macos wrapper codec took
# over.  notarize will then reject; better to fail loudly here.
SRC_HEAD=$(head -c 4 "$SRC_BIN" | xxd -p)
case "$SRC_HEAD" in
    cffaedfe|feedfacf|cafebabe)
        : ;;  # MH_CIGAM_64 / MH_MAGIC_64 / FAT_MAGIC — OK
    *)
        cat >&2 <<EOF
error: $SRC_BIN is not a Mach-O binary (magic: $SRC_HEAD).

This usually means the native Mach-O codec refused this build and
fell back to the script-wrapper codec.  Apple's notary won't accept
that.  Check the build logs for "chalk_macho:" warnings (insufficient
load-command slack, real-cert signature, etc.) and rebuild with the
underlying issue resolved.
EOF
        exit 1
        ;;
esac

# --------------------------------------------------------------------
# Stage 2: codesign the binary
# --------------------------------------------------------------------
echo
echo "===================================================================="
echo "== [2] codesign chalk binary"
echo "===================================================================="

STAGE="$DIST/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$SRC_BIN" "$STAGE/chalk"

codesign --force --timestamp --options runtime \
    --sign "$APPLICATION_IDENTITY" "$STAGE/chalk"
codesign --verify --strict --verbose=2 "$STAGE/chalk"

# --------------------------------------------------------------------
# Stage 3: notarize the raw binary (zipped for transport only)
# --------------------------------------------------------------------
echo
echo "===================================================================="
echo "== [3] notarize binary"
echo "===================================================================="

NOTARIZE_ZIP="$DIST/chalk-binary.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$STAGE/chalk" "$NOTARIZE_ZIP"

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> submitting $NOTARIZE_ZIP to notarytool ..."
    OUT=$(xcrun notarytool submit "$NOTARIZE_ZIP" \
            --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
    echo "$OUT"
    if ! grep -q "status: Accepted" <<<"$OUT"; then
        SUB_ID=$(awk '/id:/ { print $2; exit }' <<<"$OUT" || true)
        if [[ -n "${SUB_ID:-}" ]]; then
            echo "==> notarytool log:"
            xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        echo "error: binary notarization failed" >&2
        exit 1
    fi
    # A raw mach-O cannot be stapled. Apple records the notarization
    # against the binary's signature hash; Gatekeeper looks it up
    # online on first launch.
fi
rm -f "$NOTARIZE_ZIP"

# --------------------------------------------------------------------
# Stage 4: produce the binary tarball
# --------------------------------------------------------------------
echo
echo "===================================================================="
echo "== [4] tarball: $TAR_NAME"
echo "===================================================================="

# tar from the stage dir so the archive contains a top-level `chalk`,
# not `dist/stage/chalk`.
tar -C "$STAGE" -czf "$TAR_OUT" chalk
ls -la "$TAR_OUT"

if (( NO_PKG )); then
    echo
    echo "==> --no-pkg set, skipping pkg pipeline"
    echo "==> done. tarball: $TAR_OUT"
    exit 0
fi

# --------------------------------------------------------------------
# Stage 5: pkgbuild (component pkg)
# --------------------------------------------------------------------
echo
echo "===================================================================="
echo "== [5] pkgbuild component"
echo "===================================================================="

PKG_ROOT="$DIST/pkgroot"
COMPONENT_PKG="$DIST/chalk-component.pkg"
rm -rf "$PKG_ROOT" "$COMPONENT_PKG"

# Strip the leading `/` from INSTALL_PREFIX so we can join under PKG_ROOT.
PREFIX_REL="${INSTALL_PREFIX#/}"
mkdir -p "$PKG_ROOT/$PREFIX_REL/bin"
cp "$STAGE/chalk" "$PKG_ROOT/$PREFIX_REL/bin/chalk"
chmod 755 "$PKG_ROOT/$PREFIX_REL/bin/chalk"

pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_PKG"

# --------------------------------------------------------------------
# Stage 6: productbuild (distribution pkg) + sign
# --------------------------------------------------------------------
echo
echo "===================================================================="
echo "== [6] productbuild distribution + sign"
echo "===================================================================="

DIST_XML="$DIST/distribution.xml"
RESOURCES="$DIST/Resources"
rm -rf "$RESOURCES"
mkdir -p "$RESOURCES"
cp "$ROOT/scripts/macos/welcome.html"    "$RESOURCES/welcome.html"
cp "$ROOT/scripts/macos/conclusion.html" "$RESOURCES/conclusion.html"

# Substitute version + bundle id into the distribution template.
sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
    -e "s|@COMPONENT_PKG@|$(basename "$COMPONENT_PKG")|g" \
    "$ROOT/scripts/macos/distribution.xml.tmpl" > "$DIST_XML"

UNSIGNED_PKG="$DIST/chalk-unsigned.pkg"
productbuild \
    --distribution "$DIST_XML" \
    --package-path "$DIST" \
    --resources "$RESOURCES" \
    "$UNSIGNED_PKG"

productsign \
    --sign "$INSTALLER_IDENTITY" \
    --timestamp \
    "$UNSIGNED_PKG" "$PKG_OUT"

rm -f "$UNSIGNED_PKG"

pkgutil --check-signature "$PKG_OUT" | head -10

# --------------------------------------------------------------------
# Stage 7: notarize + staple the pkg
# --------------------------------------------------------------------
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo
    echo "===================================================================="
    echo "== [7] notarize + staple pkg"
    echo "===================================================================="
    OUT=$(xcrun notarytool submit "$PKG_OUT" \
            --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
    echo "$OUT"
    if ! grep -q "status: Accepted" <<<"$OUT"; then
        SUB_ID=$(awk '/id:/ { print $2; exit }' <<<"$OUT" || true)
        if [[ -n "${SUB_ID:-}" ]]; then
            echo "==> notarytool log:"
            xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        echo "error: pkg notarization failed" >&2
        exit 1
    fi
    xcrun stapler staple "$PKG_OUT"
    xcrun stapler validate "$PKG_OUT"
fi

# --------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------
rm -rf "$STAGE" "$PKG_ROOT" "$RESOURCES" "$DIST_XML" "$COMPONENT_PKG"

echo
echo "===================================================================="
echo "== done"
echo "===================================================================="
ls -la "$TAR_OUT" "$PKG_OUT"
