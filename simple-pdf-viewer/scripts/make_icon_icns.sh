#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <source-image> [output-icns]" >&2
  echo "Example: $0 ~/Downloads/my-icon.png assets/AppIcon.icns" >&2
  exit 1
fi

SOURCE_IMAGE="$1"
OUTPUT_ICNS="${2:-assets/AppIcon.icns}"

if [[ ! -f "${SOURCE_IMAGE}" ]]; then
  echo "Source image not found: ${SOURCE_IMAGE}" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

mkdir -p "$(dirname "${OUTPUT_ICNS}")"

ICONSET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/appicon.iconset.XXXXXX")"
trap 'rm -rf "${ICONSET_DIR}"' EXIT

for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "${retina_size}" "${retina_size}" "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET_DIR}" -o "${OUTPUT_ICNS}"
echo "Created icon: ${ROOT_DIR}/${OUTPUT_ICNS}"
