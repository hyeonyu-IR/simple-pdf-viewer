#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Hyeon's PDF Viewer"
BUNDLE_NAME="${APP_NAME}.app"
BUNDLE_ID="com.hyeonyu.hyeonspdfviewer"
EXECUTABLE_NAME="simple-pdf-viewer"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${BUNDLE_NAME}"
BIN_PATH="${ROOT_DIR}/.build/release/${EXECUTABLE_NAME}"
PLIST_PATH="${APP_DIR}/Contents/Info.plist"
VERSION_FILE="${ROOT_DIR}/VERSION"
DEFAULT_APP_VERSION="1.0.0"
DEFAULT_ICON_ICNS_SOURCE_PATH="${ROOT_DIR}/assets/AppIcon.icns"
DEFAULT_ICON_IMAGE_SOURCE_PATH="${ROOT_DIR}/pdf-viewer-converted.png"
APP_VERSION_ARG=""
APP_BUILD_ARG=""
ICON_SOURCE_PATH_ARG=""
ICON_BUNDLE_NAME="AppIcon.icns"
ICON_PLIST_ENTRY=""
USES_CUSTOM_BUNDLE_ICON=false

usage() {
  cat <<'EOF'
Usage: ./scripts/package_app.sh [options]

Options:
  --version <x.y.z>    Set CFBundleShortVersionString (overrides VERSION file/env)
  --build <number>     Set CFBundleVersion (overrides derived default/env)
  --icon <path>        Use custom .icns file path for app icon
  -h, --help           Show this help

Environment:
  APP_VERSION          Same as --version
  APP_BUILD            Same as --build
  APP_ICON_PATH        Same as --icon (supports .icns or image files like .png)
EOF
}

apply_custom_bundle_icon() {
  local source_image="$1"
  local app_path="$2"
  local temp_png
  local temp_rsrc
  local icon_file

  temp_png="$(mktemp "${TMPDIR:-/tmp}/appicon.XXXXXX.png")"
  temp_rsrc="$(mktemp "${TMPDIR:-/tmp}/appicon.XXXXXX.rsrc")"
  icon_file="${app_path}/Icon"$'\r'

  trap 'rm -f "${temp_png}" "${temp_rsrc}"' RETURN

  sips -s format png "${source_image}" --out "${temp_png}" >/dev/null
  sips -i "${temp_png}" >/dev/null
  DeRez -only icns "${temp_png}" > "${temp_rsrc}"
  rm -f "${icon_file}"
  Rez -append "${temp_rsrc}" -o "${icon_file}"
  SetFile -a C "${app_path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ -z "${2:-}" ]]; then
        echo "Missing value for --version" >&2
        usage
        exit 1
      fi
      APP_VERSION_ARG="$2"
      shift 2
      ;;
    --build)
      if [[ -z "${2:-}" ]]; then
        echo "Missing value for --build" >&2
        usage
        exit 1
      fi
      APP_BUILD_ARG="$2"
      shift 2
      ;;
    --icon)
      if [[ -z "${2:-}" ]]; then
        echo "Missing value for --icon" >&2
        usage
        exit 1
      fi
      ICON_SOURCE_PATH_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

FILE_VERSION="${DEFAULT_APP_VERSION}"
if [[ -f "${VERSION_FILE}" ]]; then
  FILE_VERSION="$(head -n 1 "${VERSION_FILE}" | tr -d '[:space:]')"
fi

APP_VERSION="${APP_VERSION_ARG:-${APP_VERSION:-${FILE_VERSION}}}"
APP_BUILD_DEFAULT="$(echo "${APP_VERSION}" | tr -cd '0-9')"
if [[ -z "${APP_BUILD_DEFAULT}" ]]; then
  APP_BUILD_DEFAULT="1"
fi
APP_BUILD="${APP_BUILD_ARG:-${APP_BUILD:-${APP_BUILD_DEFAULT}}}"
ICON_SOURCE_PATH="${ICON_SOURCE_PATH_ARG:-${APP_ICON_PATH:-}}"

if [[ -z "${ICON_SOURCE_PATH}" ]]; then
  if [[ -f "${DEFAULT_ICON_ICNS_SOURCE_PATH}" ]]; then
    ICON_SOURCE_PATH="${DEFAULT_ICON_ICNS_SOURCE_PATH}"
  elif [[ -f "${DEFAULT_ICON_IMAGE_SOURCE_PATH}" ]]; then
    ICON_SOURCE_PATH="${DEFAULT_ICON_IMAGE_SOURCE_PATH}"
  fi
fi

if [[ -n "${ICON_SOURCE_PATH}" && "${ICON_SOURCE_PATH}" != /* ]]; then
  ICON_SOURCE_PATH="${ROOT_DIR}/${ICON_SOURCE_PATH}"
fi

echo "Building release binary..."
swift build -c release --package-path "${ROOT_DIR}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Release binary not found: ${BIN_PATH}" >&2
  exit 1
fi

echo "Creating app bundle at ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"

if [[ -f "${ICON_SOURCE_PATH}" && "${ICON_SOURCE_PATH##*.}" == "icns" ]]; then
  cp "${ICON_SOURCE_PATH}" "${APP_DIR}/Contents/Resources/${ICON_BUNDLE_NAME}"
  ICON_PLIST_ENTRY=$(cat <<EOF
  <key>CFBundleIconFile</key>
  <string>${ICON_BUNDLE_NAME}</string>
EOF
)
  echo "Using custom .icns icon: ${ICON_SOURCE_PATH}"
elif [[ -f "${ICON_SOURCE_PATH}" ]]; then
  apply_custom_bundle_icon "${ICON_SOURCE_PATH}" "${APP_DIR}"
  USES_CUSTOM_BUNDLE_ICON=true
  echo "Using custom bundle icon image: ${ICON_SOURCE_PATH}"
else
  echo "No custom icon found at ${ICON_SOURCE_PATH} (using default app icon)."
fi

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>PDF Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.adobe.pdf</string>
      </array>
    </dict>
  </array>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>(c) 2026 Hyeon Yu</string>
${ICON_PLIST_ENTRY}
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Bundle version: ${APP_VERSION} (${APP_BUILD})"
if [[ "${USES_CUSTOM_BUNDLE_ICON}" == "true" ]]; then
  echo "Skipping ad-hoc signing because custom bundle icons add Finder metadata that codesign rejects."
else
  echo "Ad-hoc signing app bundle..."
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null
fi

echo "Done."
echo "App bundle: ${APP_DIR}"
echo "Double-click it in Finder or run:"
echo "open \"${APP_DIR}\""
