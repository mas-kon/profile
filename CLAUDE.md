# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is a Linux profile setup repository that provides automated installation and configuration scripts for a personalized development environment. The main script ([profile_zsh.sh](profile_zsh.sh)) sets up a complete Linux development environment with zsh, tmux, vim, and various modern CLI tools.

## Repository Structure

The repository contains:
- [profile_zsh.sh](profile_zsh.sh) - Main installation script (373 lines)
- [vimrc](vimrc) - Vim configuration
- [rename_host.sh](rename_host.sh) - Hostname renaming utility
- [postfix.txt](postfix.txt) - Postfix mail server configuration reference
- [README.md](README.md) - Installation instructions

## Installation Process

The main installation is done via a single command that downloads and executes the setup script:
```bash
wget -qO- https://raw.githubusercontent.com/mas-kon/profile/main/profile_zsh.sh > /tmp/install.sh && bash /tmp/install.sh
```

## Main Script Architecture ([profile_zsh.sh](profile_zsh.sh))

The script follows a modular design with these key components:

### Architecture Detection
- Detects x86_64 or aarch64 architecture at the start
- Sets `ARCH_SUFFIX` and `ARCH_DEB` variables used throughout for downloading appropriate binaries

### Bootstrap Phase ([profile_zsh.sh](profile_zsh.sh#L14-L42))
- `bootstrap_deps()` - Ensures `sudo` and `curl` are installed on bare Debian systems
- Adds user to sudo group if needed
- Handles both root and non-root installation scenarios

### Installation Functions
Each tool has its own installation function:

1. **min_install()** ([profile_zsh.sh](profile_zsh.sh#L52-L58)) - Installs base packages via apt
   - Core utilities: tree, mc, bat, duf, zsh, tmux, vim, htop, git
   - Development tools: build-essential, python3-venv, jq, ripgrep
   - System tools: sysstat, ncdu, net-tools, dnsutils

2. **install_lazygit()** ([profile_zsh.sh](profile_zsh.sh#L60-L97)) - Latest version via GitHub API
   - Uses GitHub API to get latest release version
   - Downloads appropriate binary for detected architecture
   - Includes comprehensive error handling

3. **install_bottom()** ([profile_zsh.sh](profile_zsh.sh#L127-L157)) - Tool for change more
   - Downloads `.deb` package for the detected architecture

4. **install_lazyssh()** ([profile_zsh.sh](profile_zsh.sh#L159-L202)) - SSH connection manager
   - Uses GitHub API for version detection
   - Downloads and extracts tarball

5. **install_oh_my_zsh()** ([profile_zsh.sh](profile_zsh.sh#L204-L232)) - Zsh framework setup
   - Removes old installation if exists
   - Installs plugins: zsh-syntax-highlighting, zsh-autosuggestions
   - Configures plugins in .zshrc
   - Changes shell to zsh

6. **install_tmux()** ([profile_zsh.sh](profile_zsh.sh#L100-L125)) - Terminal multiplexer
   - Clones gpakosz/.tmux configuration
   - Adds custom configuration for mouse support, plugins (tmux-sessionist, tmux-resurrect, tmux-continuum)
   - Sets prefix to Ctrl+a

7. **install_nvm()** ([profile_zsh.sh](profile_zsh.sh#L235-L278)) - Node Version Manager (optional)
   - Installs latest NVM version
   - Installs Node.js LTS
   - Adds NVM initialization to .zshrc

8. **install_uv()** ([profile_zsh.sh](profile_zsh.sh#L280-L311)) - Python package manager (optional)
   - Installs UV via official install script
   - Adds to PATH
   - Configures shell completions

9. **add_aliases()** ([profile_zsh.sh](profile_zsh.sh#L313-L347)) - Shell aliases
   - Adds common aliases to .zshrc
   - Conditional aliases for batcat/duf if installed

### Execution Flow ([profile_zsh.sh](profile_zsh.sh#L349-L372))
1. Prompts for user choices (sudoers entry, UV, NVM)
2. Runs bootstrap and base installation
3. Installs oh-my-zsh
4. Conditionally installs UV and NVM based on user input
5. Installs remaining tools (lazygit, lazyssh, tmux, bottom)
6. Adds aliases

## Error Handling Pattern

Recent updates (per git history) added comprehensive error handling:
- Version retrieval failures are caught and exit with error code 1
- Download failures are caught and temporary files cleaned up
- Installation failures trigger cleanup before exit
- Each critical operation checks success and provides descriptive error messages

## Vim Configuration ([vimrc](vimrc))

Key settings:
- Python-optimized with 4-space tabs, auto-indent, syntax highlighting
- UTF-8 encoding
- No backup/swap files
- Buffer navigation with Ctrl+N/Ctrl+P
- Mouse disabled by default
- Commented colorscheme (enabled during installation)

## Hostname Management ([rename_host.sh](rename_host.sh))

Utility script to rename system hostname across multiple configuration files:
- Updates /etc/hosts, /etc/hostname, /etc/mailname, /etc/postfix/main.cf
- Two modes:
  - 1 argument: Replace "TEMPLATE" placeholder with new hostname
  - 2 arguments: Replace old hostname with new hostname

## Postfix Configuration ([postfix.txt](postfix.txt))

Reference for Gmail SMTP relay setup. Not automated - manual configuration required.

## Working with This Repository

When modifying scripts:
- Test architecture detection logic on both x86_64 and aarch64
- Maintain error handling pattern: check operation success, cleanup on failure, exit with descriptive error
- Version detection uses GitHub API - ensure jq/grep patterns remain compatible
- Interactive prompts (y/N) default to "No" for safety
- All tools install to standard locations (/usr/local/bin or via package managers)
