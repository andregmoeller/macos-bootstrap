# macos-bootstrap

A secure, reproducible macOS setup focused on **least privilege**,
**reproducibility**, and **clarity**.

This repository contains scripts and configuration to bootstrap and
maintain the absolute baseline of a macOS system using:

- A **break-glass admin account**
- A **standard (non-admin) daily user**
- **Temporary admin privileges** via SAP Privileges
- **Declarative system configuration** via Nix and nix-darwin

---

## Goals

- 🛡️ Least-privilege by default
- ♻️ Reproducible system after a clean macOS install
- ⏱️ No permanent admin usage for daily work
- 📜 Auditable, documented configuration
- 🚀 Fast recovery after reinstall or hardware replacement

---

## Quick Start

```bash
# 1. Download the bootstrap script
curl -O https://raw.githubusercontent.com/andregmoeller/macos-bootstrap/refs/heads/main/bootstrap-admin-macos.sh

# 2. Review it (always!)
less bootstrap-admin-macos.sh

# 3. Run it
chmod +x bootstrap-admin-macos.sh
./bootstrap-admin-macos.sh
```

📖 For detailed documentation, see [docs/bootstrap-admin.md](docs/bootstrap-admin.md)

---

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (arm64)
- Internet connection
- Admin account (break-glass or temporarily elevated via SAP Privileges)

---

## Architecture Overview

### 1. Admin (Break-Glass) Account

- Created during initial macOS setup
- Used **only** for:
  - Initial system bootstrap
  - Ongoing baseline maintenance (re-run the script after version bumps)
  - Emergency access
- Installs and upgrades:
  - Nix (Determinate Systems)
  - SAP Privileges
- Excluded from automatic privilege revocation

### 2. Standard User Account

- Used for all daily work
- **Not** an admin
- Requests admin rights temporarily via SAP Privileges
- Fully configured via nix-darwin and Home Manager

---

## Repository Structure

```text
.
├── README.md
├── bootstrap-admin-macos.sh   # Idempotent admin bootstrap & maintenance
├── renovate.json              # Automated version bump PRs
└── docs/
    └── bootstrap-admin.md     # Detailed admin bootstrap documentation
```

---

## Bootstrap Flow

1. Perform a **clean macOS installation**
2. Create an **admin account** during setup
3. Log in as the admin account
4. Run the script (see [Quick Start](#quick-start) above)
5. Create a **standard user** and switch to it for daily work
6. **Re-run the script** whenever pinned versions are updated (via Renovate PR)

---

## `bootstrap-admin-macos.sh`

Establishes and maintains the absolute baseline. Designed to be run
repeatedly — the script is fully **idempotent**.

### What it does

- Installs **Nix** (Determinate Systems) via a pinned, SHA-256-verified installer binary
- Upgrades Nix on subsequent runs via `sudo determinate-nixd upgrade`
- Installs **SAP Privileges** via a pinned, SHA-256-verified, signature-checked PKG
- Enforces the pinned Privileges version exactly (upgrade or downgrade)
- Installs **Rosetta 2** on Apple Silicon if not already present
- Configures SAP Privileges **system-wide policies**:
  - Timeout for temporary admin privileges (default: 20 minutes)
  - Auto-revoke admin at next login
  - Require authentication for privilege requests
  - Break-glass admin excluded from auto-revoke
- Produces a **timestamped log file** with colored terminal output
- Cleans up old logs automatically (retention: 30 days)

### Security features

- All downloads are **version-pinned** with **SHA-256 verification**
- SAP Privileges PKG is additionally verified via **`pkgutil` signature check** against the expected signer
- Gatekeeper assessment and code signature verification post-install
- Curl hardened with TLS 1.2+, retries, and timeouts
- Reentrance guard prevents parallel execution
- Sudo keep-alive with automatic cleanup
- Placeholder SHA-256 hashes are detected and rejected with actionable instructions

### Configuration

Override defaults via environment variables:

```bash
PRIV_TIMEOUT_MINUTES=30 PRIV_REQUIRE_AUTH=false ./bootstrap-admin-macos.sh
```

| Variable | Default | Description |
|---|---|---|
| `PRIV_TIMEOUT_MINUTES` | `20` | Minutes before admin privileges auto-expire |
| `PRIV_REVOKE_AT_LOGIN` | `true` | Revoke admin rights at next login |
| `PRIV_REQUIRE_AUTH` | `true` | Require authentication to request privileges |

### Version management

The script contains `# renovate:` comments for automated version bumps
via [Renovate Bot](https://github.com/renovatebot/renovate). When a new
release is published on GitHub, Renovate creates a PR that updates the
pinned version. A companion GitHub Action computes and commits the
updated SHA-256 hash.

---

## Security Model

- No permanent admin rights for daily users
- Admin privileges are:
  - Time-limited
  - Explicitly requested
  - Require authentication
  - Automatically revoked at next login
- SAP Privileges configuration is:
  - System-wide (via `/Library/Preferences`)
  - Version-pinned and hash-verified
  - PKG-signature-verified
  - Readable by all users (required for enforcement)
- Note: These are "unmanaged preferences". If the Mac is later enrolled
  in an MDM, Configuration Profiles will take precedence.

---

## Reproducibility

- SAP Privileges is installed via a **pinned PKG + SHA-256 + signature verification**
- Nix installer binary is **pinned + SHA-256 verified**
- Nix provides deterministic package management
- nix-darwin ensures declarative system configuration
- Entire setup can be recreated after a clean install by re-running the script

---

## Documentation

Comprehensive technical documentation:

- **[docs/bootstrap-admin.md](docs/bootstrap-admin.md)** — Complete guide to the admin bootstrap process
  - What each step does and why
  - Security model and design decisions
  - Configuration defaults and customization
  - Troubleshooting and logs

---

## Disclaimer

This repository reflects personal preferences and security assumptions.

- Review scripts before running them
- Test changes on non-production machines
- No warranty is provided
