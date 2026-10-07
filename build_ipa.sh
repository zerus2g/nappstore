#!/usr/bin/env bash
set -euo pipefail

# Build a normal development-signed IPA without invoking xcodebuild. This
# script still uses Apple's SDK and Swift compiler, but all staging, signing,
# and packaging happen here so the output is reproducible from Terminal.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NappStore"
IPA_NAME="NappStore-dev"
OUTPUT_DIR="${ROOT_DIR}/output"
BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE_DIR="${ROOT_DIR}/build/ipa-${BUILD_STAMP}"
PAYLOAD_DIR="${STAGE_DIR}/Payload"
APP_DIR="${PAYLOAD_DIR}/${APP_NAME}.app"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

mkdir -p "${APP_DIR}" "${OUTPUT_DIR}"

if command -v rg >/dev/null 2>&1; then
    while IFS= read -r file; do
        SWIFT_FILES+=("${file}")
    done < <(rg --files "${ROOT_DIR}/Sources" -g '*.swift' | sort)
else
    while IFS= read -r file; do
        SWIFT_FILES+=("${file}")
    done < <(find "${ROOT_DIR}/Sources" -type f -name '*.swift' | sort)
fi
if [[ "${#SWIFT_FILES[@]}" -eq 0 ]]; then
    echo "Không tìm thấy mã nguồn Swift trong Sources" >&2
    exit 1
fi

echo "[1/4] Biên dịch ${#SWIFT_FILES[@]} file Swift bằng SDK iphoneos"
xcrun --sdk iphoneos swiftc \
    -target arm64-apple-ios16.0 \
    -sdk "${SDK_PATH}" \
    -module-name "${APP_NAME}" \
    -O \
    -parse-as-library \
    -framework UIKit \
    -framework SwiftUI \
    -framework Foundation \
    -framework CoreServices \
    -framework StoreKit \
    "${SWIFT_FILES[@]}" \
    -o "${APP_DIR}/${APP_NAME}"

echo "[2/4] Đặt metadata và icon"
cp "${ROOT_DIR}/Info.plist" "${APP_DIR}/Info.plist"
if [[ -f "${ROOT_DIR}/AppIcon.png" ]]; then
    cp "${ROOT_DIR}/AppIcon.png" "${APP_DIR}/AppIcon.png"
    cp "${ROOT_DIR}/AppIcon.png" "${APP_DIR}/AppIcon60x60@2x.png"
    cp "${ROOT_DIR}/AppIcon.png" "${APP_DIR}/AppIcon60x60@3x.png"
fi
if [[ -d "${ROOT_DIR}/CatalogData" ]]; then
    cp -R "${ROOT_DIR}/CatalogData" "${APP_DIR}/CatalogData"
fi

PROFILE_PATH="${PROVISIONING_PROFILE:-}"
if [[ -z "${PROFILE_PATH}" ]]; then
    PROFILE_PATH="$(ls -t "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision 2>/dev/null | head -n 1 || true)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ { print $2; exit }')"
fi

if [[ -n "${SIGN_IDENTITY}" && -n "${PROFILE_PATH}" && -f "${PROFILE_PATH}" ]]; then
    echo "[3/4] Ký Apple Development: ${SIGN_IDENTITY}"
    cp "${PROFILE_PATH}" "${APP_DIR}/embedded.mobileprovision"
    SIGNING_ENTITLEMENTS="${STAGE_DIR}/signing-entitlements.plist"
    # A profile carries the required application-identifier and team
    # entitlements. Passing an empty plist to codesign drops those values and
    # produces an IPA that iOS refuses to install. Copy only the profile's
    # entitlements and explicitly discard jailbreak-only keys.
    security cms -D -i "${PROFILE_PATH}" > "${STAGE_DIR}/profile.plist"
    /usr/bin/python3 - "${STAGE_DIR}/profile.plist" "${SIGNING_ENTITLEMENTS}" <<'PY'
import plistlib, sys
source, destination = sys.argv[1:]
with open(source, "rb") as stream:
    profile = plistlib.load(stream)
entitlements = dict(profile.get("Entitlements", {}))
for key in ("platform-application", "com.apple.private.security.no-sandbox"):
    entitlements.pop(key, None)
with open(destination, "wb") as stream:
    plistlib.dump(entitlements, stream, fmt=plistlib.FMT_XML)
PY
    # --deep is needed here because the raw swiftc bundle contains PNG
    # resources that Apple's signer treats as nested bundle components when
    # sealing an ad-hoc app directory assembled outside Xcode.
    codesign --force --deep --sign "${SIGN_IDENTITY}" \
        --entitlements "${SIGNING_ENTITLEMENTS}" \
        --timestamp=none "${APP_DIR}"
    codesign --verify --deep --strict "${APP_DIR}"
else
    echo "[3/4] Không tìm thấy Apple Development identity/profile; tạo IPA chưa ký" >&2
fi

echo "[4/4] Đóng gói IPA"
IPA_PATH="${OUTPUT_DIR}/${IPA_NAME}.ipa"
(cd "${STAGE_DIR}" && /usr/bin/zip -qr "${IPA_PATH}" Payload)

echo "IPA: ${IPA_PATH}"
if [[ -n "${SIGN_IDENTITY}" && -n "${PROFILE_PATH}" ]]; then
    echo "Thiết bị có thể cài IPA bằng devicectl/Sideloadly với profile hiện tại."
else
    echo "IPA chưa ký; hãy đặt SIGN_IDENTITY và PROVISIONING_PROFILE rồi chạy lại."
fi
