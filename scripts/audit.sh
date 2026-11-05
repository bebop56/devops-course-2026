#!/usr/bin/env bash
# Аудит конфигурации сервера devops-vm.
# Использование: scripts/audit.sh   (запускается на сервере от имени devops)
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
SSHD_T="$(sudo sshd -T)"
check "Вход от имени root запрещён"        "no"  "$(awk '/^permitrootlogin/{print $2}' <<<"$SSHD_T")"
check "Парольная аутентификация отключена" "no"  "$(awk '/^passwordauthentication/{print $2}' <<<"$SSHD_T")"
# TODO 1: значение параметра port отлично от 22
check "Порт SSH отличен от 22"             "yes" "$(awk '/^port /{print ($2 != 22) ? "yes" : "no"; exit}' <<<"$SSHD_T")"
# TODO 2: значение параметра maxauthtries равно 3
check "MaxAuthTries равен 3"               "3"   "$(awk '/^maxauthtries/{print $2}' <<<"$SSHD_T")"

echo "[2] Межсетевой экран"
UFW_V="$(sudo ufw status verbose)"
check "Межсетевой экран активен" "active" "$(awk '/^Status:/{print $2}' <<<"$UFW_V")"
# TODO 3: политика по умолчанию для входящего трафика равна deny
check "Политика по умолчанию для входящего трафика — deny" "deny" "$(awk '/^Default:/{print $2}' <<<"$UFW_V")"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
sudo nginx -t >/dev/null 2>&1
check "Конфигурация nginx синтаксически корректна" "0" "$?"
openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend 2592000 >/dev/null 2>&1
check "Сертификат действителен ещё 30+ дней" "0" "$?"
WEB_PERMS="ok"
[[ -n "$(find /var/www/devops-site -perm -o+w 2>/dev/null)" ]] && WEB_PERMS="есть файлы с правом записи для всех"
[[ "$(sudo stat -c '%a' /etc/ssl/private/devops.key)" != "600" ]] && WEB_PERMS="права ключа не 600"
check "Нет файлов ресурса с правом записи для всех, ключ — 600" "ok" "$WEB_PERMS"

echo "[5] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy" "healthy" \
    "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
# адреса, на которых прослушиваются порты 5000 и 5432; допустим только 127.0.0.1
EXPOSED="$(ss -tln | awk '$4 ~ /:(5000|5432)$/ {sub(/:[0-9]+$/, "", $4); print $4}' | grep -vx '127.0.0.1' | sort -u | paste -sd ' ')"
check "Порты 5000 и 5432 прослушиваются только на 127.0.0.1" "" "$EXPOSED"
check "Права файла ~/app/.env равны 600" "600" "$(stat -c '%a' "$HOME/app/.env" 2>/dev/null)"

echo "[6] Контрольная работа № 2"
KR2_DIR="$HOME/kr2"
# контейнер определяется по имени сервиса, а не по имени, сформированному Compose
REDIS_CID="$(docker compose --project-directory "$KR2_DIR" ps -q redis 2>/dev/null)"
check "Контейнер сервиса redis в состоянии healthy" "healthy" \
    "$(docker inspect -f '{{.State.Health.Status}}' "$REDIS_CID" 2>/dev/null)"
check "Порт 8004 опубликован только на 127.0.0.1" "127.0.0.1:8004" \
    "$(docker compose --project-directory "$KR2_DIR" port app 8004 2>/dev/null | sort -u | paste -sd ' ')"
check "Права файла ~/kr2/.env равны 600" "600" "$(stat -c '%a' "$KR2_DIR/.env" 2>/dev/null)"
openssl x509 -in /etc/ssl/certs/kr2.crt -noout -checkend 2592000 >/dev/null 2>&1
check "Сертификат kr2.crt действителен ещё 30+ дней" "0" "$?"
check "Ресурс kr2 активирован (ссылка в sites-enabled)" "/etc/nginx/sites-available/kr2" \
    "$(readlink -f /etc/nginx/sites-enabled/kr2 2>/dev/null)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
