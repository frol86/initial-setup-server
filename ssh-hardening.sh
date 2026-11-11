#!/usr/bin/env bash
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
  USERNAME="$(prompt 'Имя пользователя' 'oleg')"
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ && "$USERNAME" != root ]] || fail "Некорректное имя."
  OLD_PORT="$(sshd -T | awk '$1=="port" && !found {print $2; found=1}')"
  OLD_PORT="$(printf '%s' "$OLD_PORT" | tr -d '\n')"
  NEW_PORT="$(prompt 'SSH-порт' "$OLD_PORT")"
  [[ "$NEW_PORT" =~ ^[0-9]{1,5}$ ]] || fail "Неправильный порт."
  (( 10#$NEW_PORT >= 1 && 10#$NEW_PORT <= 65535 )) || fail "Порт вне диапазона."
  NEW_PORT="$((10#$NEW_PORT))"
  OLD_SOCKET=disabled
  OLD_SERVICE=disabled
  systemctl is-enabled --quiet ssh.socket && OLD_SOCKET=enabled
  if systemctl is-active --quiet ssh.socket; then OLD_SOCKET=active; fi
  systemctl is-enabled --quiet ssh.service && OLD_SERVICE=enabled
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y sudo openssh-server
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
  install -m 755 "$0" "$SELF"
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
  [[ -n "${SSH_CONNECTION:-}" ]] || fail "Требуется новая SSH-сессия."
  local client_ip client_port server_ip server_port
  read -r client_ip client_port server_ip server_port <<< "${SSH_CONNECTION:-}"
  [[ "$server_port" == "$NEW_PORT" ]] || fail "Текущий SSH-порт не совпадает с $NEW_PORT."
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
