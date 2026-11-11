#!/usr/bin/env bash

set +x
set -Eeuo pipefail

# Не допускаем вывода пароля при запуске bash -x.
trap 'unset AMNEZIA_PASSWORD AMNEZIA_PASSWORD_CONFIRM PASSWORD' EXIT

trap 'echo ""; echo "❌ Ошибка на строке $LINENO. Установка остановлена."' ERR

# ============================================================
# Initial Server Setup
# Debian / Ubuntu
#
# Настраивает:
#   - hostname
#   - swap (опционально)
#   - mc (опционально)
#   - UFW (опционально)
#   - Docker Engine + Docker Compose Plugin (опционально)
#   - AmneziaWG Easy (опционально, если выбран Docker)
# ============================================================


# ------------------------------------------------------------
# Проверка root
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "❌ Скрипт необходимо запускать от root:"
    echo
    echo "sudo bash $0"
    exit 1
fi


# ------------------------------------------------------------
# Проверка ОС
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    echo "❌ Не удалось определить операционную систему."
    exit 1
fi

source /etc/os-release

case "${ID:-}" in
    debian|ubuntu)
        ;;
    *)
        echo "❌ Поддерживаются только Debian и Ubuntu."
        echo "Обнаружено: ${PRETTY_NAME:-unknown}"
        exit 1
        ;;
esac


# ------------------------------------------------------------
# Вспомогательные функции
# ------------------------------------------------------------

ask_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    while true; do

        if [[ "$default" == "Y" ]]; then
            read -rp "$prompt [Y/n]: " answer || exit 1
            answer="${answer:-Y}"
        else
            read -rp "$prompt [y/N]: " answer || exit 1
            answer="${answer:-N}"
        fi

        case "$answer" in
            [Yy])
                return 0
                ;;
            [Nn])
                return 1
                ;;
            *)
                echo "Введите Y или N."
                ;;
        esac

    done
}


yes_no_text() {
    if [[ "$1" == "true" ]]; then
        echo "YES"
    else
        echo "NO"
    fi
}



