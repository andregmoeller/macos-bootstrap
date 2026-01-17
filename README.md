# macos-bootstrap

A secure, reproducible macOS setup focused on **least privilege**,
**reproducibility**, and **clarity**.

This repository contains scripts and configuration to bootstrap a fresh
macOS system using: - A **break-glass admin account** - A **standard
(non-admin) daily user** - **Temporary admin privileges** via SAP
Privileges - **Declarative system configuration** via Nix and nix-darwin

------------------------------------------------------------------------

## Goals

-   🛡️ Least-privilege by default
-   ♻️ Reproducible system after a clean macOS install
-   ⏱️ No permanent admin usage for daily work
-   📜 Auditable, documented configuration
-   🚀 Fast recovery after reinstall or hardware replacement

------------------------------------------------------------------------

## Architecture Overview

### 1. Admin (Break-Glass) Account

-   Created during initial macOS setup
-   Used **only** for:
    -   Initial system bootstrap
    -   Emergency access
-   Installs:
    -   Nix (Determinate Systems)
    -   SAP Privileges
-   Excluded from automatic privilege revocation

### 2. Standard User Account

-   Used for all daily work
-   **Not** an admin
-   Requests admin rights temporarily via SAP Privileges
-   Fully configured via nix-darwin and Home Manager

------------------------------------------------------------------------

## Repository Structure

``` text
.
└── bootstrap-admin-macos.sh   # One-time admin bootstrap
```

------------------------------------------------------------------------

## Bootstrap Flow

1.  Perform a **clean macOS installation**

2.  Create an **admin account** during setup

3.  Log in as the admin account

4.  Run:

    ``` bash
    chmod +x bootstrap-admin-macos.sh
    ./bootstrap-admin-macos.sh
    ```

------------------------------------------------------------------------

## Security Model

-   No permanent admin rights for daily users
-   Admin privileges are:
    -   Time-limited
    -   Explicitly requested
    -   Automatically revoked at next login
-   SAP Privileges configuration is:
    -   System-wide
    -   Version-pinned
    -   Hash-verified
    -   Readable by all users (required for enforcement)

------------------------------------------------------------------------

## Reproducibility

-   SAP Privileges is installed via a **pinned PKG + SHA-256
    verification**
-   Nix provides deterministic package management
-   nix-darwin ensures declarative system configuration
-   Entire setup can be recreated after a clean install by re-running
    the scripts

------------------------------------------------------------------------

## Scripts

### `bootstrap-admin-macos.sh`

Responsibilities: - Install Nix (Determinate Systems) - Install SAP
Privileges (standard localized PKG) - Verify PKG integrity via SHA-256 -
Configure SAP Privileges policies system-wide - Produce a detailed log
file

**Run once per system.**

------------------------------------------------------------------------

## Requirements

-   macOS (Apple Silicon)
-   Internet connection
-   Ability to create one admin account during setup

------------------------------------------------------------------------

## Disclaimer

This repository reflects personal preferences and security assumptions.

-   Review scripts before running them
-   Test changes on non-production machines
-   No warranty is provided
