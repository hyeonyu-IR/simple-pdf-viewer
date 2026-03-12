#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Hyeon's PDF Viewer"
BUNDLE_NAME="${APP_NAME}.app"
BUNDLE_ID="com.hyeonyu.hyeonspdfviewer"
APP_SOURCE="${ROOT_DIR}/dist/${BUNDLE_NAME}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LS_PLIST="${HOME}/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"

INSTALL_ROOT="/Applications"
INSTALL_PATH="${INSTALL_ROOT}/${BUNDLE_NAME}"
USE_SUDO=false
DRY_RUN=false
CLEAN_PDF_OVERRIDES=false

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [options]

Options:
  --user                  Install to ~/Applications instead of /Applications
  --clean-pdf-overrides   Remove per-file OpenWith override from PDFs in ~/Downloads and ~/Documents
  --dry-run               Print actions without changing anything
  -h, --help              Show this help
EOF
}

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

run_install_cmd() {
  if [[ "${USE_SUDO}" == "true" ]]; then
    run_cmd sudo "$@"
  else
    run_cmd "$@"
  fi
}

find_handler_index() {
  local pattern="$1"
  /usr/libexec/PlistBuddy -c "Print LSHandlers" "${LS_PLIST}" 2>/dev/null | \
    awk -v pat="${pattern}" '
      BEGIN { i=-1; in_dict=0; hit=0 }
      /^    Dict \{/ { i++; in_dict=1; hit=0; next }
      in_dict && index($0, pat) { hit=1 }
      in_dict && /^    }/ {
        if (hit) { print i; exit }
        in_dict=0
      }'
}

set_or_add_pdf_handler() {
  local idx
  idx="$(find_handler_index "LSHandlerContentType = com.adobe.pdf")"

  if [[ -n "${idx}" ]]; then
    run_cmd /usr/libexec/PlistBuddy -c "Set :LSHandlers:${idx}:LSHandlerRoleAll ${BUNDLE_ID}" "${LS_PLIST}"
    if /usr/libexec/PlistBuddy -c "Print :LSHandlers:${idx}:LSHandlerRoleViewer" "${LS_PLIST}" >/dev/null 2>&1; then
      run_cmd /usr/libexec/PlistBuddy -c "Set :LSHandlers:${idx}:LSHandlerRoleViewer ${BUNDLE_ID}" "${LS_PLIST}"
    else
      run_cmd /usr/libexec/PlistBuddy -c "Add :LSHandlers:${idx}:LSHandlerRoleViewer string ${BUNDLE_ID}" "${LS_PLIST}"
    fi
  else
    run_cmd /usr/libexec/PlistBuddy -c "Add :LSHandlers:0 dict" "${LS_PLIST}"
    run_cmd /usr/libexec/PlistBuddy -c "Add :LSHandlers:0:LSHandlerContentType string com.adobe.pdf" "${LS_PLIST}"
    run_cmd /usr/libexec/PlistBuddy -c "Add :LSHandlers:0:LSHandlerRoleAll string ${BUNDLE_ID}" "${LS_PLIST}"
    run_cmd /usr/libexec/PlistBuddy -c "Add :LSHandlers:0:LSHandlerRoleViewer string ${BUNDLE_ID}" "${LS_PLIST}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      INSTALL_ROOT="${HOME}/Applications"
      INSTALL_PATH="${INSTALL_ROOT}/${BUNDLE_NAME}"
      shift
      ;;
    --clean-pdf-overrides)
      CLEAN_PDF_OVERRIDES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
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

echo "Packaging app..."
run_cmd "${ROOT_DIR}/scripts/package_app.sh"

if [[ "${DRY_RUN}" != "true" && ! -d "${APP_SOURCE}" ]]; then
  echo "App bundle not found: ${APP_SOURCE}" >&2
  exit 1
fi

if [[ "${INSTALL_ROOT}" == "/Applications" && ! -w "${INSTALL_ROOT}" ]]; then
  USE_SUDO=true
fi

echo "Installing app to ${INSTALL_PATH}..."
run_install_cmd mkdir -p "${INSTALL_ROOT}"
run_install_cmd rm -rf "${INSTALL_PATH}"
run_install_cmd cp -R "${APP_SOURCE}" "${INSTALL_PATH}"
run_install_cmd xattr -dr com.apple.quarantine "${INSTALL_PATH}" || true

echo "Registering app with LaunchServices..."
run_cmd "${LSREGISTER}" -f "${INSTALL_PATH}" || true

echo "Setting default PDF handler to ${BUNDLE_ID}..."
set_or_add_pdf_handler

echo "Refreshing macOS caches..."
run_cmd killall cfprefsd || true
run_cmd killall Finder || true

if [[ "${CLEAN_PDF_OVERRIDES}" == "true" ]]; then
  echo "Removing per-file OpenWith override from PDFs in ~/Downloads and ~/Documents..."
  run_cmd find "${HOME}/Downloads" "${HOME}/Documents" -type f -name "*.pdf" -exec xattr -d com.apple.LaunchServices.OpenWith "{}" \; 2>/dev/null || true
fi

echo "Done."
echo "Installed app: ${INSTALL_PATH}"
if [[ "${CLEAN_PDF_OVERRIDES}" == "true" ]]; then
  echo "Per-file PDF OpenWith overrides were also cleaned."
fi
