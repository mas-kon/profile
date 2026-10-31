# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Linux profile setup repository: automated installation and configuration of a personalized
development environment (zsh, tmux, Neovim, modern CLI tools) with a single `curl | bash`
command. README and user-facing docs are in Russian; log messages and comments in the
scripts are in English.

Supported distributions: Debian/Ubuntu (+ Debian-family like Linux Mint, Kali, Pop), Fedora,
RHEL/Rocky/AlmaLinux. Architectures: x86_64 and aarch64.

## Repository Structure

- [profile.sh](profile.sh) — main installation script (~930 lines), distro-independent
- [rename_host.sh](rename_host.sh) — hostname renaming utility
- [vimrc](vimrc) — Vim configuration (downloaded to `~/.vimrc` during base package install)
- [postfix.txt](postfix.txt) — Postfix mail server configuration reference (manual setup)
- [README.md](README.md) — installation instructions + component table
- [docs/plans/](docs/plans/) — implementation plans (e.g. the plan that created `profile.sh`)

## Installation Modes

```bash
# Interactive (component selection menu) — default
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh)

# Minimal (only base packages, oh-my-zsh, omz plugins, tmux, aliases)
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --min

# Full (all components, no menu)
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --full

# Preview component list without installing
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --dry-run
```

Every run writes a log file to `$HOME/profile_install_<TIMESTAMP>.log`.

## Architecture of profile.sh

The script follows a layered modular design, in source order:

### Global setup (top of file)
- `set -euo pipefail`
- Constants: `TIMESTAMP`, `LOG_FILE`
- Architecture detection: `x86_64` / `aarch64` → `ARCH_SUFFIX`, `ARCH_DEB` (`amd64`/`arm64`),
  `ARCH_RPM`, `ARCH_NVIM` — used for GitHub binary downloads and `.deb`/`.rpm` names

### Distro abstraction
- `detect_distro()` — reads `/etc/os-release`, sets `DISTRO_FAMILY` (`debian` | `fedora` | `rhel`),
  and `PKG_UPDATE` / `PKG_INSTALL` commands per family
- `pkg_name()` — maps canonical package names to distro-specific ones
  (e.g. `dns-tools` → `dnsutils` on Debian, `bind-utils` on RPM; empty return = skip on this distro)
- `install_packages()` — calls `$PKG_INSTALL`

### Utilities
- `log()` / `log_error()` — write to stdout and `LOG_FILE`
- `validate_github_api_response()` — validates GitHub API JSON responses
- `check_url_exists()` — HEAD-request a URL before downloading
- `backup_config()` — `cp -r <file> <file>.bak.<TIMESTAMP>`; backs up each target
  **at most once per run** (tracked in `_BACKED_UP` associative array)

### Bootstrap
- `bootstrap_deps()` — installs missing `sudo`/`curl` (as root or via `su`), adds the user
  to the sudo group if needed
- `add_sudoers_entry()` — writes NOPASSWD sudoers entry (component 1)

### Component installers
Each tool has its own function that returns non-zero on failure (the main flow logs the
error and continues to the next component):

1. **install_base_packages()** — enables EPEL on RPM systems; installs a canonical package
   list resolved through `pkg_name()`; groupinstall "Development Tools" on RPM; downloads
   `vimrc` from this repo to `~/.vimrc`
2. **install_lazygit()** — latest release via GitHub API, arch-dependent binary
3. **install_bottom()** — `.deb` / `.rpm` depending on `DISTRO_FAMILY`
4. **install_lazyssh()** — tarball via GitHub API
5. **install_oh_my_zsh()** — Oh-My-Zsh + plugins (zsh-syntax-highlighting, zsh-autosuggestions),
   sets zsh as login shell; backs up `.zshrc`
6. **install_tmux()** — clones gpakosz/.tmux, custom config (mouse, tmux-sessionist,
   tmux-resurrect, tmux-continuum), prefix Ctrl+a
