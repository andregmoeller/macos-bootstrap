# bootstrap-admin-macos.sh

This document explains **what** the admin bootstrap script does, **why**
each step exists, and **how** it contributes to a secure, reproducible
macOS setup.

It is intended as long-term documentation for future re-installs,
audits, or onboarding.

------------------------------------------------------------------------

## Purpose of the Admin Bootstrap

The admin bootstrap establishes a **minimal, secure foundation** for the
system.

Key principles:

-   The admin account is **not** used for daily work
-   Admin privileges are **temporary and explicit**
-   The system can be **recreated after a clean install**
-   Configuration is **auditable and documented**

This script is designed to be run **once per machine**.

------------------------------------------------------------------------

## High-Level Responsibilities

`bootstrap-admin-macos.sh` performs the following tasks:

1.  Prepare a safe execution environment
2.  Install Nix (Determinate Systems)
3.  Install SAP Privileges (standard PKG)
4.  Configure SAP Privileges system-wide
5.  Leave the system ready for a standard (non-admin) user

------------------------------------------------------------------------

## Why a Separate Admin Account?

macOS requires at least one admin account.

Instead of using that account daily, we treat it as a **break-glass
account**:

-   Used only for:
    -   Initial system setup
    -   Emergency recovery
-   Never used for development or daily work
-   Excluded from privilege auto-revocation to guarantee access

This significantly reduces the attack surface of the system.

------------------------------------------------------------------------

## Step-by-Step Breakdown

### 1. Preflight Checks

The script verifies:

-   Required system tools are present
-   macOS version and architecture
-   The current user is an admin
-   `sudo` access is available

A sudo keep-alive runs in the background to avoid repeated password
prompts.

All output is written to a timestamped log file in the admin home
directory.

#### Automatic Cleanup

The script uses a trap to ensure proper cleanup on exit:

- Stops the sudo keep-alive background process
- Removes temporary download directories
- Executes even if the script encounters errors

------------------------------------------------------------------------

### 2. Rosetta 2 (Apple Silicon Only)

On Apple Silicon systems, Rosetta 2 is installed if not already present.

This ensures compatibility with: - x86-only tools - Some prebuilt
binaries - Legacy installers

The step is skipped on Intel Macs.

------------------------------------------------------------------------

### 3. Installing Nix (Determinate Systems)

Nix is installed using the **Determinate Systems installer**, which
provides:

-   A secure, supported Nix daemon
-   An encrypted APFS volume for `/nix`
-   Proper integration with macOS (launchd, Time Machine exclusions)

After installation, the script attempts to load Nix into the current
shell. If that is not possible, the user is instructed to restart the
shell and re-run the script.

This makes the bootstrap process **idempotent and safe**.

------------------------------------------------------------------------

### 4. Installing SAP Privileges

SAP Privileges is installed using the **standard localized PKG**
provided by SAP.

Reasons for using the PKG instead of ZIP extraction:

-   Uses Apple's Installer framework
-   Creates proper system receipts
-   Works well with audits and MDM tooling
-   Reduces the chance of broken app bundles

The installation process includes:

-   Version pinning
-   SHA-256 checksum verification
-   Gatekeeper and code-signature checks
-   Optional LaunchServices refresh

This ensures both **security** and **reproducibility**.

#### Post-Installation Verification

After installing Privileges, the script:

- Removes quarantine attributes (`xattr -dr com.apple.quarantine`)
- Performs Gatekeeper assessment (`spctl -a -vv`)
- Verifies code signature (`codesign -v`)
- Registers the app with LaunchServices for Spotlight/Finder

This ensures the app is properly integrated and trusted by macOS.

------------------------------------------------------------------------

### 5. SAP Privileges Configuration (System-Wide)

The script writes configuration to:

    /Library/Preferences/corp.sap.privileges.plist

Important settings:

-   **DockToggleTimeout**\
    Limits admin privileges to a fixed time window.

-   **RevokePrivilegesAtLogin**\
    Ensures privileges do not persist across logins.

-   **RevokeAtLoginExcludedUsers**\
    Excludes the break-glass admin account from auto-revocation.

-   **RequireAuthentication**\
    Forces authentication when requesting privileges.

The script explicitly: - Flushes preferences to disk - Sets permissions
to `644` so the Privileges app can read them

This avoids subtle edge cases where settings silently do not apply.

------------------------------------------------------------------------

## Configuration Defaults

The script uses the following defaults (overridable via environment variables):

| Variable | Default | Description |
|----------|---------|-------------|
| `PRIV_TIMEOUT_MINUTES` | 20 | Privilege timeout in minutes |
| `PRIV_REVOKE_AT_LOGIN` | true | Auto-revoke at next login |
| `PRIV_REQUIRE_AUTH` | true | Require authentication |
| `PRIVILEGES_VERSION` | 2.5.0 | SAP Privileges version |
| `PRIVILEGES_PKG_SHA256` | a7587035... | PKG checksum (pinned) |

Example of overriding:
```bash
PRIV_TIMEOUT_MINUTES=30 ./bootstrap-admin-macos.sh
```

------------------------------------------------------------------------

## Security Model Summary

  Aspect                  Decision
  ----------------------- ----------------------------------
  Daily user              Non-admin
  Admin access            Temporary, explicit
  Privilege timeout       Enforced
  Privilege persistence   Revoked at login
  Configuration           System-wide, auditable
  Recovery                Guaranteed via break-glass admin

------------------------------------------------------------------------

## Idempotency & Re-Runs

The script is designed to be safely re-run:

-   Existing Nix installations are detected
-   Existing Privileges installations are reused
-   Configuration is overwritten deterministically

This is intentional and simplifies recovery.

------------------------------------------------------------------------

## Logs & Troubleshooting

Each run produces a log file:

    ~/bootstrap-admin-YYYYMMDD-HHMMSS.log

If something goes wrong:

1.  Check the log file first
2.  Verify `/Library/Preferences/corp.sap.privileges.plist`
3.  Confirm Privileges.app exists in `/Applications`

------------------------------------------------------------------------

## After This Script

Once the admin bootstrap is complete:

1.  Create a **standard (non-admin) user**
2.  Log in as that user
3.  Use SAP Privileges for temporary admin access
4.  Run `bootstrap-user.sh`

At this point, the admin account should rarely be needed again.

------------------------------------------------------------------------

## Philosophy

This setup intentionally trades a small amount of convenience for:

-   Clear security boundaries
-   Predictable system state
-   Easy recovery after failure
-   Confidence when re-installing years later

That trade-off is deliberate.
