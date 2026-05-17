# План: profile.sh — дистрибутив-независимый скрипт профиля

## Context

`profile_zsh.sh` жёстко завязан на `apt`/`dpkg` (Debian/Ubuntu). Нужен новый скрипт `profile.sh`, который работает и на RPM-системах (Fedora, RHEL, Rocky, Alma). Плюс добавить установку Neovim с конфигом `mas-kon/nvim`. Старый скрипт не трогаем.

---

## Структура нового скрипта `profile.sh`

```
profile.sh
├── ГЛОБАЛЬНЫЕ НАСТРОЙКИ
│   ├── set -euo pipefail
│   ├── Определение архитектуры: ARCH_SUFFIX / ARCH_DEB / ARCH_RPM / ARCH_NVIM
│   └── Константы: LOG_FILE, TIMESTAMP
│
├── УРОВЕНЬ 1 — УТИЛИТЫ
│   ├── log() / log_error()                  # с записью в LOG_FILE
│   ├── validate_github_api_response()       # из оригинала
│   ├── check_url_exists()                   # из оригинала
│   └── backup_config()                      # НОВАЯ: cp -r file file.bak.YYYYMMDD_HHMMSS
│
├── УРОВЕНЬ 2 — АБСТРАКЦИЯ ДИСТРИБУТИВА
│   ├── detect_distro()                      # читает /etc/os-release → DISTRO_FAMILY
│   ├── pkg_name()                           # каноническое имя → имя для дистрибутива
│   └── install_packages()                   # вызывает $PKG_INSTALL
│
├── УРОВЕНЬ 3 — BOOTSTRAP
│   └── bootstrap_deps()                     # sudo+curl если отсутствуют
│
├── УРОВЕНЬ 4 — УСТАНОВЩИКИ КОМПОНЕНТОВ
│   ├── install_base_packages()              # массивы пакетов + pkg_name()
│   ├── install_oh_my_zsh()                  # оригинал + backup_config
│   ├── install_tmux()                       # оригинал + backup_config
│   ├── install_lazygit()                    # оригинал (уже архитектурно-независим)
│   ├── install_bottom()                     # .deb / .rpm / tarball в зависимости от семейства
│   ├── install_lazyssh()                    # оригинал (уже архитектурно-независим)
│   ├── install_nvim()                       # НОВАЯ: tarball с GitHub releases
│   ├── install_nvim_config()               # НОВАЯ: git clone mas-kon/nvim → ~/.config/nvim
│   ├── install_nvm()                        # оригинал + backup_config
│   ├── install_uv()                         # оригинал + backup_config
│   └── add_aliases()                        # исправлена логика bat/batcat для обоих семейств
│
├── УРОВЕНЬ 5 — ИНТЕРФЕЙС
│   ├── show_interactive_menu()              # НОВАЯ: меню с toggle вместо 3 read-вопросов
│   └── parse_args()                         # НОВАЯ: --help, --dry-run, --minimal, --full
│
└── ТОЧКА ВХОДА
    ├── parse_args "$@"
    ├── detect_distro
    ├── bootstrap_deps
    ├── show_interactive_menu
    └── выполнение выбранных компонентов по порядку
```

---

## Определение дистрибутива (`detect_distro`)

Читает `/etc/os-release` (POSIX-стандарт для всех современных дистрибутивов):

```bash
detect_distro() {
    source /etc/os-release
    # ID и ID_LIKE для покрытия производных (Pop!_OS, Rocky, Alma, Mint...)
    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop|kali) DISTRO_FAMILY="debian" ;;
        fedora)                           DISTRO_FAMILY="fedora" ;;
        rhel|centos|rocky|almalinux)      DISTRO_FAMILY="rhel" ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*) DISTRO_FAMILY="debian" ;;
                *fedora*|*rhel*) DISTRO_FAMILY="rhel" ;;
                *) echo "Unsupported distro: ${PRETTY_NAME}"; exit 1 ;;
            esac ;;
    esac

    case "$DISTRO_FAMILY" in
        debian)
            PKG_UPDATE="sudo apt-get update"
            PKG_INSTALL="sudo apt-get install -y" ;;
        fedora|rhel)
            PKG_UPDATE="sudo dnf check-update || true"  # dnf exit 100 = updates exist, not error
            PKG_INSTALL="sudo dnf install -y" ;;
    esac
}
```

---

## Маппинг имён пакетов (`pkg_name`)

Функция (не ассоциативный массив — нет зависимости от bash 4+):

| Каноническое | Debian/Ubuntu | Fedora/RHEL |
|---|---|---|
| `bat` | `batcat` | `bat` |
| `python3` | `python3-full python3-venv python3-pip` | `python3` |
| `dns-tools` | `dnsutils` | `bind-utils` |
| `dev-tools` | `build-essential` | _(groupinstall "Development Tools")_ |
| `fonts-powerline` | `fonts-powerline` | `powerline-fonts` |
| `ca-certs` | `ca-certificates apt-transport-https` | _(встроено, пропустить)_ |

