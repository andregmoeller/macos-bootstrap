#!/bin/bash
set -euo pipefail

# ==============================================================================
# bootstrap-admin-macos.sh
# ==============================================================================
# Purpose:
#   Establish and maintain the absolute baseline of a macOS system (Apple Silicon).
#   Installs Nix (Determinate Systems) and SAP Privileges, configures system-wide
#   Privileges policies, and upgrades components when pinned versions change.
#   Designed to be run repeatedly (idempotent).
#
# Requirements:
#   macOS 14 (Sonoma) or later on Apple Silicon (arm64).
#
# Usage:
#   Run from the break-glass admin account after a clean macOS install,
#   and again whenever the pinned versions in this script are updated.
#   Then create a standard (non-admin) user and continue with bootstrap-user.sh.
#
# Environment overrides (optional):
#   PRIV_TIMEOUT_MINUTES   – auto-revoke timeout in minutes  (default: 20)
#   PRIV_REVOKE_AT_LOGIN   – revoke admin at login           (default: true)
#   PRIV_REQUIRE_AUTH      – require auth for privilege grant (default: true)
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="$HOME/bootstrap-admin-${TIMESTAMP}.log"
readonly LOCK_DIR="/tmp/bootstrap-admin.lock"

# ------------------------------------------------------------------------------
# Configuration – edit consciously
# ------------------------------------------------------------------------------

# These three are normalized to "true"/"false" and made readonly in
# validate_and_normalize_inputs() after parsing the user-supplied values.
PRIV_TIMEOUT_MINUTES="${PRIV_TIMEOUT_MINUTES:-20}"
PRIV_REVOKE_AT_LOGIN="${PRIV_REVOKE_AT_LOGIN:-true}"
PRIV_REQUIRE_AUTH="${PRIV_REQUIRE_AUTH:-true}"

readonly MIN_MACOS_MAJOR=14  # Sonoma – required by Nix (nixpkgs 25.05+)

# --- Nix (Determinate Systems installer) pinned by version + SHA256 ---
# renovate: datasource=github-releases depName=DeterminateSystems/nix-installer
readonly NIX_INSTALLER_VERSION="${NIX_INSTALLER_VERSION:-0.32.3}"
readonly NIX_INSTALLER_SHA256="${NIX_INSTALLER_SHA256:-REPLACE_WITH_ACTUAL_SHA256}"
readonly NIX_INSTALLER_URL="https://github.com/DeterminateSystems/nix-installer/releases/download/v${NIX_INSTALLER_VERSION}/nix-installer-aarch64-darwin"

# --- SAP Privileges: standard (localized) PKG pinned by version + SHA256 ---
# renovate: datasource=github-releases depName=SAP/macOS-enterprise-privileges
readonly PRIVILEGES_VERSION="${PRIVILEGES_VERSION:-2.5.0}"
readonly PRIVILEGES_PKG_NAME="Privileges_${PRIVILEGES_VERSION}.pkg"
readonly PRIVILEGES_PKG_SHA256="${PRIVILEGES_PKG_SHA256:-a7587035b340bd5b0f37fdba9b0e57f8072c59f958fdc8193870c4df16df3f5a}"
readonly PRIVILEGES_PKG_URL="https://github.com/SAP/macOS-enterprise-privileges/releases/download/${PRIVILEGES_VERSION}/${PRIVILEGES_PKG_NAME}"
# NOTE: If SAP rotates their Developer ID certificate, this string must be updated.
# Check with: pkgutil --check-signature <pkg-file>
readonly PRIVILEGES_EXPECTED_SIGNER="Developer ID Installer: SAP SE"

# --- Paths ---
readonly PRIV_APP="/Applications/Privileges.app"
readonly PRIV_PREF_DOMAIN="/Library/Preferences/corp.sap.privileges"
readonly PRIV_PREF_PLIST="${PRIV_PREF_DOMAIN}.plist"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly NIX_DAEMON_SH="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

readonly LOG_RETENTION_DAYS=30
readonly CURL_OPTS=(--proto =https --tlsv1.2 --retry 3 --retry-all-errors --connect-timeout 15 --max-time 600)

