#!/bin/bash
set -euo pipefail

# ==============================================================================
# bootstrap-admin-macos.sh
# ==============================================================================
# Purpose:
# - Install Nix (Determinate Systems) and SAP Privileges on a fresh macOS system
# - Install SAP Privileges via the STANDARD PKG (localized UI), pinned + SHA256 verified
# - Configure SAP Privileges policies system-wide (timeout, auto-revoke, exclusions)
# - Produce a detailed log file in the admin user's home directory
#
# Usage:
# - Run ONCE from the break-glass admin account after a clean macOS install
# - Then create a standard (non-admin) user and continue with bootstrap-user.sh
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="$HOME/bootstrap-admin-${TIMESTAMP}.log"

# ------------------------------------------------------------------------------
# Configuration (edit consciously)
# ------------------------------------------------------------------------------
readonly PRIV_TIMEOUT_MINUTES="${PRIV_TIMEOUT_MINUTES:-20}"
readonly PRIV_REVOKE_AT_LOGIN="${PRIV_REVOKE_AT_LOGIN:-true}"   # true/false
readonly PRIV_REQUIRE_AUTH="${PRIV_REQUIRE_AUTH:-true}"         # true/false

# --- SAP Privileges: STANDARD (localized) PKG pinned by version + SHA256 ---
readonly PRIVILEGES_VERSION="${PRIVILEGES_VERSION:-2.5.0}"
readonly PRIVILEGES_PKG_NAME="${PRIVILEGES_PKG_NAME:-Privileges_2.5.0.pkg}"
readonly PRIVILEGES_PKG_SHA256="${PRIVILEGES_PKG_SHA256:-a7587035b340bd5b0f37fdba9b0e57f8072c59f958fdc8193870c4df16df3f5a}"
readonly PRIVILEGES_PKG_URL="https://github.com/SAP/macOS-enterprise-privileges/releases/download/${PRIVILEGES_VERSION}/${PRIVILEGES_PKG_NAME}"

