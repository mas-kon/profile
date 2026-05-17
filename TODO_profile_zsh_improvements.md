# TODO: Улучшения для profile_zsh.sh

## 🔴 Критические исправления (Priority: HIGH)

- [x] **Строка 225**: Исправить регулярное выражение в sed
  ```bash
  # Было:
  sed -i 's/plugins=(.*)$/plugins=(z git ...)/' .zshrc
  # Должно быть:
  sed -i 's/plugins=(.*)/plugins=(z git zsh-syntax-highlighting jira zsh-autosuggestions aliases poetry battery terraform aws docker docker-compose kubectl)/' .zshrc
  ```

- [x] **Строка 229**: Удалить дублирование - `zsh-syntax-highlighting` уже добавлен в плагины на строке 225

- [x] **Строки 172, 178, 199**: Добавить кавычки для имен файлов с `$(uname)_$(uname -m)`
  ```bash
  # Было:
  tar -xzf lazyssh_$(uname)_$(uname -m).tar.gz
  # Должно быть:
  tar -xzf "lazyssh_$(uname)_$(uname -m).tar.gz"
  ```

## 🟡 Идемпотентность (Priority: MEDIUM)

- [x] **install_lazygit()**: Проверять установленную версию перед переустановкой
  ```bash
  if command -v lazygit &>/dev/null; then
      CURRENT_VERSION=$(lazygit --version | grep -oP 'version=\K[^,]+')
      if [[ "$CURRENT_VERSION" == "$LAZYGIT_VERSION" ]]; then
          echo "Lazygit $CURRENT_VERSION already installed, skipping."
          return
      fi
  fi
  ```

- [x] **install_bottom()**: Проверять установленную версию перед переустановкой

- [x] **install_lazyssh()**: Проверять установленную версию перед переустановкой

- [x] **add_aliases()**: Проверять существование алиасов перед добавлением в .zshrc
  ```bash
  if ! grep -q "alias sst=" ~/.zshrc; then
      echo "alias sst='ss -nlptu'" >> ~/.zshrc
  fi
  ```

- [x] **install_tmux()**: Проверять существование настроек перед добавлением в .tmux.conf.local

- [x] **install_oh_my_zsh()**: Проверять существование плагинов перед клонированием

## 🟢 Функциональные улучшения (Priority: LOW)

### Обработка ошибок

- [ ] Заменить `exit 1` на `return 1` в функциях для продолжения выполнения

- [ ] Добавить общий обработчик ошибок с возможностью продолжения

- [ ] Логировать все ошибки в отдельный файл

### Новые инструменты

- [ ] Добавить установку `fzf` (fuzzy finder)
  ```bash
  install_fzf() {
      git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
      ~/.fzf/install --all
  }
  ```

- [ ] Добавить установку `zoxide` (умная замена cd)
  ```bash
  install_zoxide() {
      curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
      echo 'eval "$(zoxide init zsh)"' >> ~/.zshrc
  }
  ```

- [ ] Добавить установку `eza` (современная замена ls)

- [ ] Добавить установку `fd` (быстрая замена find)

- [ ] Добавить установку `delta` (улучшенный git diff)

- [ ] Добавить установку `starship` (кроссплатформенный prompt)

### Конфигурация

- [ ] Добавить профили установки (minimal, full, custom)

- [ ] Поддержка переменных окружения для кастомизации

### CLI опции

- [ ] Добавить `--help` для показа справки

- [ ] Добавить `--dry-run` для показа что будет установлено

- [ ] Добавить `--minimal` для минимальной установки

- [ ] Добавить `--full` для полной установки

- [ ] Добавить возможность установки отдельных компонентов: `./profile_zsh.sh --only lazygit,tmux`

### Интерактивность

- [ ] Заменить 3 вопроса на интерактивное меню с выбором всех компонентов

- [ ] Показывать что уже установлено перед началом

- [ ] Добавить возможность пропуска уже установленных компонентов

## 🔒 Безопасность (Priority: MEDIUM)

- [x] Добавить проверку контрольных сумм для скачиваемых файлов (реализовано для lazygit)

- [x] Валидация JSON ответов от GitHub API перед использованием (helper `validate_github_api_response()`)

- [x] Проверка URL перед скачиванием файлов (helper `check_url_exists()`)

## 🏗️ Структурные улучшения (Priority: LOW)

> **Расшифровка и приоритеты внутри раздела:**

- [ ] **Вынести список пакетов в переменные** ⭐⭐⭐ — просто, высокая польза
  - Пакеты сейчас захардкожены в `apt install`. Вынести в массивы для удобного редактирования:
  ```bash
  SYSTEM_PACKAGES=(tree mc curl wget ca-certificates)
  DEV_PACKAGES=(git build-essential jq ripgrep)
  sudo apt install -y "${SYSTEM_PACKAGES[@]}"
  ```

- [ ] **Создать функцию для бэкапа конфигов перед изменением** ⭐⭐⭐ — просто, высокая польза
  - Перед изменением `.zshrc`, `.tmux.conf.local` и т.д. сохранять копию:
  ```bash
  cp ~/.zshrc ~/.zshrc.bak.$(date +%Y%m%d_%H%M%S)
  ```
  - Сейчас только `install_tmux()` делает `mv ~/.tmux ~/.tmux.bak`, для остальных конфигов бэкапа нет.

- [ ] **Разбить `min_install()` на категории** ⭐⭐ — просто, средняя польза (читаемость)
  ```bash
  install_system_packages()  # tree, mc, curl, wget
  install_dev_tools()        # git, build-essential, jq
  install_monitoring_tools() # htop, sysstat, iotop
  ```

- [ ] **Добавить функцию для кэширования версий из GitHub API** ⭐ — средняя сложность, низкая польза
  - Сейчас каждая функция делает отдельный HTTP-запрос. При повторных запусках тратится время и квота API.

- [ ] **Добавить функцию отката изменений** ⭐ — высокая сложность, низкая польза
  - Если скрипт упал на середине — восстановить `.zshrc` из бэкапа, удалить частично установленные файлы.
  - Сложно сделать надёжно, проще запускать скрипт повторно (идемпотентность уже реализована).

## 📝 Документация (Priority: LOW)

- [ ] Добавить комментарии на английском для международного использования

- [ ] Создать README.md с описанием всех устанавливаемых компонентов

- [ ] Документировать все функции с примерами использования

- [ ] Добавить секцию FAQ

- [ ] Добавить секцию Troubleshooting

## ⚡ Производительность (Priority: LOW)

- [ ] Реализовать параллельную установку независимых компонентов

- [ ] Кэширование результатов API запросов

- [ ] Опциональная поддержка `apt-fast` вместо `apt`

- [ ] Оптимизация git clone с использованием `--depth 1` везде где возможно

## 🧪 Тестирование (Priority: LOW)

- [ ] Добавить unit тесты для функций

- [ ] Тестирование на разных дистрибутивах (Debian, Ubuntu)

- [ ] Тестирование на разных архитектурах (x86_64, aarch64)

- [ ] CI/CD pipeline для автоматического тестирования

---

**Дата создания**: 2026-01-25  
**Последнее обновление**: 2026-05-17  
**Версия скрипта**: profile_zsh.sh  
**Статус**: В разработке