7. **install_nvim()** — Neovim prebuilt tarball for the detected arch → `/opt/nvim`
8. **install_nvim_config()** — clones `mas-kon/nvim` → `~/.config/nvim`; installs
   `tree-sitter-cli` via npm (warns and skips if npm absent)
9. **install_nvm()** — NVM + Node.js LTS; stores the node version in `NVM_NODE_VER`
10. **install_uv()** — uv via astral.sh install script; PATH and shell completions in `.zshrc`
11. **add_aliases()** — common aliases in `.zshrc`; conditional aliases for
    bat (`batcat` on Debian, `bat` on RPM), `duf`, `lazygit`, `lazyssh`

### Interactive menu and component state
- `COMPONENT_KEYS` (`1 2 3 4 5 6 7 8 9 A B C`), `COMPONENT_NAMES`, `COMPONENT_DEFAULTS`,
  `COMPONENT_STATE` — arrays; the same components are shown in README's table
- `show_interactive_menu()` — applies mode overrides: `--min` sets
  `N Y Y N N N N N N N N Y`, `--full` sets all `Y`; default is all `Y` except sudoers (N);
  then toggle loop for interactive mode
- `component_enabled <key>` — checks the current state; used by `main()`

### CLI parsing and main flow
- `parse_args()` — `--help`, `--dry-run`, `--min`, `--full`; unknown option → error, exit 1
- `main()` order:
  1. `parse_args` → banner
  2. `detect_distro` → `bootstrap_deps` → `show_interactive_menu`
  3. `--dry-run` → print enabled components, exit
  4. sudo session: if not root and no NOPASSWD, try `sudo -v`; on failure grant sudo
     access via `su` (requires root password)
  5. Run enabled installers via `component_enabled`, each as `install_x || log_error "…: failed, continuing."`
  6. Note: aliases (C) run **before** nvm (A) and uv (B) so PATH is set before completions

## Key Conventions

- Every modification of shell configs goes through `backup_config()` first.
- GitHub version detection uses the API + `jq` (`.$tag_name`); validate responses with
  `validate_github_api_response`, check download URLs with `check_url_exists`.
- Failure of a single component must never abort the whole script: installer returns 1,
  main logs and continues.
- Interactive (`y/N`) prompts default to "No" for safety.
- Tools install to standard locations (`/usr/local/bin`, `~/.local/bin`, package managers).
- Bash arrays/associative arrays require Bash ≥ 4; the script targets Linux only, not macOS/BSD.

## Vim Configuration ([vimrc](vimrc))

- UTF-8 encoding, 4-space tabs with auto-indent, Python-oriented settings
- No backup/swap files
- Buffer navigation with Ctrl+N / Ctrl+P
- Mouse disabled by default
- Colorscheme line is commented out

## Hostname Management ([rename_host.sh](rename_host.sh))

Renames the hostname with validation (`^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$`), requires root:

```bash
sudo ./rename_host.sh <new-hostname>                  # replaces TEMPLATE placeholder
sudo ./rename_host.sh <old-hostname> <new-hostname>   # replaces old hostname
```

Updates (files missing from the list are skipped silently): `hostnamectl set-hostname`,
`/etc/hosts`, `/etc/hostname`, `/etc/mailname`, `/etc/postfix/main.cf`.

## Postfix Configuration ([postfix.txt](postfix.txt))

Reference for Gmail SMTP relay setup. Not automated — manual configuration required.

## Working with This Repository

When modifying scripts:
- Mind the distro abstraction: new packages must go through `pkg_name()` mapping,
  not hardcoded package manager calls
- Test architecture detection and package resolution on both x86_64 and aarch64,
  and on both a Debian-family and an RPM-family system (`--dry-run` is a cheap smoke test)
- Keep the error-handling pattern: check operation success, clean up on failure,
  log a descriptive error via `log_error`
- Shell config changes should use `backup_config()` and be idempotent where possible
  (grep before appending, e.g. `add_aliases()`)