# Paths
readonly PRIV_APP="/Applications/Privileges.app"
readonly PREF_DOMAIN_PATH="/Library/Preferences/corp.sap.privileges"  # system-wide domain path (no .plist)
readonly PREF_PLIST="${PREF_DOMAIN_PATH}.plist"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# ------------------------------------------------------------------------------
# Logging (stdout+stderr -> console and logfile)
# ------------------------------------------------------------------------------
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { printf '%s\n' "==> $*"; }
log_step() { printf '%s\n' "--> $*"; }
log_ok()   { printf '%s\n' "✓ $*"; }
log_warn() { printf '%s\n' "⚠️  WARNING: $*"; }
log_err()  { printf '%s\n' "❌ ERROR: $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log_err "Missing required tool: $1"; exit 1; }
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
TEMP_DIR=""
SUDO_KA_PID=""

cleanup() {
  # Stop sudo keep-alive quietly (avoid "Terminated" job message)
  if [[ -n "${SUDO_KA_PID:-}" ]]; then
    kill "$SUDO_KA_PID" >/dev/null 2>&1 || true
    wait "$SUDO_KA_PID" >/dev/null 2>&1 || true
  fi

  # Remove temp dir
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
    rm -rf "$TEMP_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Helpers (Bash 3.2 compatible)
# ------------------------------------------------------------------------------
tolower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

bool_is_true() {
  case "$(tolower "$1")" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

get_app_version() {
  local plist="$1/Contents/Info.plist"
  if [[ -f "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true
  fi
}

refresh_launchservices() {
  if [[ -x "$LSREGISTER" ]]; then
    log_step "Registering app with LaunchServices (Spotlight/Finder refresh)..."
    "$LSREGISTER" -f "$PRIV_APP" >/dev/null 2>&1 || true
    log_ok "LaunchServices registration done (best-effort)."
  else
    log_warn "LaunchServices tool not found; skipping refresh."
  fi
}

append_excluded_user_if_missing() {
  local user="$1"
  local existing
  existing="$(sudo /usr/bin/defaults read "$PREF_DOMAIN_PATH" RevokeAtLoginExcludedUsers 2>/dev/null || true)"

  if [[ -z "${existing:-}" ]]; then
    sudo /usr/bin/defaults write "$PREF_DOMAIN_PATH" RevokeAtLoginExcludedUsers -array "$user"
    log_ok "Excluded users list created with: $user"
    return 0
  fi

  printf '%s\n' "$existing" | /usr/bin/grep -qE "\"${user}\"|${user}" && {
    log_ok "User already excluded from auto-revoke: $user"
    return 0
  }

  sudo /usr/bin/defaults write "$PREF_DOMAIN_PATH" RevokeAtLoginExcludedUsers -array-add "$user"
  log_ok "User added to excluded list: $user"
}

# ==============================================================================
# Preflight
# ==============================================================================
log_info "Bootstrap Admin Account (macOS)"
log_info "Script:   $SCRIPT_NAME"
log_info "Log file: $LOG_FILE"
echo ""

need_cmd sw_vers
need_cmd uname
need_cmd sudo
need_cmd curl
need_cmd shasum
need_cmd awk
need_cmd tee
need_cmd pgrep
need_cmd softwareupdate
need_cmd defaults
need_cmd id
need_cmd installer
need_cmd spctl
need_cmd codesign
need_cmd xattr
need_cmd /usr/libexec/PlistBuddy

MAC_OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
ARCH="$(/usr/bin/uname -m)"
ADMIN_USER="$(/usr/bin/id -un)"
MAIN_PID="$$"

log_info "macOS version: $MAC_OS_VERSION"
log_info "Architecture:  $ARCH"
log_info "Admin user:    $ADMIN_USER"
echo ""

# Sudo + keep-alive
log_step "Requesting admin privileges (sudo)..."
sudo -v
( while true; do sudo -n true; sleep 60; /bin/kill -0 "$MAIN_PID" 2>/dev/null || exit; done ) >/dev/null 2>&1 &
SUDO_KA_PID="$!"
disown "$SUDO_KA_PID" >/dev/null 2>&1 || true
log_ok "sudo is active."

# ==============================================================================
# Rosetta 2 (Apple Silicon)
# ==============================================================================
if [[ "$ARCH" == "arm64" ]]; then
  if ! /usr/bin/pgrep oahd >/dev/null 2>&1; then
    log_step "Installing Rosetta 2 (Apple Silicon detected)..."
    if sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license; then
      log_ok "Rosetta 2 installed."
    else
      log_warn "Rosetta 2 installation failed (it may already be installed, or you may be offline)."
    fi
  else
    log_step "Rosetta 2 is already installed."
  fi
fi
echo ""

# ==============================================================================
# 1) Install Nix (Determinate Systems)
# ==============================================================================
log_info "Nix: check / install"

if ! command -v nix >/dev/null 2>&1; then
  log_step "Installing Nix (Determinate Systems installer)..."
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
  log_ok "Nix installer completed successfully."

  # Try to load Nix into the current shell (best-effort).
  # Temporarily disable nounset (set -u) while sourcing third-party scripts.
  if [[ -f "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]]; then
    log_step "Loading Nix environment into current shell (best-effort)..."
    # shellcheck disable=SC1091
    set +u
    source "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" || true
    set -u
  fi

  if command -v nix >/dev/null 2>&1; then
    log_ok "Nix is available in this shell: $(nix --version)"
  else
    log_info "Nix is installed but not available in the current shell session."
    log_info "Open a new shell and re-run this script."
    exit 0
  fi
else
  log_ok "Nix is already installed: $(nix --version)"
fi
echo ""

# ==============================================================================
# 2) Install SAP Privileges (STANDARD PKG, pinned + verified)
# ==============================================================================
log_info "SAP Privileges: check / install (PKG)"

install_privileges_pkg() {
  TEMP_DIR="$(/usr/bin/mktemp -d)"
  local pkg="$TEMP_DIR/${PRIVILEGES_PKG_NAME}"

  log_step "Downloading SAP Privileges PKG (${PRIVILEGES_VERSION})..."
  log_step "Source: $PRIVILEGES_PKG_URL"
  /usr/bin/curl -fsSL -o "$pkg" "$PRIVILEGES_PKG_URL"
  log_ok "Download completed."

  log_step "Verifying SHA-256 checksum..."
  local actual expected
  actual="$(sha256_file "$pkg")"
  expected="$(tolower "$PRIVILEGES_PKG_SHA256")"
  actual="$(tolower "$actual")"

  if [[ "$actual" != "$expected" ]]; then
    log_err "Checksum mismatch!"
    log_err "Expected: $PRIVILEGES_PKG_SHA256"
    log_err "Actual:   $actual"
    exit 1
  fi
  log_ok "Checksum verified."

  log_step "Installing PKG..."
  sudo /usr/sbin/installer -pkg "$pkg" -target / >/dev/null
  log_ok "PKG installed."

  if [[ -d "$PRIV_APP" ]]; then
    log_step "Removing quarantine attributes (if present)..."
    sudo /usr/bin/xattr -dr com.apple.quarantine "$PRIV_APP" 2>/dev/null || true

    log_step "Gatekeeper assessment (informational)..."
    /usr/sbin/spctl -a -vv "$PRIV_APP" || true

    log_step "codesign verification (basic)..."
    if /usr/bin/codesign -v "$PRIV_APP" 2>/dev/null; then
      log_ok "Code signature (basic) looks OK."
    else
      log_warn "Code signature could not be verified."
    fi

    refresh_launchservices

    local ver
    ver="$(get_app_version "$PRIV_APP")"
    log_ok "SAP Privileges installed.${ver:+ Version: $ver}"
  else
    log_warn "Privileges.app not found at $PRIV_APP after installation (unexpected)."
  fi
}

if [[ -d "$PRIV_APP" ]]; then
  ver="$(get_app_version "$PRIV_APP")"
  log_ok "Privileges is already installed at $PRIV_APP.${ver:+ Version: $ver}"
  log_step "Gatekeeper assessment (informational)..."
  /usr/sbin/spctl -a -vv "$PRIV_APP" || true
else
  install_privileges_pkg
fi
echo ""

# ==============================================================================
# 3) Configure SAP Privileges (system-wide)
# ==============================================================================
log_info "SAP Privileges: system-wide configuration"

log_step "Setting timeout (DockToggleTimeout) to ${PRIV_TIMEOUT_MINUTES} minutes..."
sudo /usr/bin/defaults write "$PREF_DOMAIN_PATH" DockToggleTimeout -int "$PRIV_TIMEOUT_MINUTES"
log_ok "Timeout set."

log_step "Configuring auto-revoke at next login (RevokePrivilegesAtLogin=${PRIV_REVOKE_AT_LOGIN})..."
if bool_is_true "$PRIV_REVOKE_AT_LOGIN"; then
  sudo /usr/bin/defaults write "$PREF_DOMAIN_PATH" RevokePrivilegesAtLogin -bool true
else
  sudo /usr/bin/defaults write "$PREF_DOMAIN_PATH" RevokePrivilegesAtLogin -bool false
fi
log_ok "Auto-revoke at login configured."

log_step "Ensuring break-glass admin user is excluded from auto-revoke..."
append_excluded_user_if_missing "$ADMIN_USER"

log_step "Requiring authentication when requesting privileges (best-effort)..."
if bool_is_true "$PRIV_REQUIRE_AUTH"; then
  if sudo /usr/bin/defaults write "$PREF_DOMAIN_PATH" RequireAuthentication -bool true 2>/dev/null; then
    log_ok "RequireAuthentication enabled."
  else
    log_warn "RequireAuthentication may not be supported by this Privileges version."
  fi
fi

log_step "Forcing system-wide preferences to be written to disk..."
sudo /usr/bin/defaults read "$PREF_DOMAIN_PATH" >/dev/null
log_ok "Preferences flushed to disk."

log_step "Ensuring configuration plist is readable by all users..."
if [[ -f "$PREF_PLIST" ]]; then
  sudo /bin/chmod 644 "$PREF_PLIST" || true
  log_ok "Permissions set to 644: $PREF_PLIST"
else
  log_warn "Expected plist not found at $PREF_PLIST (it may be created later)."
fi

log_step "Current Privileges settings (from $PREF_DOMAIN_PATH):"
{
  printf '%s\n' "  DockToggleTimeout:            $(sudo /usr/bin/defaults read "$PREF_DOMAIN_PATH" DockToggleTimeout 2>/dev/null || echo "n/a")"
  printf '%s\n' "  RevokePrivilegesAtLogin:      $(sudo /usr/bin/defaults read "$PREF_DOMAIN_PATH" RevokePrivilegesAtLogin 2>/dev/null || echo "n/a")"
  printf '%s\n' "  RevokeAtLoginExcludedUsers:   $(sudo /usr/bin/defaults read "$PREF_DOMAIN_PATH" RevokeAtLoginExcludedUsers 2>/dev/null || echo "n/a")"
  printf '%s\n' "  RequireAuthentication:        $(sudo /usr/bin/defaults read "$PREF_DOMAIN_PATH" RequireAuthentication 2>/dev/null || echo "n/a")"
} || true

echo ""

# ==============================================================================
# Finish
# ==============================================================================
printf '%s\n' "=============================================="
log_ok "Admin bootstrap completed successfully."
printf '%s\n' "=============================================="
echo ""
printf '%s\n' "Next steps:"
printf '%s\n' ""
printf '%s\n' "1) Create a standard (non-admin) user"
printf '%s\n' "   -> System Settings -> Users & Groups"
printf '%s\n' "   -> Ensure: 'Allow this user to administer this computer' is DISABLED"
printf '%s\n' ""
printf '%s\n' "2) Log out and sign in as the standard user"
printf '%s\n' ""
printf '%s\n' "3) Open SAP Privileges ($PRIV_APP)"
printf '%s\n' "   -> Request admin privileges temporarily (timeout: ${PRIV_TIMEOUT_MINUTES} minutes)"
printf '%s\n' "   -> Note: privileges are auto-revoked at the next login (if enabled)"
printf '%s\n' ""
printf '%s\n' "4) Run your user bootstrap script (e.g., bootstrap-user.sh)"
printf '%s\n' ""
printf '%s\n' "Tip: Add Privileges to the Dock for quick access."
printf '%s\n' "Log file: $LOG_FILE"
echo ""
