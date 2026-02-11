# bootstrap-admin-macos.sh

This document explains **what** the admin bootstrap script does, **why**
each step exists, and **how** it contributes to a secure, reproducible
macOS setup.

It is intended as long-term documentation for future re-installs,
audits, or onboarding.

---

## Purpose of the Admin Bootstrap

The admin bootstrap establishes and **maintains the absolute baseline**
of a macOS system (Apple Silicon).

Key principles:

- The admin account is **not** used for daily work
- Admin privileges are **temporary and explicit**
- The system can be **recreated after a clean install**
- Components are **upgraded** when pinned versions change
- Configuration is **auditable and documented**

The script is **idempotent** — designed to be run repeatedly, both for
initial setup and ongoing maintenance.

---

## Requirements

- **macOS 14 (Sonoma)** or later — required by Nix (nixpkgs 25.05+)
- **Apple Silicon (arm64)** — Intel is not supported
- **Internet connection** — for downloading pinned binaries
- **sudo access** — via admin account or temporary elevation through SAP Privileges

---

## High-Level Responsibilities

`bootstrap-admin-macos.sh` performs the following tasks:

1. Validate the environment (architecture, macOS version, sudo)
2. Install Rosetta 2 (if not present)
3. Install or upgrade Nix (Determinate Systems)
4. Install or enforce the pinned version of SAP Privileges
5. Configure SAP Privileges system-wide
6. Leave the system ready for a standard (non-admin) user

---

## Why a Separate Admin Account?

macOS requires at least one admin account.

Instead of using that account daily, we treat it as a **break-glass
account**:

- Used only for:
  - Initial system setup
  - Ongoing baseline maintenance (re-running the script after version bumps)
  - Emergency recovery
- Never used for development or daily work
- Excluded from privilege auto-revocation to guarantee access

This significantly reduces the attack surface of the system.

---

## Step-by-Step Breakdown

### 1. Preflight Checks

The script verifies:

- Required system tools are present (`need_cmd` for PATH tools,
  `need_executable` for absolute paths like PlistBuddy)
- Architecture is arm64 (Apple Silicon)
- macOS version is 14 (Sonoma) or later
- `sudo` access is available — this is the primary admin gate, allowing
  both permanent admin accounts and temporary elevation via SAP Privileges
- Environment variable inputs are valid (boolean normalization, integer checks)
- SHA-256 hashes are configured (placeholder detection with actionable
  error messages including the exact commands to compute the hash)

A **sudo keep-alive** runs in the background to avoid repeated password
prompts. It has `set +e` to handle ticket expiry gracefully, and is
cleaned up via the exit trap.

A **reentrance guard** (atomic `mkdir` lock) prevents parallel execution.

All output is written to a **timestamped log file** in the admin home
directory, with ISO 8601 timestamps and terminal-aware colored output
(colors are detected before stdout is redirected through `tee`).

#### Automatic Cleanup

The script uses a trap (`EXIT INT TERM`) to ensure proper cleanup:

- Stops the sudo keep-alive background process
- Removes temporary download directories
- Releases the lock directory
- Preserves the original exit code (so signals like SIGINT/130 are not masked)
- Executes even if the script encounters errors

#### Log Retention

Old log files (older than 30 days) are automatically purged at the
start of each run.

---

### 2. Rosetta 2 (Apple Silicon)

Rosetta 2 is installed if not already present.

Detection uses `pkgutil --pkg-info=com.apple.pkg.RosettaUpdateAuto`,
which is more reliable than checking whether the `oahd` daemon is
running (it only runs when an Intel binary is actively executing).

This ensures compatibility with:

- x86-only tools
- Some prebuilt binaries
- Legacy installers

---

### 3. Installing and Upgrading Nix (Determinate Systems)

Nix is installed using the **Determinate Systems installer**, which
provides:

- A secure, supported Nix daemon
- An encrypted APFS volume for `/nix`
- Proper integration with macOS (launchd, Time Machine exclusions)

#### Installation security

The installer binary is **not** fetched via `curl | sh`. Instead:

1. The binary is downloaded to a temp directory
2. Its SHA-256 hash is verified against the pinned value in the script
3. Only then is it executed

The version and hash are annotated with `# renovate:` comments for
automated version bumps.

#### Post-installation environment

The script sources the Nix daemon profile
(`/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`) to load
the full environment (PATH, socket, env vars) into the current shell.
`set +u` is temporarily applied because third-party profile scripts may
reference unset variables. If the profile is not found, a PATH-only
fallback is used.

If Nix is not available after installation, the script exits with an
error and instructs the user to open a new terminal and re-run.

#### Upgrades

On subsequent runs, if Nix is already installed, the script runs
`sudo determinate-nixd upgrade` to update to the latest stable version.
This is the Determinate Systems upgrade path — the standard
`nix upgrade-nix` command is not available in Determinate Nix.

---

### 4. Installing SAP Privileges

SAP Privileges is installed using the **standard localized PKG**
provided by SAP.

Reasons for using the PKG instead of ZIP extraction:

- Uses Apple's Installer framework
- Creates proper system receipts
- Works well with audits and MDM tooling
- Reduces the chance of broken app bundles

#### Version enforcement

The script enforces the **exact pinned version**:

- If the installed version matches the pin: no action
- If the installed version differs: reinstall (this may be an upgrade
  **or** a downgrade — the pinned version always wins)
- If Privileges is not installed: fresh install

This is intentional and matches the "declarative baseline" philosophy.

#### Installation verification (defense in depth)

Each installation goes through multiple verification layers:

