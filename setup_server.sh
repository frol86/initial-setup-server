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

    while true; do

        read -rp "SSH порт [22]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-22}"

        if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] &&
           (( ${#SSH_PORT} <= 5 )) &&
           (( 10#$SSH_PORT >= 1 && 10#$SSH_PORT <= 65535 )); then
            SSH_PORT=$((10#$SSH_PORT))
            break
        fi

        echo "❌ Порт должен быть числом от 1 до 65535."

    done

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

    ufw allow "${SSH_PORT}/tcp"

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
            ghcr.io/spcfox/amnezia-wg-easy


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


# ============================================================
# ФИНАЛЬНАЯ ИНФОРМАЦИЯ
# ============================================================

echo
echo "============================================================"
if (( FINAL_EXIT_CODE == 0 )); then
    echo " НАСТРОЙКА СЕРВЕРА ЗАВЕРШЕНА"
else
    echo " НАСТРОЙКА ЗАВЕРШЕНА С ОШИБКОЙ AMNEZIAWG EASY"
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
    echo "Система сообщает о необходимости перезагрузки: sudo reboot"
else
    echo "После первоначальной настройки рекомендуется перезагрузка: sudo reboot"
fi

exit "$FINAL_EXIT_CODE"
