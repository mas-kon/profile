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

- [profile.sh](profile.sh) — main installation script (~1060 lines), distro-independent
- [rename_host.sh](rename_host.sh) — hostname renaming utility
- [vimrc](vimrc) — Vim configuration (downloaded to `~/.vimrc` during base package install)
- [postfix.txt](postfix.txt) — Postfix mail server configuration reference (manual setup)
- [README.md](README.md) — installation instructions + component table
- [docs/plans/](docs/plans/) — implementation plans (e.g. the plan that created `profile.sh`)

## Installation Modes

```bash
# Interactive (component selection menu) — default
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh)

# Minimal (only base packages, oh-my-zsh, aliases — no nvim/tools)
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --min

# Full (all components, no menu)
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --full

# Preview component list without installing
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --dry-run
```

Every run writes a log file to `$HOME/profile_install_<TIMESTAMP>.log`. After the menu and
`--dry-run` exit, `start_log_capture()` tees all stdout/stderr (incl. external command
warnings, e.g. npm) into it; `log()`/`log_error()` then only print to avoid duplicates.

## Architecture of profile.sh

The script follows a layered modular design, in source order:

### Global setup (top of file)
- `set -euo pipefail`
- Constants: `TIMESTAMP`, `LOG_FILE`; `WORKDIR` (per-run `mktemp -d` scratch dir, removed on EXIT)
- Architecture detection: `x86_64` / `aarch64` → `ARCH_DEB` (`amd64`/`arm64`),
  `ARCH_RPM`, `ARCH_NVIM`, `ARCH_GO` (goreleaser naming: `x86_64`/`arm64`), and
  `ARCH_TRIPLE` (rust triple prefix: `x86_64`/`aarch64`) — used for GitHub binary download URLs.

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
- `bootstrap_deps()` — installs missing `sudo`/`curl` (as root or via `su`), then makes sure
  `jq`/`git` are present (every installer depends on them); it never touches groups or sudoers
- `add_sudoers_entry()` — opt-in NOPASSWD entry (component 1): sanitizes a "."-containing
  username for the sudoers.d filename, validates with `visudo -cf`, installs with mode 0440

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
8. **install_nvim_config()** — clones `mas-kon/nvim` → `~/.config/nvim`; loads `nvm.sh` for PATH,
   then installs `tree-sitter-cli` via npm (warns and skips if npm is absent)
9. **install_nvm()** — NVM + Node.js LTS
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
  2. `detect_distro` → `show_interactive_menu`
  3. `--dry-run` → print enabled components, exit (before any system change, incl. `bootstrap_deps`)
  4. `bootstrap_deps` (needed tools only; requires sudo to work — errors out otherwise,
     never grants NOPASSWD or group membership on its own)
  5. Run enabled installers via `component_enabled`, each as `install_x || log_error "…: failed, continuing."`
  6. Order matters: aliases (C) run before nvm (A) and uv (B) so PATH is set before completions;
     nvim config (9) runs AFTER nvm (A) because it needs npm from nvm for `tree-sitter-cli`

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
