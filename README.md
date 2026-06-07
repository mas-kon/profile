## Profile

Автоматическая установка и настройка Linux-окружения: zsh, tmux, nvim, lazygit и другие инструменты.

Поддерживаемые дистрибутивы: Debian/Ubuntu, Rocky Linux, AlmaLinux, Fedora.

## Установка

### Интерактивный режим (выбор компонентов)

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh)
```

### Минимальная установка (только пакеты и алиасы)

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --min
```

### Полная установка (все компоненты)

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --full
```

### Просмотр без установки

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/profile.sh) --dry-run
```

## Компоненты

| # | Компонент | По умолчанию |
|---|-----------|:---:|
| 1 | sudoers NOPASSWD | — |
| 2 | Базовые пакеты (zsh, tmux, vim, git, jq, ripgrep…) | ✓ |
| 3 | Oh-My-Zsh + плагины | ✓ |
| 4 | tmux (gpakosz/.tmux) | ✓ |
| 5 | lazygit | ✓ |
| 6 | bottom (btm) | ✓ |
| 7 | lazyssh | ✓ |
| 8 | Neovim (бинарник) | ✓ |
| 9 | Neovim config (mas-kon/nvim) | ✓ |
| A | nvm + Node.js LTS | ✓ |
| B | uv (Python) | ✓ |
| C | Алиасы и PATH | ✓ |