# Проверяем каждый октет, а не только форму адреса.
valid_ipv4() {
    local address="$1" octet
    local -a octets
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

ask_amnezia_subnet() {
    local address first second third last
    while true; do
        read -rp "Подсеть AmneziaWG [10.8.0.0/24]: " AMNEZIA_SUBNET || exit 1
        AMNEZIA_SUBNET="${AMNEZIA_SUBNET:-10.8.0.0/24}"
        address="${AMNEZIA_SUBNET%/24}"
        if [[ "$AMNEZIA_SUBNET" != */24 ]] || ! valid_ipv4 "$address"; then
            echo "Укажите подсеть с маской /24, например 10.9.0.0/24."
            continue
        fi
        IFS=. read -r first second third last <<< "$address"
        first=$((10#$first))
        second=$((10#$second))
        third=$((10#$third))
        last=$((10#$last))
        if (( last != 0 )); then
            echo "Нужен адрес сети с окончанием .0/24, а не адрес клиента."
            continue
        fi
        if ! (( first == 10 || (first == 172 && second >= 16 && second <= 31) ||
                (first == 192 && second == 168) )); then
            echo "Выберите частную сеть: 10.x.x.0/24, 172.16–31.x.0/24 или 192.168.x.0/24."
            continue
        fi
        AMNEZIA_SUBNET="$first.$second.$third.0/24"
        AMNEZIA_ADDRESS="$first.$second.$third.x"
        echo "Сервер VPN: $first.$second.$third.1; первый клиент: $first.$second.$third.2/32."
        break
    done
}

# Успех означает: контейнер работает, health успешен (если есть),
# и локальная веб-панель отвечает. Это не проверка VPN с внешнего клиента.
wait_for_amnezia() {
    local deadline=$((SECONDS + 120))
    local state health http_code
    while (( SECONDS < deadline )); do
        state="$(docker inspect --format '{{.State.Status}}' amnezia-wg-easy)" || return 1
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' amnezia-wg-easy)" || return 1
        case "$state" in
            exited|dead|removing)
                echo "Контейнер остановлен: $state."
                return 1
                ;;
        esac
        if [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
            http_code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' \
                --connect-timeout 2 --max-time 3 http://127.0.0.1:51821/ || true)"
            if [[ "$http_code" =~ ^[23][0-9]{2}$ ]]; then
                echo "Status: $state; health: $health; HTTP: $http_code."
                return 0
            fi
        fi
        sleep 2
    done
    echo "За 120 секунд готовность AmneziaWG Easy не подтверждена."
    echo "Последнее состояние: status=${state:-unknown}, health=${health:-unknown}."
    return 1
}

# ------------------------------------------------------------
# Embedded SSH hardening module (no second download required)
# ------------------------------------------------------------
install_embedded_ssh_hardening() {
    install -d -m 755 /usr/local/sbin
    cat > /usr/local/sbin/initial-ssh-hardening <<'INITIAL_SSH_HARDENING_EMBEDDED_EOF'
set -Eeuo pipefail
umask 077

# SSH hardening in two stages, with a systemd automatic rollback.
STATE=/var/lib/initial-ssh-hardening
CONFIG=/etc/ssh/sshd_config.d/00-00-initial-ssh-hardening.conf
SELF=/usr/local/sbin/initial-ssh-hardening
TIMER=initial-ssh-hardening-rollback.timer

fail() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }
prompt() {
  local answer
  read -r -p "$1 [$2]: " answer </dev/tty || fail "Нужен терминал."
  printf '%s' "$answer"
  if [[ -z "$answer" ]]; then printf '%s' "$2"; fi
}
confirm_question() {
  local reply
  reply="$(prompt "$1 (y/n)" "$2")"
  [[ "$reply" =~ ^[Yy]$ ]]
}
load() {
  [[ -f "$STATE/config" && ! -L "$STATE/config" ]] || fail "Сначала запусти --prepare."
  source "$STATE/config"
}
save() {
  mkdir -p -m 700 "$STATE"
  local tmp
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")"
  printf 'USERNAME=%q\nNEW_PORT=%q\nOLD_PORT=%q\nOLD_SOCKET=%q\nOLD_SERVICE=%q\nPHASE=%q\n' \
    "$USERNAME" "$NEW_PORT" "$OLD_PORT" "$OLD_SOCKET" "$OLD_SERVICE" "$PHASE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE/config"
}
authorized_keys() { echo "/home/$USERNAME/.ssh/authorized_keys"; }
verify_keys() {
  local path
  path="$(authorized_keys)"
  [[ -s "$path" ]] || fail "Вставь публичный ключ в $path перед --finalize."
  ssh-keygen -lf "$path" >/dev/null || fail "Не удалось распознать публичный ключ."
  [[ "$(stat -c %a "/home/$USERNAME/.ssh")" == 700 ]] || fail "Права .ssh должны быть 700."
  [[ "$(stat -c %a "$path")" == 600 ]] || fail "Права authorized_keys должны быть 600."
}
verify_config() {
  sshd -t || return 1
  local user_config root_config
  user_config="$(sshd -T -C "user=$USERNAME,host=localhost,addr=127.0.0.1")"
  root_config="$(sshd -T -C 'user=root,host=localhost,addr=127.0.0.1')"
  grep -qx "port $NEW_PORT" <<< "$user_config" &&
    grep -qx 'permitrootlogin no' <<< "$root_config" &&
    grep -qx 'passwordauthentication no' <<< "$user_config" &&
    grep -qx 'kbdinteractiveauthentication no' <<< "$user_config" &&
    grep -qx 'pubkeyauthentication yes' <<< "$user_config" &&
    grep -qx 'authenticationmethods publickey' <<< "$user_config"
}
listening() { ss -H -ltn "( sport = :$NEW_PORT )" | grep -q LISTEN; }
rollback() {
  load
  [[ "$PHASE" == pending ]] || { say "Откат не требуется: $PHASE"; return; }
  say "Автоматический/ручной откат SSH."
  rm -f "$CONFIG"
  sshd -t || fail "Проверка восстановленной конфигурации не пройдена."
  if [[ "$OLD_SOCKET" == enabled || "$OLD_SOCKET" == active ]]; then
    systemctl disable ssh.service >/dev/null 2>&1 || true
    systemctl enable --now ssh.socket
    systemctl restart ssh.socket
    systemctl restart ssh.service
  else
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl restart ssh.service
    if [[ "$OLD_SERVICE" == enabled ]]; then
      systemctl enable ssh.service >/dev/null
    else
      systemctl disable ssh.service >/dev/null 2>&1 || true
    fi
  fi
  PHASE=prepared
  save
  say "SSH восстановлен, прежний порт: $OLD_PORT."
}
prepare() {
  [[ -f /etc/os-release ]] || fail "Нет /etc/os-release."
  source /etc/os-release
  [[ "$ID" == debian || "$ID" == ubuntu ]] || fail "Поддерживаются Debian и Ubuntu."
  [[ ! -e "$STATE/config" && ! -e "$CONFIG" ]] || fail "Настройка уже существует; смотри --status."
  [[ -t 0 ]] || fail "Запускать в терминале."
  say "Подготовка. Текущие SSH-настройки пока не меняются."
  while true; do
    read -r -p 'Имя нового пользователя (обязательно): ' USERNAME </dev/tty || fail "Нужен терминал."
    [[ -n "$USERNAME" ]] || { echo "Имя пользователя не может быть пустым."; continue; }
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ && "$USERNAME" != root ]] || { echo "Недопустимое имя пользователя."; continue; }
    if id "$USERNAME" >/dev/null 2>&1; then
      echo "Пользователь $USERNAME уже существует."
      confirm_question "Использовать существующего пользователя и изменить его sudo/SSH настройки?" n || continue
    fi
    break
  done
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ && "$USERNAME" != root ]] || fail "Некорректное имя."
  OLD_PORT="$(sshd -T | awk '$1=="port" && !found {print $2; found=1}')"
  OLD_PORT="$(printf '%s' "$OLD_PORT" | tr -d '\n')"
  if [[ -n "${SSH_HARDENING_PORT:-}" ]]; then
    NEW_PORT="$SSH_HARDENING_PORT"
    say "Использую SSH-порт $NEW_PORT, выбранный в основном установщике."
  else
    NEW_PORT="$(prompt 'SSH-порт' "$OLD_PORT")"
  fi
  [[ "$NEW_PORT" =~ ^[0-9]{1,5}$ ]] || fail "Неправильный порт."
  (( 10#$NEW_PORT >= 1 && 10#$NEW_PORT <= 65535 )) || fail "Порт вне диапазона."
  NEW_PORT="$((10#$NEW_PORT))"
  OLD_SOCKET=disabled
  OLD_SERVICE=disabled
  systemctl is-enabled --quiet ssh.socket && OLD_SOCKET=enabled
  if systemctl is-active --quiet ssh.socket; then OLD_SOCKET=active; fi
  systemctl is-enabled --quiet ssh.service && OLD_SERVICE=enabled
  # Avoid racing unattended-upgrades after the main apt upgrade.
  local -a missing_packages=()
  dpkg-query -W -f='${Status}' sudo 2>/dev/null | grep -qx 'install ok installed' || missing_packages+=(sudo)
  dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -qx 'install ok installed' || missing_packages+=(openssh-server)
  if (( ${#missing_packages[@]} > 0 )); then
    say "Установка отсутствующих пакетов SSH; ожидание APT/dpkg до 300 секунд."
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y "${missing_packages[@]}" ||
      fail "Не удалось установить зависимости SSH. Текущий SSH не изменён."
  else
    say "sudo и openssh-server уже установлены; повторный APT не нужен."
  fi
  if ! id "$USERNAME" >/dev/null 2>&1; then useradd -m -s /bin/bash "$USERNAME"; fi
  [[ "$(id -u "$USERNAME")" != 0 ]] || fail "UID 0 запрещён."
  [[ -d "/home/$USERNAME" ]] || fail "Нет каталога /home/$USERNAME."
  if confirm_question "sudo без пароля?" y; then
    printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$USERNAME" > "/etc/sudoers.d/90-initial-$USERNAME"
  else
    printf '%s ALL=(ALL:ALL) ALL\n' "$USERNAME" > "/etc/sudoers.d/90-initial-$USERNAME"
    passwd "$USERNAME"
  fi
  chmod 440 "/etc/sudoers.d/90-initial-$USERNAME"
  visudo -cf "/etc/sudoers.d/90-initial-$USERNAME"
  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.ssh"
  touch "$(authorized_keys)"
  chown "$USERNAME:$USERNAME" "$(authorized_keys)"
  chmod 600 "$(authorized_keys)"
  if confirm_question "Вставить публичный ключ сейчас?" n; then
    local key
    read -r -p 'Вставь публичный SSH-ключ одной строкой: ' key </dev/tty || fail "Не прочитан ключ."
    [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^[:space:]]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] || fail "Некорректный формат ключа."
    printf '%s\n' "$key" >> "$(authorized_keys)"
    chown "$USERNAME:$USERNAME" "$(authorized_keys)"
    verify_keys
  fi
  PHASE=prepared
  save
  # The full installer has already written this helper to $SELF.
  # Copy only when running the helper from a different source path.
  if [[ "$(readlink -f "$0")" != "$(readlink -f "$SELF")" ]]; then
    install -m 755 "$0" "$SELF"
  fi
  say "Готово. Текущий SSH-доступ сохранён."
  printf 'Файл ключей: %s\nПосле добавления ключа: %s --finalize\n' "$(authorized_keys)" "$SELF"
}
finalize() {
  load
  [[ "$PHASE" == prepared ]] || fail "Неверное состояние: $PHASE."
  verify_keys
  [[ ! -e "$CONFIG" ]] || fail "Управляемый SSH-конфиг уже существует."
  [[ -x "$SELF" ]] || fail "Не найден установленный скрипт $SELF."
  confirm_question "Включить запрет root/паролей и SSH-порт $NEW_PORT с автооткатом через 5 минут?" n || exit 0
  PHASE=pending
  save
  # Arm rollback before any changes which can affect SSH access.
  if ! systemd-run --quiet --unit=initial-ssh-hardening-rollback --on-active=5min "$SELF" --rollback; then
    PHASE=prepared; save
    fail "Не удалось запланировать откат. SSH не менялся."
  fi
  cat > "$CONFIG" <<EOF
# Managed by initial-ssh-hardening.
Port $NEW_PORT
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
EOF
  chmod 644 "$CONFIG"
  if ! verify_config; then rollback; fail "Проверка sshd -T не пройдена."; fi
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$OLD_PORT/tcp"
    ufw allow "$NEW_PORT/tcp"
  fi
  # Ubuntu ssh.socket may otherwise keep listening on port 22.
  if ! systemctl disable --now ssh.socket; then rollback; fail "Ошибка ssh.socket."; fi
  systemctl enable ssh.service
  if ! systemctl restart ssh.service; then rollback; fail "Ошибка запуска SSH."; fi
  if ! listening; then rollback; fail "Новый порт не прослушивается."; fi
  say "SSH настроен. В течение 5 минут открой НОВУЮ SSH-сессию:"
  printf '  ssh -p %s %s@SERVER_IP\n' "$NEW_PORT" "$USERNAME"
  printf 'И в новой сессии выполни:\n  sudo %s --confirm\n' "$SELF"
  say "Без подтверждения произойдёт автоматический откат."
}
accept() {
  load
  [[ "$PHASE" == pending ]] || fail "Нет ожидающего подтверждения."
  [[ "${SUDO_USER:-}" == "$USERNAME" ]] || fail "Подтверждай только через sudo от пользователя $USERNAME."
  # sudo may clear SSH_CONNECTION; validate the SSH parent session via
  # loginctl/sshd process ancestry rather than trusting inherited environment.
  local pid ppid cmd found=false
  pid="${SUDO_PID:-$PPID}"
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; do
    cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    if [[ "$cmd" == sshd:* || "$cmd" == *"sshd-session"* ]]; then
      found=true
      break
    fi
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ "$ppid" =~ ^[0-9]+$ && "$ppid" != "$pid" ]] || break
    pid="$ppid"
  done
  [[ "$found" == true ]] || fail "Подтверждение доступно только из SSH-сессии."
  # sudo commonly removes SSH_CONNECTION; process ancestry confirms that
  # this command originates from an sshd session, while listener and policy
  # checks below verify the configured port and restrictions.
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local client_ip client_port server_ip server_port
    read -r client_ip client_port server_ip server_port <<< "$SSH_CONNECTION"
    [[ "$server_port" == "$NEW_PORT" ]] || fail "Текущий SSH-порт не совпадает с $NEW_PORT."
  fi
  # Check the active listener and effective sshd policy before confirming.
  verify_config && listening || fail "Проверка SSH не пройдена."
  systemctl stop "$TIMER"
  PHASE=confirmed
  save
  say "Подтверждено. Откат отменён. root и парольный SSH-вход запрещены."
}
status() {
  if [[ ! -f "$STATE/config" ]]; then say "Скрипт не запускался."; return; fi
  load
  printf 'User: %s | Port: %s | Previous: %s | Phase: %s\n' "$USERNAME" "$NEW_PORT" "$OLD_PORT" "$PHASE"
  sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|authenticationmethods) '
}
(( EUID == 0 )) || fail "Запусти под root / через sudo."
case "${1:---prepare}" in
  --prepare|'') prepare ;;
  --finalize) finalize ;;
  --confirm) accept ;;
  --rollback) rollback ;;
  --status) status ;;
  *) fail "Использование: $0 [--prepare|--finalize|--confirm|--rollback|--status]" ;;
