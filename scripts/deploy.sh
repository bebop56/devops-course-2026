#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
#
# На хостовой системе (Windows, Git Bash) нет rsync, поэтому каталог site/
# передаётся архивом git archive по одному SSH-соединению, а rsync
# выполняется на сервере: он приводит REMOTE_DIR к точной копии site/
# (--delete) с правами 755/644 (--chmod).
set -euo pipefail

REMOTE="devops"                     # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         echo "Использование: $0 [--dry-run]" >&2; exit 1 ;;
esac

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "deploy: нет файла site/index.html, доставка отменена" >&2
    exit 1
fi
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    echo "deploy: в репозитории есть незафиксированные изменения, доставка отменена" >&2
    exit 1
fi

# 3. Синхронизация: архив зафиксированного каталога site/ -> временный каталог
#    на сервере -> rsync в REMOTE_DIR. Одно SSH-соединение, без запроса пароля.
git -C "$REPO_ROOT" archive --format=tar HEAD site \
    | ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE" "
        set -e
        STAGE=\$(mktemp -d)
        trap 'rm -rf \"\$STAGE\"' EXIT
        tar -xf - -C \"\$STAGE\"
        rsync -av --delete --chmod=D755,F644 $DRY_RUN \"\$STAGE/site/\" '$REMOTE_DIR/'
    "

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
    exit 0
fi

# 5. Проверка доступности с проверкой сертификата
if ! curl -fsS --cacert "$CA_CERT" -o /dev/null "$SITE_URL"; then
    echo "deploy: ресурс $SITE_URL недоступен после доставки" >&2
    exit 1
fi
git -C "$REPO_ROOT" rev-parse --short HEAD