# ------------------------------------------------------------------------------
# Logging
#   stdout + stderr go to both console and logfile via tee.
#   Colors are determined BEFORE the exec redirect, while stdout is still the
#   terminal. After exec, stdout becomes a pipe to tee and [[ -t 1 ]] would
#   always return false.
# ------------------------------------------------------------------------------

# Detect TTY before redirecting stdout through tee.
if [[ -t 1 ]]; then
  readonly BOLD='\033[1m'  RED='\033[0;31m'  GREEN='\033[0;32m'
  readonly YELLOW='\033[0;33m'  BLUE='\033[0;34m'  NC='\033[0m'
else
  readonly BOLD=""  RED=""  GREEN=""  YELLOW=""  BLUE=""  NC=""
fi

exec > >(tee -a "$LOG_FILE") 2>&1

_ts() { date "+%Y-%m-%d %H:%M:%S"; }

log_info()      { printf "${BLUE}[%s] [INFO]  %s${NC}\n" "$(_ts)" "$*"; }
log_step()      { printf "${BOLD}[%s] [STEP]  %s${NC}\n" "$(_ts)" "$*"; }
log_ok()        { printf "${GREEN}[%s] [OK]    %s${NC}\n" "$(_ts)" "$*"; }
log_warn()      { printf "${YELLOW}[%s] [WARN]  %s${NC}\n" "$(_ts)" "$*"; }
log_err()       { printf "${RED}[%s] [ERROR] %s${NC}\n" "$(_ts)" "$*" >&2; }
log_separator() { printf '%s\n' "----------------------------------------------------------------------"; }

# ------------------------------------------------------------------------------
# Helpers (Bash 3.2 or later – must be defined before all functions that use them)
# ------------------------------------------------------------------------------
tolower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Validate that a value is a recognized boolean.
is_valid_bool() {
  case "$(tolower "$1")" in true|false|1|0|yes|no|y|n|on|off) return 0 ;; *) return 1 ;; esac
}

# Test whether a value is truthy.
bool_is_true() {
  case "$(tolower "$1")" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac
}

# Normalize a boolean value to "true" or "false".
normalize_bool() {
  if bool_is_true "$1"; then printf 'true'; else printf 'false'; fi
}

# Check that a command is available in PATH.
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_err "Required tool not found in PATH: $1"
    exit 1
  fi
}