esac

INITIAL_SSH_HARDENING_EMBEDDED_EOF
    chmod 755 /usr/local/sbin/initial-ssh-hardening
}

# ============================================================
# СБОР НАСТРОЕК
# ============================================================

if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear || true
fi

echo "============================================================"
echo " Initial Server Setup"
echo " ${PRETTY_NAME}"
echo "============================================================"
echo


# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

while true; do

    read -rp "Имя сервера (обязательно): " NEW_HOSTNAME

    if [[ -z "$NEW_HOSTNAME" ]]; then
        echo "❌ Имя сервера не может быть пустым."
        continue
    fi

    if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]] &&
       [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]$ ]]; then

        echo "❌ Некорректный hostname."
        echo "Допустимы: буквы, цифры, дефис и точка."
        continue
    fi

    break

done


# ------------------------------------------------------------
# SSH hardening (optional, two-stage)
# ------------------------------------------------------------

echo
if ask_yes_no "Настроить SSH (пользователь, ключи, запрет root/паролей)?" "N"; then
    SETUP_SSH=true
else
    SETUP_SSH=false
fi


# ------------------------------------------------------------
# Swap
# ------------------------------------------------------------

while true; do

    echo
    read -rp "Размер SWAP в GB (Enter = не использовать): " SWAP_SIZE_GB

    if [[ -z "$SWAP_SIZE_GB" ]]; then
        USE_SWAP=false
        break
    fi

    if [[ "$SWAP_SIZE_GB" =~ ^[1-9][0-9]*$ ]]; then
        USE_SWAP=true
        break
    fi

    echo "❌ Укажите целое число больше 0 или нажмите Enter."

