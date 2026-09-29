#!/bin/bash
# docker-manage.sh
# Использование:
#   ./docker-manage.sh install
#   ./docker-manage.sh check
#   ./docker-manage.sh all
#
# Коды возврата check:
#   0 — Docker установлен и доступен
#   1 — Docker не установлен
#   2 — Docker установлен, но служба не запущена/недоступна
#   3 — Docker работает, но у пользователя нет прав

set -u

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; NC=""
fi

ok()   { printf '%s✔%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$1"; }
err()  { printf '%s✘%s %s\n' "$RED" "$NC" "$1"; }

usage() {
  cat <<EOF
Использование: $0 {install|check|all}

  install — установить Docker CE из официального репозитория (Ubuntu)
  check   — проверить установку, службу и права доступа
  all     — install + check

Коды возврата check:
  0 — Docker установлен и доступен
  1 — Docker не установлен
  2 — Docker установлен, но служба не запущена/недоступна
  3 — Docker работает, но у пользователя нет прав
EOF
}

install_docker() {
  set -euo pipefail

  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
      warn "Скрипт установки рассчитан на Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}"
      warn "Продолжение может не сработать."
    fi
  fi

  $SUDO apt update
  $SUDO apt install -y ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc

  $SUDO tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  $SUDO apt update

  VERSION_STRING=$(apt-cache policy docker-ce | grep 'Candidate:' | awk '{print $2}')
  $SUDO apt install -y docker-ce=$VERSION_STRING docker-ce-cli=$VERSION_STRING containerd.io docker-buildx-plugin docker-compose-plugin

  TARGET_USER="${SUDO_USER:-$(id -un)}"
  $SUDO groupadd -f docker
  $SUDO usermod -aG docker "$TARGET_USER"

  echo "---------------------------------------------------------------"
  ok "Docker установлен."
  echo "Пользователь $TARGET_USER добавлен в группу docker."

  # Спрашиваем, выполнить ли newgrp docker сразу
  if [ -t 0 ]; then
    read -r -p "Выполнить 'newgrp docker' сейчас, чтобы применить группу в текущей сессии? [y/N]: " answer
    case "$answer" in
      [yY]|[yY][eE][sS])
        echo "Запускаю newgrp docker. После выхода из нового shell скрипт завершится."
        echo "Если вы запускали './docker-manage.sh all', проверка не выполнится автоматически —"
        echo "запустите её отдельно: ./docker-manage.sh check"
        newgrp docker
        ;;
      *)
        echo "Пропущено. Чтобы применить членство в группе, перезайдите в систему"
        echo "или выполните в текущем терминале: newgrp docker"
        ;;
    esac
  else
    echo "Скрипт запущен не в интерактивном режиме. Чтобы применить членство в группе,"
    echo "перезайдите в систему или выполните: newgrp docker"
  fi
  echo "---------------------------------------------------------------"
}

check_docker() {
  # 1. Бинарник
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker не установлен (команда 'docker' не найдена в PATH)."
    return 1
  fi

  DOCKER_BIN="$(command -v docker)"
  ok "Найден бинарник docker: $DOCKER_BIN"

  # 2. Версия клиента
  if CLIENT_VERSION="$(docker --version 2>/dev/null)"; then
    ok "Клиент: $CLIENT_VERSION"
  else
    err "Не удалось получить версию docker-клиента."
    return 1
  fi

  # 3. Доступ к демону
  if ! docker info >/dev/null 2>&1; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      warn "Служба docker запущена, но текущий пользователь не имеет к нему доступа."
      warn "Добавьте пользователя в группу 'docker' или запускайте команды через sudo:"
      warn "  sudo usermod -aG docker \"\$USER\" && newgrp docker"
      return 3
    else
      err "Docker установлен, но демон не запущен или недоступен."
      err "Попробуйте: sudo systemctl start docker"
      return 2
    fi
  fi
  ok "Служба Docker доступна."

  # 4. Версия сервера
  if SERVER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"; then
    ok "Сервер Docker: $SERVER_VERSION"
  fi

  # 5. Docker Compose
  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose (plugin): $(docker compose version --short 2>/dev/null || docker compose version)"
  elif command -v docker-compose >/dev/null 2>&1; then
    warn "Найден устаревший docker-compose v1: $(docker-compose --version)"
  else
    warn "Docker Compose не установлен."
  fi

  # 6. Buildx
  if docker buildx version >/dev/null 2>&1; then
    ok "Docker Buildx: $(docker buildx version | awk '{print $2}')"
  fi

  ok "Проверка завершена успешно."
  return 0
}

case "${1:-}" in
  install)
    install_docker
    ;;
  check)
    check_docker
    exit $?
    ;;
  all)
    install_docker
    echo
    warn "Сразу после установки текущая сессия ещё не в группе docker."
    warn "Если вы выбрали 'newgrp docker', скрипт перейдёт в новый shell и проверка не запустится."
    warn "Запустите проверку вручную: ./docker-manage.sh check"
    check_docker
    exit $?
    ;;
  *)
    usage
    exit 64
    ;;
esac