# Check that a binary exists at a specific absolute path.
need_executable() {
  if ! [[ -x "$1" ]]; then
    log_err "Required executable not found: $1"
    exit 1
  fi
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_sha256() {
  local file="$1" expected="$2" label="${3:-file}"
  log_step "Verifying SHA-256 for ${label}..."

  # Let shasum handle normalization and comparison.
  if printf '%s  %s\n' "$expected" "$file" | /usr/bin/shasum -a 256 --check --status 2>/dev/null; then
    log_ok "SHA-256 verified for ${label}."
  else
    local actual
    actual="$(sha256_file "$file")"
    log_err "SHA-256 mismatch for ${label}!"
    log_err "  Expected: $expected"
    log_err "  Actual:   $actual"
    exit 1
  fi
}

download_or_fail() {
  local url="$1" dest="$2" label="${3:-file}"
  log_step "Downloading ${label}..."
  log_info "  URL: $url"
  if ! /usr/bin/curl "${CURL_OPTS[@]}" -fsSL -o "$dest" "$url"; then
    log_err "Download failed: $url"
    exit 1
  fi
  log_ok "Download complete: ${label}"
}

get_app_version() {
  local plist="$1/Contents/Info.plist"
  if [[ -f "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true
  fi
}

macos_major_version() {
  printf '%s' "$1" | /usr/bin/awk -F. '{print $1}'
}

refresh_launchservices() {
  if [[ -x "$LSREGISTER" ]]; then
    log_step "Refreshing LaunchServices registration..."
    "$LSREGISTER" -f "$PRIV_APP" >/dev/null 2>&1 || true
    log_ok "LaunchServices registration done."
  else
    log_warn "lsregister not found at expected path – skipping LaunchServices refresh."
  fi
}

# NOTE: This function parses the human-readable output of `pkgutil --check-signature`.
# Apple has not changed this format since macOS 10.6, and it is widely relied upon
# by MDM tooling, but it is not contractually stable. If a future macOS release
# changes the output format, this function will need to be updated.
verify_pkg_signature() {
  local pkg="$1" expected_signer="$2"
  log_step "Verifying PKG signature..."
  local sig_output
  sig_output="$(/usr/sbin/pkgutil --check-signature "$pkg" 2>&1)" || true

  if printf '%s' "$sig_output" | /usr/bin/grep -q "Status: signed"; then
    log_ok "PKG is signed."
    if printf '%s' "$sig_output" | /usr/bin/grep -qF "$expected_signer"; then
      log_ok "PKG signer matches expected: ${expected_signer}"
    else
      printf '%s\n' "$sig_output" | while IFS= read -r line; do log_warn "  $line"; done
      log_err "PKG signer does not match expected '${expected_signer}' – aborting."
      exit 1
    fi
  else
    printf '%s\n' "$sig_output" | while IFS= read -r line; do log_warn "  $line"; done
    log_err "PKG is not signed – aborting."
    exit 1
  fi
}

# NOTE: There is a theoretical race condition between the PlistBuddy check and the
# defaults write. This is safe in practice because the script is protected by a
# lockfile (LOCK_DIR) and is never run in parallel.
append_excluded_user_if_missing() {
  local user="$1"

  # Iterate via PlistBuddy for exact string matching (no substring false positives).
  if [[ -f "$PRIV_PREF_PLIST" ]]; then
    local i=0 entry
    while true; do
      entry="$(sudo /usr/libexec/PlistBuddy -c "Print :RevokeAtLoginExcludedUsers:${i}" "$PRIV_PREF_PLIST" 2>/dev/null)" || break
      if [[ "$entry" == "$user" ]]; then
        log_ok "User '${user}' is already in the auto-revoke exclusion list."
        return 0
      fi
      i=$(( i + 1 ))
    done
  fi

  local existing
  existing="$(sudo /usr/bin/defaults read "$PRIV_PREF_DOMAIN" RevokeAtLoginExcludedUsers 2>/dev/null || true)"

  if [[ -z "${existing:-}" ]]; then
    sudo /usr/bin/defaults write "$PRIV_PREF_DOMAIN" RevokeAtLoginExcludedUsers -array "$user"
    log_ok "Created exclusion list with user: ${user}"
  else
    sudo /usr/bin/defaults write "$PRIV_PREF_DOMAIN" RevokeAtLoginExcludedUsers -array-add "$user"
    log_ok "Added user '${user}' to auto-revoke exclusion list."
  fi
}

purge_old_logs() {
  local count
  count="$(find "$HOME" -maxdepth 1 -name 'bootstrap-admin-*.log' -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -gt 0 ]]; then
    log_step "Removing ${count} log file(s) older than ${LOG_RETENTION_DAYS} days..."
    find "$HOME" -maxdepth 1 -name 'bootstrap-admin-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    log_ok "Old logs purged."
  fi
}

flush_preferences() {
  log_step "Flushing preferences cache (restarting cfprefsd)..."
  # cfprefsd is designed to be killed at any time – launchd restarts it immediately.
  # Pending writes are not lost: cfprefsd handles writes via XPC transactions, so
  # a kill between transactions is safe. This is the standard approach used by MDM
  # tools and Apple's own utilities to force a plist sync to disk.
  sudo killall cfprefsd 2>/dev/null || true
  sleep 1
  log_ok "Preferences cache flushed."
}

# ------------------------------------------------------------------------------
# Input validation and normalization
# ------------------------------------------------------------------------------
validate_and_normalize_inputs() {
  if ! [[ "$PRIV_TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] || [[ "$PRIV_TIMEOUT_MINUTES" -eq 0 ]]; then
    log_err "PRIV_TIMEOUT_MINUTES must be a positive integer, got: '$PRIV_TIMEOUT_MINUTES'"
    exit 1
  fi

  if ! is_valid_bool "$PRIV_REVOKE_AT_LOGIN"; then
    log_err "PRIV_REVOKE_AT_LOGIN must be a boolean, got: '$PRIV_REVOKE_AT_LOGIN'"
    exit 1
  fi

  if ! is_valid_bool "$PRIV_REQUIRE_AUTH"; then
    log_err "PRIV_REQUIRE_AUTH must be a boolean, got: '$PRIV_REQUIRE_AUTH'"
    exit 1
  fi

  # Normalize to "true"/"false" and lock down – from here on only these two values exist.
  PRIV_REVOKE_AT_LOGIN="$(normalize_bool "$PRIV_REVOKE_AT_LOGIN")"
  PRIV_REQUIRE_AUTH="$(normalize_bool "$PRIV_REQUIRE_AUTH")"
  readonly PRIV_TIMEOUT_MINUTES PRIV_REVOKE_AT_LOGIN PRIV_REQUIRE_AUTH
}

# Guard against placeholder SHA256 hashes that were never configured.
validate_sha256_configured() {
  if [[ "$NIX_INSTALLER_SHA256" == REPLACE_WITH_* ]]; then
    log_err "NIX_INSTALLER_SHA256 still contains a placeholder."
    log_err "To obtain the correct hash, run:"
    log_err "  curl -fsSL -o /tmp/nix-installer '${NIX_INSTALLER_URL}'"
    log_err "  shasum -a 256 /tmp/nix-installer"
    log_err "Then set NIX_INSTALLER_SHA256 in this script to the resulting hash."
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Reentrance guard (mkdir is atomic on macOS)
# ------------------------------------------------------------------------------
acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log_err "Another instance is already running (lock: $LOCK_DIR)."
    log_err "If this is stale, remove it manually: rm -rf $LOCK_DIR"
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
TEMP_DIR=""
SUDO_KA_PID=""

cleanup() {
  local exit_code=$?

  if [[ -n "${SUDO_KA_PID:-}" ]]; then
    kill "$SUDO_KA_PID" >/dev/null 2>&1 || true
    wait "$SUDO_KA_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
    rm -rf "$TEMP_DIR" >/dev/null 2>&1 || true
  fi

  rm -rf "$LOCK_DIR" 2>/dev/null || true

  if [[ "$exit_code" -ne 0 ]]; then
    log_err "Script exited with code $exit_code. Check log: $LOG_FILE"
  fi

  # Preserve the original exit code. Without this, a signal like SIGINT (130)
  # could be masked by the exit code of the last command in this trap.
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ==============================================================================
# Preflight
# ==============================================================================
log_separator
log_info "Bootstrap Admin Account (macOS)"
log_info "Script:    $SCRIPT_NAME"
log_info "Log file:  $LOG_FILE"
log_info "Timestamp: $TIMESTAMP"
log_separator

acquire_lock

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
need_cmd pkgutil
need_executable /usr/libexec/PlistBuddy

MAC_OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
ARCH="$(/usr/bin/uname -m)"
ADMIN_USER="$(/usr/bin/id -un)"
MAIN_PID="$$"

log_info "macOS:        $MAC_OS_VERSION"
log_info "Architecture: $ARCH"
log_info "Admin user:   $ADMIN_USER"
log_separator

# Architecture check – this script supports Apple Silicon only.
if [[ "$ARCH" != "arm64" ]]; then
  log_err "This script requires Apple Silicon (arm64). Detected: $ARCH"
  exit 1
fi
log_ok "Architecture: arm64 (Apple Silicon)"

# Minimum macOS version check
MAC_OS_MAJOR="$(macos_major_version "$MAC_OS_VERSION")"
if [[ "$MAC_OS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]]; then
  log_err "macOS $MIN_MACOS_MAJOR (Sonoma) or later is required (detected: $MAC_OS_VERSION)."
  exit 1
fi
log_ok "macOS version $MAC_OS_VERSION meets minimum requirement (>= $MIN_MACOS_MAJOR)."

validate_and_normalize_inputs
validate_sha256_configured

# Sudo is the admin gate – if the user can authenticate via sudo, they have
# sufficient privileges. This works with SAP Privileges (temporary elevation)
# without requiring permanent admin group membership.
log_step "Requesting admin privileges (sudo)..."
if ! sudo -v; then
  log_err "Could not obtain sudo privileges."
  log_err "If SAP Privileges is installed, grant yourself admin rights first, then re-run."
  exit 1
fi
(
  # Disable errexit: sudo -n may fail when the Kerberos ticket expires,
  # which is expected. The loop exits when the parent process is gone.
  set +e
  while true; do
    sudo -n true 2>/dev/null
    sleep 60
    /bin/kill -0 "$MAIN_PID" 2>/dev/null || exit
  done
) >/dev/null 2>&1 &
SUDO_KA_PID="$!"
# disown suppresses job-control messages. The || true is intentional: disown may
# silently fail in non-interactive Bash 3.2 shells, which is harmless here.
disown "$SUDO_KA_PID" >/dev/null 2>&1 || true
log_ok "sudo session established, keep-alive running (PID $SUDO_KA_PID)."

# Single temp directory for all downloads (cleaned up in trap)
TEMP_DIR="$(/usr/bin/mktemp -d)"
log_ok "Temp directory: $TEMP_DIR"

# Housekeeping
purge_old_logs

# ==============================================================================
# Rosetta 2 (Apple Silicon)
# ==============================================================================
log_separator
log_info "Rosetta 2"

# pkgutil --pkg-info is more reliable than checking whether oahd is running,
# because the Rosetta daemon only starts when an Intel binary is active.
if /usr/sbin/pkgutil --pkg-info=com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
  log_ok "Rosetta 2 is already installed."
else
  log_step "Installing Rosetta 2..."
  if sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license; then
    log_ok "Rosetta 2 installed successfully."
  else
    log_warn "Rosetta 2 installation returned an error (may already be installed or offline)."
  fi
fi

# ==============================================================================
# 1) Nix (Determinate Systems) – pinned installer binary + SHA256
# ==============================================================================
log_separator
log_info "Nix (Determinate Systems)"

install_nix() {
  local installer_bin="$TEMP_DIR/nix-installer"

  download_or_fail "$NIX_INSTALLER_URL" "$installer_bin" "Nix installer v${NIX_INSTALLER_VERSION} (arm64)"
  verify_sha256 "$installer_bin" "$NIX_INSTALLER_SHA256" "Nix installer binary"

  chmod +x "$installer_bin"
  log_step "Running Nix installer v${NIX_INSTALLER_VERSION}..."
  "$installer_bin" install --no-confirm
  log_ok "Nix installer completed."

  # Load the full Nix daemon environment (PATH, socket, env vars) into this shell.
  # A bare PATH export is insufficient – the daemon profile sets up more than just PATH.
  if [[ -e "$NIX_DAEMON_SH" ]]; then
    log_step "Sourcing Nix daemon environment ($NIX_DAEMON_SH)..."
    # Temporarily disable nounset: third-party profile scripts may reference unset variables.
    # shellcheck disable=SC1091
    set +u; . "$NIX_DAEMON_SH"; set -u
    log_ok "Nix environment sourced."
  else
    log_warn "Nix daemon profile not found at $NIX_DAEMON_SH – falling back to PATH export."
    export PATH="/nix/var/nix/profiles/default/bin:$PATH"
  fi

  if command -v nix >/dev/null 2>&1; then
    log_ok "Nix is available in this shell: $(nix --version)"
  else
    log_err "Nix was installed but is not available in the current shell."
    log_err "Open a new terminal and re-run this script to complete the bootstrap."
    exit 1
  fi
}

upgrade_nix() {
  log_step "Attempting to upgrade Nix (Determinate Systems)..."
  if sudo determinate-nixd upgrade 2>&1; then
    log_ok "Nix upgraded successfully: $(nix --version)"
  else
    log_warn "Could not upgrade Nix (may already be the latest version)."
  fi
}

if command -v nix >/dev/null 2>&1; then
  log_ok "Nix is already installed: $(nix --version)"
  upgrade_nix
else
  install_nix
fi

# ==============================================================================
# 2) SAP Privileges – standard PKG, pinned + SHA256 + signature verified
# ==============================================================================
log_separator
log_info "SAP Privileges (v${PRIVILEGES_VERSION})"

install_privileges_pkg() {
  local pkg="$TEMP_DIR/${PRIVILEGES_PKG_NAME}"

  download_or_fail "$PRIVILEGES_PKG_URL" "$pkg" "SAP Privileges PKG v${PRIVILEGES_VERSION}"
  verify_sha256 "$pkg" "$PRIVILEGES_PKG_SHA256" "Privileges PKG"
  verify_pkg_signature "$pkg" "$PRIVILEGES_EXPECTED_SIGNER"

  log_step "Installing PKG to /..."
  if ! sudo /usr/sbin/installer -pkg "$pkg" -target / 2>&1; then
    log_err "PKG installation failed. See installer output above."
    exit 1
  fi
  log_ok "PKG installation completed."

  if [[ -d "$PRIV_APP" ]]; then
    log_step "Removing quarantine attribute (if present)..."
    sudo /usr/bin/xattr -dr com.apple.quarantine "$PRIV_APP" 2>/dev/null || true

    log_step "Running Gatekeeper assessment..."
    local spctl_output
    spctl_output="$(/usr/sbin/spctl -a -vv "$PRIV_APP" 2>&1)" || true
    printf '%s\n' "$spctl_output" | while IFS= read -r line; do log_info "  spctl: $line"; done
    # Use spctl exit code rather than parsing output text – more stable across
    # macOS versions than grepping for "rejected".
    if /usr/sbin/spctl -a "$PRIV_APP" 2>/dev/null; then
      log_ok "Gatekeeper: accepted."
    else
      log_warn "Gatekeeper REJECTED Privileges.app – review manually before use."
    fi

    log_step "Verifying code signature..."
    if /usr/bin/codesign -v "$PRIV_APP" 2>/dev/null; then
      log_ok "Code signature valid."
    else
      log_warn "Code signature could not be verified – review manually."
    fi

    refresh_launchservices

    local ver
    ver="$(get_app_version "$PRIV_APP")"
    log_ok "SAP Privileges installed (version: ${ver:-unknown})."
  else
    log_err "Privileges.app not found at $PRIV_APP after installation."
    exit 1
  fi
}

if [[ -d "$PRIV_APP" ]]; then
  installed_ver="$(get_app_version "$PRIV_APP")"
  if [[ "${installed_ver:-}" == "$PRIVILEGES_VERSION" ]]; then
    log_ok "Privileges ${installed_ver} matches pinned version – no action needed."
    log_step "Running Gatekeeper assessment..."
    /usr/sbin/spctl -a -vv "$PRIV_APP" 2>&1 || true
  else
    # Enforces the pinned version exactly – this may upgrade OR downgrade.
    # If a newer version was installed manually, it will be replaced.
    log_step "Privileges ${installed_ver:-unknown} installed, pinned version is ${PRIVILEGES_VERSION} – enforcing pinned version (may downgrade)..."
    install_privileges_pkg
  fi
else
  log_step "Privileges.app not found – installing..."
  install_privileges_pkg
fi

# ==============================================================================
# 3) SAP Privileges – system-wide configuration
# ==============================================================================
# These settings are written as "unmanaged preferences" via `defaults write`.
# If this Mac is later enrolled in an MDM (Jamf, Kandji, etc.), MDM-managed
# Configuration Profiles take precedence and may override these values.
# For standalone / break-glass setups this approach is appropriate.
# ==============================================================================
log_separator
log_info "SAP Privileges: system-wide configuration"

log_step "Setting DockToggleTimeout to ${PRIV_TIMEOUT_MINUTES} minutes..."
sudo /usr/bin/defaults write "$PRIV_PREF_DOMAIN" DockToggleTimeout -int "$PRIV_TIMEOUT_MINUTES"
log_ok "DockToggleTimeout = ${PRIV_TIMEOUT_MINUTES}"

# Use explicit if/else for -bool writes rather than passing the variable directly.
# macOS `defaults` officially documents TRUE/FALSE/YES/NO/1/0 as valid -bool values.
# Lowercase "true"/"false" works in practice but is not documented behavior.
log_step "Setting RevokePrivilegesAtLogin to ${PRIV_REVOKE_AT_LOGIN}..."
if [[ "$PRIV_REVOKE_AT_LOGIN" == "true" ]]; then
  sudo /usr/bin/defaults write "$PRIV_PREF_DOMAIN" RevokePrivilegesAtLogin -bool true
else
  sudo /usr/bin/defaults write "$PRIV_PREF_DOMAIN" RevokePrivilegesAtLogin -bool false
fi
log_ok "RevokePrivilegesAtLogin = ${PRIV_REVOKE_AT_LOGIN}"

# Only manage the exclusion list when auto-revoke is active – otherwise irrelevant.
if [[ "$PRIV_REVOKE_AT_LOGIN" == "true" ]]; then
  log_step "Adding '${ADMIN_USER}' to auto-revoke exclusion list..."
  append_excluded_user_if_missing "$ADMIN_USER"
else
  log_info "Auto-revoke is disabled – skipping exclusion list management."
fi

if [[ "$PRIV_REQUIRE_AUTH" == "true" ]]; then
  log_step "Setting RequireAuthentication to true..."
  if sudo /usr/bin/defaults write "$PRIV_PREF_DOMAIN" RequireAuthentication -bool true 2>/dev/null; then
    log_ok "RequireAuthentication = true"
  else
    log_warn "RequireAuthentication could not be set (may require MDM or is unsupported in Privileges ${PRIVILEGES_VERSION})."
  fi
fi

flush_preferences

if [[ -f "$PRIV_PREF_PLIST" ]]; then
  log_step "Setting plist permissions to 644..."
  sudo /bin/chmod 644 "$PRIV_PREF_PLIST" || true
  log_ok "Permissions set: $PRIV_PREF_PLIST"
else
  log_warn "Plist not found at $PRIV_PREF_PLIST – it may be created on first use."
fi

log_separator
log_info "Current SAP Privileges configuration:"
log_info "  DockToggleTimeout:          $(sudo /usr/bin/defaults read "$PRIV_PREF_DOMAIN" DockToggleTimeout 2>/dev/null || echo 'not set')"
log_info "  RevokePrivilegesAtLogin:    $(sudo /usr/bin/defaults read "$PRIV_PREF_DOMAIN" RevokePrivilegesAtLogin 2>/dev/null || echo 'not set')"
log_info "  RevokeAtLoginExcludedUsers: $(sudo /usr/bin/defaults read "$PRIV_PREF_DOMAIN" RevokeAtLoginExcludedUsers 2>/dev/null || echo 'not set')"
log_info "  RequireAuthentication:      $(sudo /usr/bin/defaults read "$PRIV_PREF_DOMAIN" RequireAuthentication 2>/dev/null || echo 'not set')"

# ==============================================================================
# Done
# ==============================================================================
log_separator
log_ok "Admin bootstrap completed successfully."
log_separator

# Intentionally without log prefix – these are user-facing instructions for the
# terminal, not structured log output that needs to be machine-parsed.
printf '\n'
printf '%s\n' "Next steps:"
printf '%s\n' ""
printf '%s\n' "  1. Create a standard (non-admin) user"
printf '%s\n' "     System Settings > Users & Groups"
printf '%s\n' "     Ensure 'Allow this user to administer this computer' is DISABLED"
printf '%s\n' ""
printf '%s\n' "  2. Log out and sign in as the standard user"
printf '%s\n' ""
printf '%s\n' "  3. Open SAP Privileges ($PRIV_APP)"
printf '%s\n' "     Request admin privileges temporarily (timeout: ${PRIV_TIMEOUT_MINUTES} min)"
if [[ "$PRIV_REVOKE_AT_LOGIN" == "true" ]]; then
  printf '%s\n' "     Privileges are auto-revoked at next login"
fi
printf '%s\n' ""
printf '%s\n' "  4. Run your user bootstrap script (e.g., bootstrap-user.sh)"
printf '%s\n' ""
printf '%s\n' "  Tip: Add Privileges to the Dock for quick access."
printf '%s\n' "  Nix upgrade: sudo determinate-nixd upgrade"
printf '%s\n' "  Log: $LOG_FILE"
printf '\n'