done


# ------------------------------------------------------------
# MC
# ------------------------------------------------------------

echo

if ask_yes_no "Установить Midnight Commander (mc)?" "Y"; then
    INSTALL_MC=true
else
    INSTALL_MC=false
fi


# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

echo

if ask_yes_no "Установить и настроить UFW?" "Y"; then

    INSTALL_UFW=true

    echo

    if ask_yes_no "Открыть HTTP 80/tcp?" "N"; then
        ALLOW_HTTP=true
    else
        ALLOW_HTTP=false
    fi

    if ask_yes_no "Открыть HTTPS 443/tcp?" "N"; then
        ALLOW_HTTPS=true
    else
        ALLOW_HTTPS=false
    fi

else

    INSTALL_UFW=false
    SSH_PORT="-"
    ALLOW_HTTP=false
    ALLOW_HTTPS=false

fi


# SSH port is selected once for both UFW and SSH hardening.
# If SSH hardening is skipped, the port is only a firewall rule.
if [[ "$INSTALL_UFW" == "true" || "$SETUP_SSH" == "true" ]]; then
    CURRENT_SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" && !found {print $2; found=1}')"
    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
    while true; do
        read -rp "SSH порт [${CURRENT_SSH_PORT}]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-$CURRENT_SSH_PORT}"
        if [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] &&
           (( 10#$SSH_PORT >= 1 && 10#$SSH_PORT <= 65535 )); then
            SSH_PORT=$((10#$SSH_PORT))
            break
        fi
        echo "❌ Порт должен быть числом от 1 до 65535."
    done
else
    SSH_PORT="-"
fi

# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------

echo

if ask_yes_no "Установить Docker Engine + Docker Compose Plugin?" "Y"; then

    INSTALL_DOCKER=true

    echo

    if ask_yes_no "Установить AmneziaWG Easy?" "Y"; then

        INSTALL_AMNEZIA=true

        echo
        echo "Настройка AmneziaWG Easy"
        echo

        ask_amnezia_subnet
        echo

        while true; do

            read -rsp "Пароль для админки AmneziaWG Easy: " AMNEZIA_PASSWORD
            echo

            if [[ -z "$AMNEZIA_PASSWORD" ]]; then
                echo "❌ Пароль не может быть пустым."
                continue
            fi

            read -rsp "Повторите пароль: " AMNEZIA_PASSWORD_CONFIRM
            echo

            if [[ "$AMNEZIA_PASSWORD" != "$AMNEZIA_PASSWORD_CONFIRM" ]]; then
                echo "❌ Пароли не совпадают."
                echo
                continue
            fi

            break

        done

        unset AMNEZIA_PASSWORD_CONFIRM

    else

        INSTALL_AMNEZIA=false
        AMNEZIA_PASSWORD=""

    fi

else

    INSTALL_DOCKER=false
    INSTALL_AMNEZIA=false
    AMNEZIA_PASSWORD=""

fi


# ============================================================
# СВОДКА
# ============================================================

echo
echo "============================================================"
echo " НАСТРОЙКИ"
echo "============================================================"
echo

echo "ОС:        ${PRETTY_NAME}"
echo "Hostname:  ${NEW_HOSTNAME}"

if [[ "$USE_SWAP" == "true" ]]; then
    echo "Swap:      ${SWAP_SIZE_GB} GB"
else
    echo "Swap:      NO"
fi

echo
echo "SSH setup: $(yes_no_text "$SETUP_SSH")"
echo "MC:        $(yes_no_text "$INSTALL_MC")"
echo "UFW:       $(yes_no_text "$INSTALL_UFW")"

if [[ "$INSTALL_UFW" == "true" ]]; then
    echo "SSH:       ${SSH_PORT}/tcp"
    echo "HTTP 80:   $(yes_no_text "$ALLOW_HTTP")"
    echo "HTTPS 443: $(yes_no_text "$ALLOW_HTTPS")"
fi

echo "Docker:    $(yes_no_text "$INSTALL_DOCKER")"

if [[ "$INSTALL_DOCKER" == "true" ]]; then
    echo "AmneziaWG: $(yes_no_text "$INSTALL_AMNEZIA")"
fi

if [[ "$INSTALL_AMNEZIA" == "true" ]]; then
    echo "WG UDP:    51820"
    echo "WG Admin:  127.0.0.1:51821"
    echo "WG DNS:    8.8.8.8, 8.8.4.4"
    echo "WG сеть:   $AMNEZIA_SUBNET"
fi

echo
echo "============================================================"
echo

if ! ask_yes_no "Продолжить установку?" "Y"; then
    echo
    echo "Установка отменена."
    exit 0
fi


# ============================================================
# НАЧАЛО УСТАНОВКИ
# ============================================================

echo
echo "============================================================"
echo " НАЧАЛО УСТАНОВКИ"
echo "============================================================"


# ------------------------------------------------------------
# Обновление системы
# ------------------------------------------------------------

echo
echo "[1] Обновление системы..."

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y


# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

echo
echo "[2] Настройка hostname..."

hostnamectl set-hostname "$NEW_HOSTNAME"

if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then

    sed -i \
        "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 ${NEW_HOSTNAME}/" \
        /etc/hosts

else

    echo "127.0.1.1 ${NEW_HOSTNAME}" >> /etc/hosts

fi

echo "Hostname установлен: $(hostname)"


# ------------------------------------------------------------
# Swap
# ------------------------------------------------------------

echo
echo "[3] Настройка SWAP..."

if [[ "$USE_SWAP" == "true" ]]; then

    SWAPFILE="/swapfile"

    if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then

        echo "Swap ${SWAPFILE} уже активен."
        echo "Создание пропущено."

    elif [[ -f "$SWAPFILE" ]]; then

        echo "Файл ${SWAPFILE} уже существует."

        chmod 600 "$SWAPFILE"

        swapon "$SWAPFILE"

        if ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
            echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
        fi

    else

        echo "Создание SWAP ${SWAP_SIZE_GB} GB..."

        if ! fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE"; then

            echo "fallocate недоступен. Используется dd..."

            dd if=/dev/zero \
               of="$SWAPFILE" \
               bs=1M \
               count=$((SWAP_SIZE_GB * 1024)) \
               status=progress

        fi

        chmod 600 "$SWAPFILE"

        mkswap "$SWAPFILE"

        swapon "$SWAPFILE"

        if ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
            echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
        fi

    fi


    cat > /etc/sysctl.d/99-server-swap.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

    sysctl -p /etc/sysctl.d/99-server-swap.conf >/dev/null

    echo
    echo "Swap:"
    swapon --show

else

    echo "Swap не выбран. Пропускаем."

fi


# ------------------------------------------------------------
# MC
# ------------------------------------------------------------

echo
echo "[4] Midnight Commander..."

if [[ "$INSTALL_MC" == "true" ]]; then

    if command -v mc >/dev/null 2>&1; then
        echo "mc уже установлен."
    else
        apt-get install -y mc
    fi

else

    echo "Установка mc пропущена."

fi


# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

echo
echo "[5] UFW..."

if [[ "$INSTALL_UFW" == "true" ]]; then

    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y ufw
    else
        echo "UFW уже установлен."
    fi

    echo
    echo "Настройка firewall..."

    # Сначала разрешаем SSH, только потом включаем firewall.

    # Keep the actual current SSH listener accessible even if the requested
    # firewall port differs from the sshd configuration.
    CURRENT_SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" && !found {print $2; found=1}')"
    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
    ufw allow "${CURRENT_SSH_PORT}/tcp"
    ufw allow "${SSH_PORT}/tcp"
    if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
        echo "Внимание: порт ${SSH_PORT} открыт в UFW, но SSH пока слушает ${CURRENT_SSH_PORT}."
        echo "Для смены порта используй отдельный ssh-hardening.sh."
    fi

    if [[ "$ALLOW_HTTP" == "true" ]]; then
        ufw allow 80/tcp
    fi

    if [[ "$ALLOW_HTTPS" == "true" ]]; then
        ufw allow 443/tcp
    fi

    # Если устанавливается AmneziaWG Easy,
    # автоматически открываем WireGuard UDP-порт.
    #
    # 51821 наружу НЕ открываем:
    # Web UI будет привязан только к 127.0.0.1.

    if [[ "$INSTALL_AMNEZIA" == "true" ]]; then
        ufw allow 51820/udp
    fi

    ufw default deny incoming
    ufw default allow outgoing

    ufw --force enable

    echo
    ufw status verbose

else

    echo "Установка UFW пропущена."

fi


# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------

echo
echo "[6] Docker..."

if [[ "$INSTALL_DOCKER" == "true" ]]; then

    if command -v docker >/dev/null 2>&1; then

        echo "Docker уже установлен:"
        docker --version

    else

        echo "Установка зависимостей Docker..."

        apt-get install -y \
            ca-certificates \
            curl


        echo "Создание директории keyrings..."

        install -m 0755 -d /etc/apt/keyrings


        echo "Установка Docker GPG key..."

        curl -fsSL \
            "https://download.docker.com/linux/${ID}/gpg" \
            -o /etc/apt/keyrings/docker.asc

        chmod a+r /etc/apt/keyrings/docker.asc


        echo "Добавление Docker repository..."

        ARCH="$(dpkg --print-architecture)"

        echo \
            "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list


        echo "Обновление APT..."

        apt-get update


        echo "Установка Docker..."

        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

    fi


    systemctl enable --now docker
    docker info >/dev/null


    echo
    echo "Docker:"
    docker --version

    echo
    echo "Docker Compose:"
    docker compose version

else

    echo "Установка Docker пропущена."

fi


# ------------------------------------------------------------
# AmneziaWG Easy
# ------------------------------------------------------------

echo
echo "[7] AmneziaWG Easy..."

AMNEZIA_RESULT="не выбрана"
FINAL_EXIT_CODE=0

if [[ "$INSTALL_AMNEZIA" == "true" ]]; then

    # curl нужен для определения внешнего IP.
    # При стандартной установке Docker он уже установлен.
    # Если Docker существовал заранее, curl может отсутствовать.

    if ! command -v curl >/dev/null 2>&1; then
        echo "Установка curl для определения внешнего IP..."
        apt-get install -y curl
    fi


    # --------------------------------------------------------
    # Проверка TUN
    # --------------------------------------------------------

    if [[ ! -c /dev/net/tun ]]; then

        echo "❌ /dev/net/tun отсутствует."
        echo "AmneziaWG Easy не может быть запущен без TUN."
        exit 1

    fi


    # --------------------------------------------------------
    # Определение внешнего IPv4
    # --------------------------------------------------------

    echo "Определение внешнего IPv4..."

    PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"


    # Проверяем, что получили IPv4.

    if ! valid_ipv4 "$PUBLIC_IP"; then

        echo "❌ Не удалось автоматически определить внешний IPv4."
        echo
        echo "Получено: ${PUBLIC_IP:-пустой ответ}"
        echo
        echo "Установка AmneziaWG Easy остановлена."
        exit 1

    fi


    echo "Внешний IPv4: ${PUBLIC_IP}"


    # --------------------------------------------------------
    # Директория конфигурации
    # --------------------------------------------------------

    echo "Создание /srv/amnezia-wg..."

    mkdir -p /srv/amnezia-wg


    # --------------------------------------------------------
    # Проверка существующего контейнера
    # --------------------------------------------------------

    if docker ps -a \
        --format '{{.Names}}' \
        | grep -qx 'amnezia-wg-easy'; then

        echo
        echo "❌ Контейнер amnezia-wg-easy уже существует."
        echo
        echo "Автоматически удалять существующий контейнер не будем."
        echo "AmneziaWG Easy пропущен."
        AMNEZIA_RESULT="контейнер уже существует; настройки и пароль не изменены"

    else

        if [[ -e /srv/amnezia-wg/wg0.json || -e /srv/amnezia-wg/wg0.conf ]]; then
            echo "В /srv/amnezia-wg уже есть конфигурация AmneziaWG."
            echo "Выбранная подсеть $AMNEZIA_SUBNET не применена."
            echo "Остановлено: перенос существующей сети и клиентов требует отдельной настройки."
            exit 1
        fi

        # Use the original image when legacy NAT is available.
        # Ubuntu/nft-only hosts require an nft-based image.
        AMNEZIA_IMAGE="ghcr.io/spcfox/amnezia-wg-easy"
        if ! command -v iptables-legacy >/dev/null 2>&1 || ! iptables-legacy -t nat -S >/dev/null 2>&1; then
            echo "Legacy NAT недоступен. Проверка nftables NAT..."
            if ! iptables -t nat -S >/dev/null 2>&1; then
                echo "❌ NAT недоступен ни через legacy, ни через системный iptables."
                exit 1
            fi
            install -d -m 755 /srv/amnezia-wg-image
            cat > /srv/amnezia-wg-image/Dockerfile <<'AMNEZIA_NFT_DOCKERFILE'
FROM ghcr.io/spcfox/amnezia-wg-easy
RUN test -x /sbin/iptables-nft && ln -sf /sbin/iptables-nft /etc/alternatives/iptables
AMNEZIA_NFT_DOCKERFILE
            docker build -t amnezia-wg-easy:nft /srv/amnezia-wg-image
            AMNEZIA_IMAGE="amnezia-wg-easy:nft"
        fi
        echo "Образ AmneziaWG: $AMNEZIA_IMAGE"

        echo
        echo "Запуск AmneziaWG Easy..."


        # Передаём пароль через окружение, без его значения в аргументах процесса.
        export PASSWORD="$AMNEZIA_PASSWORD"

        docker run -d \
            --name amnezia-wg-easy \
            -e WG_HOST="$PUBLIC_IP" \
            -e PASSWORD \
            -e WG_DEFAULT_ADDRESS="$AMNEZIA_ADDRESS" \
            -e WG_DEFAULT_DNS="8.8.8.8, 8.8.4.4" \
            -p 51820:51820/udp \
            -p 127.0.0.1:51821:51821/tcp \
            --cap-add=NET_ADMIN \
            --cap-add=SYS_MODULE \
            --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
            --sysctl="net.ipv4.ip_forward=1" \
            --device=/dev/net/tun:/dev/net/tun \
            --restart unless-stopped \
            -v /srv/amnezia-wg:/etc/wireguard \
            "$AMNEZIA_IMAGE"


        # Пароль больше не нужен в shell-переменной.
        unset AMNEZIA_PASSWORD


        echo "Проверка готовности AmneziaWG Easy (до 120 секунд)..."
        if wait_for_amnezia; then
            AMNEZIA_RESULT="контейнер запущен, админка отвечает"
        else
            AMNEZIA_RESULT="ОШИБКА: готовность контейнера не подтверждена"
            FINAL_EXIT_CODE=1
            echo "Диагностика: sudo docker logs --tail 100 amnezia-wg-easy"
        fi

    fi

    unset AMNEZIA_PASSWORD PASSWORD

else

    echo "Установка AmneziaWG Easy пропущена."

fi


# ------------------------------------------------------------
# SSH hardening (prepare only; never disable current access here)
# ------------------------------------------------------------

echo
echo "[8] SSH hardening..."
if [[ "$SETUP_SSH" == "true" ]]; then
    install_embedded_ssh_hardening
    echo "Подготовка SSH: пользователь, sudo и публичный ключ."
    if ! SSH_HARDENING_PORT="$SSH_PORT" /usr/local/sbin/initial-ssh-hardening --prepare; then
        echo "❌ Настройка SSH не выполнена. Старый SSH-доступ сохранён."
        FINAL_EXIT_CODE=1
    else
        SSH_STATE=/var/lib/initial-ssh-hardening/config
        # This file is root-owned, written by the embedded SSH helper.
        source "$SSH_STATE"
        SSH_KEY_FILE="/home/$USERNAME/.ssh/authorized_keys"
        while [[ ! -s "$SSH_KEY_FILE" ]]; do
            echo "❌ Публичный ключ не добавлен: $SSH_KEY_FILE"
            echo "Вставь ключ в файл в другом терминале, затем нажми Enter."
            echo "Для отказа от SSH-настройки введи 'cancel' (завершение с ошибкой)."
            read -r -p "Проверить ключ [Enter/cancel]: " SSH_KEY_ANSWER
            if [[ "$SSH_KEY_ANSWER" == cancel ]]; then
                echo "SSH НЕ НАСТРОЕН. Установка не считается успешной."
                FINAL_EXIT_CODE=1
                break
            fi
        done
        if [[ "${SSH_KEY_ANSWER:-}" != cancel ]]; then
            echo "Применение SSH: порт $SSH_PORT, запрет root и паролей."
            echo "Оставь эту root-сессию открытой. Автооткат через 5 минут."
            if initial-ssh-hardening --finalize; then
                echo "Открой НОВОЕ SSH-подключение и выполни:"
                echo "  sudo initial-ssh-hardening --confirm"
                echo "Ожидаю подтверждения SSH (до 5 минут)..."
                SSH_CONFIRMED=false
                for (( SSH_WAIT=0; SSH_WAIT<150; SSH_WAIT++ )); do
                    if grep -qx 'PHASE=confirmed' "$SSH_STATE"; then
                        SSH_CONFIRMED=true
                        break
                    fi
                    sleep 2
                done
                if [[ "$SSH_CONFIRMED" == true ]]; then
                    echo "✅ SSH подтверждён из нового подключения."
                else
                    echo "❌ SSH не подтверждён. Проверь автооткат. Установка НЕ считается успешной."
                    FINAL_EXIT_CODE=1
                fi
            else
                echo "❌ Не удалось активировать SSH."
                FINAL_EXIT_CODE=1
            fi
        fi
    fi
else
    echo "Настройка SSH пропущена."
fi


# ============================================================
# ФИНАЛЬНАЯ ИНФОРМАЦИЯ
# ============================================================

echo
echo "============================================================"
if (( FINAL_EXIT_CODE == 0 )); then
    echo " НАСТРОЙКА СЕРВЕРА ЗАВЕРШЕНА"
else
    echo " НАСТРОЙКА ЗАВЕРШЕНА С ОШИБКАМИ (СМ. ВЫВОД ВЫШЕ)"
fi
echo "============================================================"

echo
echo "Hostname: $(hostname)"
echo "IP-адреса сервера:"
hostname -I || true

echo
echo "RAM:"
free -h
echo
echo "Disk:"
df -h /

echo
echo "Swap (фактическое состояние):"
if [[ -n "$(swapon --show=NAME --noheadings)" ]]; then
    swapon --show
else
    echo "Swap не используется."
fi

echo
echo "MC выбран: $(yes_no_text "$INSTALL_MC")"
if [[ "$INSTALL_UFW" == "true" ]]; then
    echo
    echo "UFW:"
    ufw status verbose
fi

if [[ "$INSTALL_DOCKER" == "true" ]]; then
    echo
    echo "Docker:"
    docker --version
    docker compose version
fi

echo
echo "AmneziaWG Easy: $AMNEZIA_RESULT"
if [[ "$INSTALL_AMNEZIA" == "true" ]]; then
    docker ps -a --filter 'name=^/amnezia-wg-easy$' \
        --format 'Контейнер: {{.Names}} | {{.Status}} | {{.Ports}}'
    docker inspect --format \
        'Status: {{.State.Status}} | Health: {{if .State.Health}}{{.State.Health.Status}}{{else}}не предусмотрен образом{{end}} | Restart: {{.HostConfig.RestartPolicy.Name}}' \
        amnezia-wg-easy
    if [[ "$AMNEZIA_RESULT" == "контейнер запущен, админка отвечает" ]]; then
        echo "Внешний IPv4: $PUBLIC_IP"
        echo "VPN: 51820/udp"
        echo "DNS: 8.8.8.8, 8.8.4.4"
        echo "Подсеть VPN: $AMNEZIA_SUBNET"
        echo "Конфигурация: /srv/amnezia-wg"
        echo "Админка: http://127.0.0.1:51821 (через SSH-туннель)"
        echo
        echo "На своём компьютере выполните, подставив SSH-пользователя и порт:"
        echo "ssh -N -L 51821:127.0.0.1:51821 -p <SSH_PORT> <SSH_USER>@$PUBLIC_IP"
        echo "Затем откройте http://127.0.0.1:51821"
        echo "Работу VPN с внешнего клиента нужно проверить отдельно."
    fi
fi

echo
if [[ -f /var/run/reboot-required ]]; then
    if (( FINAL_EXIT_CODE == 0 )); then
        echo "Система сообщает о необходимости перезагрузки: sudo reboot"
    else
        echo "Система требует перезагрузки, но сначала исправь ошибки настройки."
    fi
else
    if (( FINAL_EXIT_CODE == 0 )); then
        echo "После первоначальной настройки рекомендуется перезагрузка: sudo reboot"
    else
        echo "Перезагрузка не рекомендуется: настройка завершилась с ошибками."
    fi
fi

exit "$FINAL_EXIT_CODE"
