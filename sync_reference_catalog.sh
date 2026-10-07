#!/usr/bin/env bash
set -euo pipefail

# Copy the catalog snapshot exported from the connected reference app into
# NappStore's developer-accessible app container. This is a development
# convenience for a device that is paired with this Mac; an installed IPA
# cannot read IAPPay's container at runtime because iOS app sandboxes are
# separate.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-dinh}"
BUNDLE_ID="${NAPPSTORE_BUNDLE_ID:-dev.dothanh.nappstore}"
CATALOG_DIR="${ROOT_DIR}/CatalogData/ReferenceCatalog"
if [[ -n "${NAPPSTORE_CATALOG_DIR:-}" ]]; then
    CATALOG_DIR="${NAPPSTORE_CATALOG_DIR}"
fi

if [[ ! -d "${CATALOG_DIR}" ]]; then
    echo "Không tìm thấy thư mục catalog: ${CATALOG_DIR}" >&2
    exit 1
fi

total=0
files=0
for catalog in "${CATALOG_DIR}"/*.json; do
    [[ -f "${catalog}" ]] || continue
    name="$(basename "${catalog}")"
    echo "Đồng bộ ${name} lên ${DEVICE} (${BUNDLE_ID})…"
    xcrun devicectl device copy to \
        --device "${DEVICE}" \
        --domain-type appDataContainer \
        --domain-identifier "${BUNDLE_ID}" \
        --source "${catalog}" \
        --destination "Documents/IAPCheck/${name}"
    count=$(/usr/bin/python3 - "${catalog}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(len(json.load(stream).get("items", [])))
PY
    )
    total=$((total + count))
    files=$((files + 1))
done
echo "Đã chép ${total} mục từ ${files} app; mở NappStore và nhấn Đồng bộ để đọc catalog."