`install_base_packages()` вызывает `sudo dnf groupinstall -y "Development Tools"` отдельно на RPM.

Массив канонических имён:
```bash
BASE_PACKAGES=(
    tree mc bat zsh curl wget tmux vim htop git
    chrony sysstat ncdu jq ripgrep net-tools
    dns-tools iotop gpg parted fonts-powerline
    python3 dev-tools ca-certs
)
```

---

## Установка Neovim (`install_nvim` + `install_nvim_config`)

**Бинарник — tarball с GitHub** (без AppImage, требует FUSE):

```
NVIM_VERSION ← GitHub API (neovim/neovim)
ARCH_NVIM: x86_64→"x86_64", aarch64→"arm64"  # Neovim использует arm64, не aarch64

URL: .../releases/download/${NVIM_VERSION}/nvim-linux-${ARCH_NVIM}.tar.gz
Извлечь в /opt/nvim-${NVIM_VERSION}/
Симлинк: sudo ln -sf /opt/nvim-.../bin/nvim /usr/local/bin/nvim
```

**Конфигурация:**

```bash
install_nvim_config() {
    # Если уже git-репозиторий — обновить
    if [[ -d ~/.config/nvim/.git ]]; then
        git -C ~/.config/nvim pull --ff-only
    else
        backup_config ~/.config/nvim     # если есть, но не git
        git clone --depth 1 https://github.com/mas-kon/nvim ~/.config/nvim
    fi
}
```

---

## `install_bottom` — ветвление по семейству

```
debian: .deb → dpkg -i  (как сейчас)
fedora/rhel: .rpm → rpm -i
    fallback: tarball → извлечь btm → sudo install /usr/local/bin/btm
```

---

## Исправление алиаса `bat`

```bash
if command -v batcat &>/dev/null; then BAT_BIN="batcat"
elif command -v bat &>/dev/null;    then BAT_BIN="bat"
fi
# алиасы используют $BAT_BIN — работает на обоих семействах
```

---

## Интерактивное меню (заменяет 3 `read`-вопроса)

Компоненты с флагами по умолчанию:

| # | Компонент | По умолчанию |
|---|---|---|
| 1 | sudoers NOPASSWD | N |
| 2 | base packages | Y |
| 3 | oh-my-zsh | Y |
| 4 | tmux | Y |
| 5 | lazygit | Y |
| 6 | bottom | Y |
| 7 | lazyssh | Y |
| 8 | nvim binary | Y |
| 9 | nvim config (mas-kon/nvim) | Y |
| A | nvm + Node LTS | N |
| B | uv (Python) | N |
| C | aliases | Y |

Флаги: `--minimal` включает только base+zsh+tmux+aliases. `--full` включает всё. `--dry-run` показывает без выполнения.

---

## Что берём из TODO / что откладываем

**Включаем в `profile.sh`:**
- Пакеты в массивах (обязательно для маппинга)
- `backup_config()` (3 строки, защищает `.zshrc`, `.tmux.conf.local`)
- Интерактивное меню (спека требует)
- Комментарии на английском (новый скрипт публичный)
- `set -euo pipefail`
- Лог в файл

**Откладываем:**
- Параллельная установка (сложно, перемешивается вывод)
- Кэш ответов GitHub API
- `install_fzf`, `install_zoxide`, `install_eza`, `install_delta`, `install_starship`
- `--only component,component`
- Откат изменений (идемпотентность уже решает задачу)
- Unit-тесты / CI

---

## Файлы для изменения

| Действие | Путь |
|---|---|
| Создать | `profile/profile.sh` |
| Не трогать | `profile/profile_zsh.sh` |
| Обновить (потом) | `profile/README.md` — добавить one-liner для нового скрипта |

Паттерны из оригинала переносить как есть:
- `validate_github_api_response()` — строки 15–30
- `check_url_exists()` — строки 33–39
- Логика `install_lazygit()` — строки 88–155 (эталон для других установщиков)

---

## Среда разработки

Редактирование на Windows → файл сохранять с **LF** (не CRLF), иначе bash сломается.
Добавить в репозиторий `.gitattributes`:
```
*.sh text eol=lf
```

## Тестовая матрица (Proxmox VM)

| VM | Дистрибутив | DISTRO_FAMILY | Что проверяем |
|---|---|---|---|
| vm-ubuntu | Ubuntu Server 24.04 | debian | полный флоу, алиасы batcat |
| vm-debian | Debian 13 | debian | полный флоу, install_bottom .deb |
| vm-rocky | Rocky Linux 10 | rhel | маппинг пакетов, install_bottom .rpm/fallback, bat alias |

На каждой VM:
1. `bash profile.sh --dry-run` — проверить синтаксис, вывод плана
2. `bash profile.sh --minimal` — базовая установка
3. `bash profile.sh` — полный интерактивный флоу
4. Проверить: `nvim --version`, `~/.config/nvim` существует
5. `shellcheck profile.sh` — ноль предупреждений (установить через `apt/dnf install shellcheck`)