1. **SHA-256 hash** — verified via `shasum --check --status`
2. **PKG signature** — verified via `pkgutil --check-signature` against
   the expected signer string (`Developer ID Installer: SAP SE`).
   Note: if SAP rotates their certificate, the signer string must be
   updated. Note: `pkgutil` output format has been stable since macOS 10.6
   and is relied upon by MDM tooling, but is not contractually stable.
3. **Gatekeeper assessment** — `spctl -a` exit code (more stable than
   parsing output text)
4. **Code signature** — `codesign -v`
5. **Quarantine removal** — `xattr -dr com.apple.quarantine`
6. **LaunchServices registration** — ensures Spotlight/Finder recognize
   the app immediately

---

### 5. SAP Privileges Configuration (System-Wide)

The script writes configuration to:

```
/Library/Preferences/corp.sap.privileges.plist
```

These are **"unmanaged preferences"** via `defaults write`. If the Mac
is later enrolled in an MDM (Jamf, Kandji, etc.), MDM-managed
Configuration Profiles will take precedence and may override these
values. For standalone / break-glass setups this approach is appropriate.

#### Settings

- **DockToggleTimeout** — limits admin privileges to a fixed time window
- **RevokePrivilegesAtLogin** — ensures privileges do not persist across
  logins
- **RevokeAtLoginExcludedUsers** — excludes the break-glass admin account
  from auto-revocation (only managed when auto-revoke is active)
- **RequireAuthentication** — forces authentication when requesting
  privileges (may require MDM on some macOS/Privileges versions)

#### Implementation details

- Boolean values are written with explicit `if/else` blocks using
  literal `true`/`false` rather than passing variables to `defaults write
  -bool`, because macOS only officially documents `TRUE/FALSE/YES/NO/1/0`
  as valid values
- The exclusion list is checked via PlistBuddy iteration for exact string
  matching (no substring false positives)
- Preferences are flushed by restarting `cfprefsd` (`sudo killall cfprefsd`).
  This is safe because cfprefsd handles writes via XPC transactions and
  launchd restarts it immediately
- Plist permissions are set to `644` so the Privileges app can read them

---

## Configuration Defaults

The script uses the following defaults (overridable via environment
variables):

| Variable | Default | Description |
|---|---|---|
| `PRIV_TIMEOUT_MINUTES` | `20` | Privilege timeout in minutes |
| `PRIV_REVOKE_AT_LOGIN` | `true` | Auto-revoke at next login |
| `PRIV_REQUIRE_AUTH` | `true` | Require authentication |
| `PRIVILEGES_VERSION` | `2.5.0` | SAP Privileges version (pinned) |
| `PRIVILEGES_PKG_SHA256` | `a7587035…` | PKG checksum (pinned) |
| `NIX_INSTALLER_VERSION` | `0.32.3` | Nix installer version (pinned) |
| `NIX_INSTALLER_SHA256` | (must be set) | Installer binary checksum |

Boolean values accept: `true`, `false`, `1`, `0`, `yes`, `no`, `y`,
`n`, `on`, `off` — they are normalized to `"true"` / `"false"` early in
the script.

Example:

```bash
PRIV_TIMEOUT_MINUTES=30 PRIV_REQUIRE_AUTH=false ./bootstrap-admin-macos.sh
```

---

## Version Management

The script contains `# renovate:` comments that enable
[Renovate Bot](https://github.com/renovatebot/renovate) to automatically
create PRs when new releases are published. A companion GitHub Action
computes and commits the updated SHA-256 hash into the Renovate PR.

This keeps the baseline current with minimal manual effort: review the
PR, merge it, pull locally, and re-run the script.

---

## Security Model Summary

| Aspect | Decision |
|---|---|
| Daily user | Non-admin |
| Admin access | Temporary, explicit, authenticated |
| Privilege timeout | Enforced (default: 20 min) |
| Privilege persistence | Revoked at login |
| Downloads | Version-pinned + SHA-256 verified |
| PKG integrity | Additionally signature-verified |
| Curl | TLS 1.2+, retries, timeouts |
| Configuration | System-wide, auditable |
| Recovery | Guaranteed via break-glass admin |
| MDM interaction | Unmanaged preferences; MDM profiles take precedence |

---

## Idempotency and Re-Runs

The script is designed to be safely re-run:

- Nix: detected → upgraded via `sudo determinate-nixd upgrade`
- SAP Privileges: version compared → reinstalled only if mismatched
- Configuration: overwritten deterministically
- Exclusion list: checked for existing entries before adding
- Logs: old files purged automatically

This is intentional and simplifies both maintenance and recovery.

---

## Logs and Troubleshooting

Each run produces a log file:

```
~/bootstrap-admin-YYYYMMDD-HHMMSS.log
```

Log entries include ISO 8601 timestamps and structured prefixes
(`[INFO]`, `[STEP]`, `[OK]`, `[WARN]`, `[ERROR]`). Terminal output
includes colors when running interactively.

If something goes wrong:

1. Check the log file — timestamps help identify where time was spent
2. Verify `/Library/Preferences/corp.sap.privileges.plist`
3. Confirm Privileges.app exists in `/Applications`
4. If SAP Privileges has revoked your admin rights: open Privileges.app,
   grant yourself temporary admin, and re-run the script
5. If the lock file is stale: `rm -rf /tmp/bootstrap-admin.lock`

---

## After This Script

Once the admin bootstrap is complete:

1. Create a **standard (non-admin) user**
2. Log in as that user
3. Use SAP Privileges for temporary admin access
4. Run `bootstrap-user.sh`

At this point, the admin account should rarely be needed — only for
re-running this script after version bumps or for emergency access.

---

## Philosophy

This setup intentionally trades a small amount of convenience for:

- Clear security boundaries
- Predictable system state
- Easy recovery after failure
- Confidence when re-installing years later

That trade-off is deliberate.
