#!/usr/bin/env bash
#
# Установка Watchgoose.
#
# Спрашивает то, что нельзя угадать, генерирует то, что можно, поднимает
# стек и печатает первый токен доступа.
#
# ⚠️ Повторный запуск НЕ ПЕРЕТИРАЕТ уже заданные секреты.
#
# Смена INGEST_TOKEN на работающей системе означает, что коллектор
# получит 401 и логи осядут в его дисковой очереди. Снаружи это выглядит
# как работающая система с пустым поиском — самая дорогая ошибка,
# которую тут можно допустить. Поэтому заданное только показывается,
# а меняется по явному подтверждению.

set -euo pipefail

cd "$(dirname "$0")"

# ── Режим работы ────────────────────────────────────────────────────────────
#
# ⚠️ Обновление — ОТДЕЛЬНЫЙ режим, а не повторная установка.
#
# Раньше поднять новую версию можно было только прогнав установщик целиком:
# он заново спрашивал про домен, сертификат, бюджет и S3, и приходилось
# жать Enter десять раз, чтобы поменять один номер сборки. Хуже того, файлы
# развёртывания при этом НЕ обновлялись — установщик существующие не трогает.
# Новый бинарник с прошлым docker-compose.yml — это расхождение, которое
# ломается молча и разбирается долго.
UPDATE_MODE=0
TAG_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --update|-u) UPDATE_MODE=1 ;;
        --tag=*)     TAG_OVERRIDE="${1#--tag=}" ;;
        --tag)       shift; TAG_OVERRIDE="${1:-}" ;;
        -h|--help)
            cat <<СПРАВКА
Установка и обновление Watchgoose.

  ./install.sh              установка: спросит домен, бюджет, S3
  ./install.sh --update     обновление: ничего не спрашивает, берёт всё из .env
  ./install.sh --update --tag=1.1.0
                            обновление до конкретной версии

Переменные окружения:
  WATCHGOOSE_TAG   версия сборки (по умолчанию latest)
  WG_REF           ветка репозитория с файлами развёртывания
  WG_PROJECT       владелец/репозиторий на GitHub
СПРАВКА
            exit 0 ;;
        *) echo "неизвестный аргумент: $1 (см. --help)" >&2; exit 1 ;;
    esac
    shift
done

# ── Откуда берётся выпуск ───────────────────────────────────────────────────
#
# Исходники приватные и лежат в другом месте. Публичная сторона — этот
# репозиторий: в нём файлы развёртывания, а в разделе релизов — собранные
# бинарники по версиям. Оба адреса выводятся из имени проекта.
#
# Каждую переменную можно перекрыть окружением: так пробуют выпуск
# из своей ветки или ставят из форка, не правя скрипт.
#
#     WG_REF=develop ./install.sh          — файлы из другой ветки
#     WATCHGOOSE_TAG=1.0.0 ./install.sh    — закрепить версию сборки
WG_PROJECT="${WG_PROJECT:-4eSyH/watchgoose}"
WG_REF="${WG_REF:-main}"

# Файлы развёртывания: сырые файлы публичного репозитория.
WG_FILES_BASE="${WG_FILES_BASE:-https://raw.githubusercontent.com/$WG_PROJECT/$WG_REF}"
# Бинарники: раздел релизов того же репозитория.
WG_RELEASES="${WG_RELEASES:-https://github.com/$WG_PROJECT/releases}"

# ⚠️ Реестра контейнеров НЕТ, и он не нужен.
#
# Наружу уходит бинарник, выложенный в релиз по версиям. Установщик
# скачивает нужную сборку, сверяет контрольную сумму и заворачивает её
# в образ прямо здесь, на сервере. Имя локальное: в реестр он не уходит
# и оттуда не тянется.
WATCHGOOSE_IMAGE="${WATCHGOOSE_IMAGE:-watchgoose}"
export WATCHGOOSE_IMAGE

ENV_FILE=".env"

# ⚠️ Версию НЕ вычисляем — её несёт тег образа.
#
# Раньше здесь стоял git describe: установщик собирал образ из исходников
# и проставлял номер линковщиком. Теперь исходников на машине нет вовсе,
# а версия зашита в опубликованный образ при выпуске и видна в подвале
# интерфейса и в /healthz. Здесь остаётся только выбор тега.
#
# Умолчание latest удобно для первой пробы, но на боевом сервере тег
# закрепляют номером: иначе перезапуск однажды принесёт версию, которой
# никто не ждал, и разбираться придётся в самый неподходящий момент.
WATCHGOOSE_TAG="${WATCHGOOSE_TAG:-latest}"
export WATCHGOOSE_TAG

COMPOSE="docker compose -f deploy/docker-compose.yml"

# ── Вывод ───────────────────────────────────────────────────────────────────
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m%s\033[0m\n\n' "$*" >&2; exit 1; }

# ── Что уже есть ────────────────────────────────────────────────────────────
declare -A ENV_VALUES

load_env() {
    [ -f "$ENV_FILE" ] || return 0
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        ENV_VALUES["$key"]="$value"
    done < "$ENV_FILE"
}

get() { printf '%s' "${ENV_VALUES[$1]:-}"; }
set_value() { ENV_VALUES["$1"]="$2"; }

# secret заполняет переменную случайным значением, если её ещё нет.
secret() {
    local key="$1" bytes="${2:-32}"
    if [ -n "$(get "$key")" ]; then
        info "$key — уже задан, оставляю как есть"
        return
    fi
    set_value "$key" "$(openssl rand -hex "$bytes")"
    info "$key — сгенерирован"
}

# ask спрашивает значение, показывая текущее как значение по умолчанию.
ask() {
    local key="$1" prompt="$2" default="${3:-}"
    local current answer
    current="$(get "$key")"
    [ -n "$current" ] && default="$current"

    if [ -n "$default" ]; then
        read -r -p "  $prompt [$default]: " answer || true
        answer="${answer:-$default}"
    else
        read -r -p "  $prompt: " answer || true
    fi
    set_value "$key" "$answer"
}

# ── Зависимости ─────────────────────────────────────────────────────────────
#
# ⚠️ Ответ на «ставить ли» НЕ идёт через ask.
#
# ask пишет ответ в ENV_VALUES, а оттуда всё уезжает в .env. Служебному
# «да» там не место: файл с секретами не должен обрастать мусором.
confirm() {
    local prompt="$1" answer
    read -r -p "  $prompt [Y/n]: " answer || true
    case "${answer:-y}" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# sudo_run — как выполнять привилегированное. Пусто, если мы и так root.
SUDO=""
need_root() {
    [ "$(id -u)" = "0" ] && { SUDO=""; return 0; }
    command -v sudo >/dev/null && { SUDO="sudo"; return 0; }
    die "нужны права root: запустите от root или поставьте sudo"
}

# pkg_install — поставить пакеты штатным для системы способом.
pkg_install() {
    need_root
    if   command -v apt-get >/dev/null; then $SUDO apt-get update -qq && $SUDO apt-get install -y "$@"
    elif command -v dnf     >/dev/null; then $SUDO dnf install -y "$@"
    elif command -v yum     >/dev/null; then $SUDO yum install -y "$@"
    elif command -v zypper  >/dev/null; then $SUDO zypper --non-interactive install "$@"
    elif command -v apk     >/dev/null; then $SUDO apk add --no-cache "$@"
    elif command -v pacman  >/dev/null; then $SUDO pacman -Sy --noconfirm "$@"
    else die "не узнал пакетный менеджер: поставьте вручную — $*"
    fi
}

# install_docker — официальный установщик Docker: он даёт последнюю
# стабильную версию вместе с плагином compose v2.
#
# ⚠️ Скрипт СНАЧАЛА скачивается, потом запускается, а не пайпится в sh.
#
# «curl | sh» не оставляет ни единого шанса заметить, что именно
# выполняется: оборванная закачка исполнится наполовину, а подменённый
# ответ — целиком и от root. Здесь файл сначала ложится на диск, проверяется
# на непустоту и на то, что это вообще shell-скрипт, и только потом идёт
# в исполнение. Стоит это одной лишней строки.
install_docker() {
    need_root
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    info "скачиваю официальный установщик Docker"
    if command -v curl >/dev/null; then
        curl -fsSL https://get.docker.com -o "$tmp" || die "не удалось скачать установщик Docker"
    elif command -v wget >/dev/null; then
        wget -qO "$tmp" https://get.docker.com || die "не удалось скачать установщик Docker"
    else
        die "нет ни curl, ни wget: поставьте один из них"
    fi

    [ -s "$tmp" ] || die "установщик Docker скачался пустым"
    head -n1 "$tmp" | grep -q '^#!' || die "скачанное не похоже на скрипт — проверьте сеть и прокси"

    info "запускаю установщик (нужны права root)"
    $SUDO sh "$tmp" || die "установщик Docker завершился с ошибкой"

    # На системах с systemd служба после установки может быть не поднята.
    if command -v systemctl >/dev/null; then
        $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
    fi
}

say "Проверяю окружение"

MISSING=()
command -v docker >/dev/null || MISSING+=("docker")
command -v openssl >/dev/null || MISSING+=("openssl")
# compose проверяем только если docker уже есть: иначе вопрос преждевременный.
if command -v docker >/dev/null && ! docker compose version >/dev/null 2>&1; then
    MISSING+=("docker-compose-v2")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    warn "не хватает: ${MISSING[*]}"
    if confirm "Поставить недостающее сейчас?"; then
        for item in "${MISSING[@]}"; do
            case "$item" in
                openssl) info "ставлю openssl"; pkg_install openssl ;;
                docker|docker-compose-v2)
                    # Плагин compose приходит вместе с Docker из официального
                    # установщика, поэтому оба случая лечатся одинаково.
                    if [ -z "${DOCKER_DONE:-}" ]; then install_docker; DOCKER_DONE=1; fi ;;
            esac
        done
    else
        die "без них установка невозможна: docker, docker compose v2 и openssl"
    fi
fi

# Повторная проверка: установка могла пройти, а могла и не дать результата.
command -v docker >/dev/null || die "docker так и не появился в PATH"
command -v openssl >/dev/null || die "openssl так и не появился в PATH"
docker compose version >/dev/null 2>&1 || die "docker compose v2 не найден: обновите Docker"

# ⚠️ Демон может быть установлен, но недоступен ТЕКУЩЕМУ пользователю.
#
# После свежей установки пользователь ещё не в группе docker, и все команды
# отвечают «permission denied» — на вид неотличимо от «docker не установлен».
if ! docker version >/dev/null 2>&1; then
    warn "docker установлен, но недоступен этому пользователю"
    info "добавьте себя в группу и перезайдите:"
    info "  sudo usermod -aG docker ${USER:-$(id -un)} && newgrp docker"
    die "после этого запустите install.sh заново"
fi
info "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
info "compose $($COMPOSE version --short 2>/dev/null || echo '?')"

# ── Файлы развёртывания ─────────────────────────────────────────────────────
#
# ⚠️ Установщик рассчитан на запуск БЕЗ исходников.
#
# Наружу уходит только образ, поэтому рядом со скриптом обычно нет ничего.
# Недостающие файлы — сам compose и конфигурация служб — забираются из
# публичного репозитория выпуска. Уже лежащие рядом НЕ перетираются:
# иначе правка, сделанная руками на сервере, молча пропала бы при
# следующем запуске.
fetch() {
    local rel="$1" dest="$2"
    [ -f "$dest" ] && { info "$dest — уже есть, оставляю"; return 0; }
    mkdir -p "$(dirname "$dest")"
    if command -v curl >/dev/null; then
        curl -fsSL "$WG_FILES_BASE/$rel" -o "$dest" || return 1
    elif command -v wget >/dev/null; then
        wget -qO "$dest" "$WG_FILES_BASE/$rel" || return 1
    else
        die "нет ни curl, ни wget: поставьте один из них"
    fi
    # Пустой или подменённый ответ (например страница 404) хуже, чем
    # отсутствие файла: compose упадёт с невнятной ошибкой разбора.
    [ -s "$dest" ] || { rm -f "$dest"; return 1; }
    info "$dest — скачан"
}

if [ ! -f deploy/docker-compose.yml ]; then
    say "Забираю файлы развёртывания"
    info "проект: $WG_PROJECT (ветка $WG_REF)"
    for f in deploy/docker-compose.yml deploy/otel.yaml deploy/scrape.yml \
             deploy/Caddyfile deploy/clickhouse/logs.xml deploy/vm-aggr.yaml \
             deploy/Dockerfile.release; do
        fetch "$f" "$f" || die "не удалось скачать $f — проверьте WG_PROJECT и доступность сети"
    done
    # ⚠️ Файлы Grafana сюда НЕ входят.
    #
    # Служба есть в compose, но живёт под профилем grafana и по умолчанию
    # не стартует: Watchgoose не заменяет Grafana для графиков и трендов,
    # а раздавать её настройку вместе с установкой значит обещать то,
    # чего в поставке нет. Кому нужны панели — поднимает свою и берёт
    # данные из тех же хранилищ.
fi

load_env
[ -f "$ENV_FILE" ] && info "найден $ENV_FILE — заданное сохраню"

if [ "$UPDATE_MODE" = "0" ]; then

    # ── Домен и сертификат ──────────────────────────────────────────────────────
    say "Домен и сертификат"
    cat <<'ТЕКСТ'
      Режимы:
        letsencrypt — сертификат выпускается сам. Нужны запись DNS на этот
                      сервер и открытые снаружи порты 80 и 443.
        own         — свой сертификат: положите fullchain.pem и privkey.pem
                      в deploy/certs.
        off         — без шифрования. Годится только для своей машины:
                      токены пойдут открытым текстом.
ТЕКСТ
    ask WG_TLS_MODE "Режим (letsencrypt/own/off)" "letsencrypt"

    case "$(get WG_TLS_MODE)" in
        letsencrypt)
            ask WG_DOMAIN "Домен" ""
            ask WG_ACME_EMAIL "Почта для уведомлений удостоверяющего центра" ""
            [ -n "$(get WG_DOMAIN)" ] || die "для letsencrypt нужен домен"
            set_value WG_SITE_SCHEME ""
            set_value WG_TLS_LINE ""
            set_value WG_ACME_CA_LINE ""
            set_value WG_ACME_EMAIL_LINE "email $(get WG_ACME_EMAIL)"
            ;;
        own)
            ask WG_DOMAIN "Домен" ""
            set_value WG_SITE_SCHEME ""
            set_value WG_TLS_LINE "tls /certs/fullchain.pem /certs/privkey.pem"
            set_value WG_ACME_CA_LINE ""
            set_value WG_ACME_EMAIL_LINE ""
            mkdir -p deploy/certs
            if [ ! -f deploy/certs/fullchain.pem ]; then
                warn "положите fullchain.pem и privkey.pem в deploy/certs — без них Caddy не поднимется"
            fi
            ;;
        off)
            ask WG_DOMAIN "Адрес (домен или localhost)" "localhost"
            set_value WG_SITE_SCHEME "http://"
            set_value WG_TLS_LINE ""
            set_value WG_ACME_CA_LINE ""
            set_value WG_ACME_EMAIL_LINE ""
            warn "без шифрования токены доступа передаются открытым текстом"
            ;;
        *) die "неизвестный режим: $(get WG_TLS_MODE)" ;;
    esac

    # ⚠️ Порты наружу открывает Caddy, а остальные контейнеры остаются
    # на localhost. Без TLS Caddy не нужен, и тогда порты публикует сам
    # watchgoose — тоже на localhost.
    if [ "$(get WG_TLS_MODE)" = "off" ]; then
        set_value WG_BIND "127.0.0.1"
    else
        set_value WG_BIND "127.0.0.1"
    fi

    # ── Секреты ─────────────────────────────────────────────────────────────────
    say "Секреты"
    secret PG_PASS 24
    secret CH_PASS 24
    secret INGEST_TOKEN 32
    secret MINI_APP_SECRET 32
    secret ARCHIVE_ENCRYPTION_KEY 32

    # ── Место ───────────────────────────────────────────────────────────────────
    say "Сколько места система себе позволяет"
    cat <<'ТЕКСТ'
      Это объём НА ВСЁ вместе: база знаний, логи, трассировки и метрики.
      Пока занято меньше — ничего не удаляется досрочно.
      Пусто — ограничения по объёму нет.
ТЕКСТ
    ask RETENTION_DISK_BUDGET "Бюджет (например 200GB)" "200GB"

    # ── Архив ───────────────────────────────────────────────────────────────────
    say "Архив в S3"
    # ⚠️ По умолчанию ВКЛЮЧЁН.
    #
    # Раньше умолчанием было «нет», и установка молча проходила мимо архива:
    # логи жили ровно до того, как упрутся в бюджет диска и уйдут под нож
    # ротации. Обнаруживалось это в день, когда за старыми логами приходили
    # и не находили. Хранилище — не украшение, а единственное место, откуда
    # сутки можно вернуть, поэтому вопрос задаётся с ответом «да», а отказ
    # требует осознанного «нет».
    info "Хранит посуточные батчи логов, трассировок и метрик, а также логи инцидентов."
    info "Без него сутки удаляются ротацией безвозвратно, когда кончится место."
    ask ARCHIVE_ENABLED "Включить архив? (true/false)" "true"

    # ⚠️ Профили считаем здесь, а поднимаем ниже одним вызовом.
    #
    # archive       — ячейки восстановления. Нужны ВСЕГДА при включённом
    #                 архиве: без них сутки уезжают в S3 и не читаются обратно.
    # archive-local — вдобавок MinIO рядом. Только когда своего S3 нет.
    ARCHIVE_PROFILES=()

    if [ "$(get ARCHIVE_ENABLED)" = "true" ]; then
        cat <<'ТЕКСТ'
      Своё хранилище или встроенное?
        свой   — S3 уже есть (облако, MinIO на другой машине, любой S3-совместимый).
                 Так и надо в бою: архив переживёт смерть этой машины.
        рядом  — поднять MinIO этим же compose. Годится для проверки и малых
                 установок, но лежать он будет на том же диске.
ТЕКСТ
        ask S3_KIND "Хранилище (свой/рядом)" "свой"

        if [ "$(get S3_KIND)" = "рядом" ]; then
            ARCHIVE_PROFILES+=(--profile archive-local)
            set_value S3_ENDPOINT "http://minio:9000"
            set_value S3_REGION "us-east-1"
            ask S3_BUCKET "Бакет" "watchgoose"
            secret S3_ACCESS_KEY 12
            secret S3_SECRET_KEY 24
            info "MinIO поднимется рядом, ключи сгенерированы"
        else
            info "адрес с http:// или https://, например https://storage.yandexcloud.net"
            ask S3_ENDPOINT "Адрес S3" ""
            ask S3_BUCKET "Бакет" "watchgoose-archive"
            ask S3_REGION "Регион" "ru-central1"
            ask S3_ACCESS_KEY "Ключ доступа" ""
            ask S3_SECRET_KEY "Секретный ключ" ""

            [ -n "$(get S3_ENDPOINT)" ] || die "без адреса S3 архив не включить"
            [ -n "$(get S3_ACCESS_KEY)" ] || die "нужен ключ доступа к S3"
            [ -n "$(get S3_SECRET_KEY)" ] || die "нужен секретный ключ к S3"
            case "$(get S3_ENDPOINT)" in
                http://*|https://*) ;;
                *) die "адрес S3 должен начинаться с http:// или https://" ;;
            esac

            # ⚠️ Проверяем ДОСТУП СЕЙЧАС, а не в 02:00 первой ночи.
            #
            # Выгрузка идёт по расписанию раз в сутки. Опечатка в ключе или
            # закрытый бакет обнаружились бы строкой в журнале через сутки,
            # а заметили бы её через месяц — когда за архивом придут и не найдут.
            # Проверка стоит одного запуска mc, образ уже используется стеком.
            say "Проверяю доступ к S3"
            # ⚠️ --entrypoint sh обязателен: у образа mc точка входа — сам mc,
            # и без подмены он принимает «sh» за свою подкоманду и отвечает
            # «`sh` is not a recognized command». Проверка при этом всегда
            # падала бы, пугая исправной настройкой.
            if docker run --rm --entrypoint sh minio/mc:RELEASE.2024-11-05T11-29-45Z -c "
                    mc alias set chk '$(get S3_ENDPOINT)' '$(get S3_ACCESS_KEY)' '$(get S3_SECRET_KEY)' >/dev/null 2>&1 &&
                    mc ls chk/'$(get S3_BUCKET)' >/dev/null 2>&1" 2>/dev/null; then
                info "доступ есть, бакет $(get S3_BUCKET) виден"
            else
                warn "не удалось прочитать бакет $(get S3_BUCKET) по адресу $(get S3_ENDPOINT)"
                warn "причины обычно три: опечатка в ключах, бакет не создан, адрес недоступен с этой машины"
                confirm "Всё равно продолжить?" || die "поправьте доступ к S3 и запустите заново"
            fi
        fi

        ask S3_PREFIX "Префикс" "prod/"
        ask ARCHIVE_RETENTION_DAYS "Сколько суток хранить батчи" "180"

        # Ячейки восстановления нужны при любом виде хранилища.
        ARCHIVE_PROFILES+=(--profile archive)

        warn "логи инцидентов из архива не удаляются никогда, срок их не касается"
        warn "ARCHIVE_ENCRYPTION_KEY: потеряете — архив не прочитать. Сохраните отдельно."
        info "удаление старого в S3 идёт в пробном режиме: ARCHIVE_RETENTION_DRY_RUN=true"
        info "посмотрите месяц в журнал «что удалилось бы» и снимите его осознанно"
    fi

    # ── Запись .env ─────────────────────────────────────────────────────────────
    # ── Запуск ──────────────────────────────────────────────────────────────────
    # Кладём выбор образа в .env: дальше человек работает обычным
    # docker compose, без установщика, и должен получать ТО ЖЕ самое.
    set_value WATCHGOOSE_IMAGE "$WATCHGOOSE_IMAGE"
    set_value WATCHGOOSE_TAG "$WATCHGOOSE_TAG"

    say "Записываю $ENV_FILE"
    # ⚠️ Права ставим ДО первого байта, а не после записи.
    #
    # Перенаправление создаёт файл с 0666 & ~umask, то есть на типовой машине
    # 0644, и он остаётся читаемым всем, пока блок ниже отрабатывает вместе
    # с подпроцессом sort. Внутри к тому времени уже лежат PG_PASS, CH_PASS,
    # INGEST_TOKEN, MINI_APP_SECRET и ARCHIVE_ENCRYPTION_KEY — одного чтения
    # в этом окне хватает. chmod после записи оставлен страховкой.
    : > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    {
        echo "# Создан install.sh — правьте руками, скрипт заданное не перетирает."
        for key in "${!ENV_VALUES[@]}"; do
            printf '%s=%s\n' "$key" "${ENV_VALUES[$key]}"
        done | sort
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    info "права 600: внутри секреты"



else
    # ── Обновление ──────────────────────────────────────────────────────────
    #
    # Ничего не спрашиваем: всё уже отвечено при установке и лежит в .env.
    [ -f "$ENV_FILE" ] || die "нет $ENV_FILE — это не обновление, а первая установка: запустите без --update"

    WATCHGOOSE_TAG="${TAG_OVERRIDE:-$(get WATCHGOOSE_TAG)}"
    WATCHGOOSE_TAG="${WATCHGOOSE_TAG:-latest}"
    export WATCHGOOSE_TAG

    # Профили восстанавливаем из ответов прошлой установки, а не спрашиваем.
    ARCHIVE_PROFILES=()
    if [ "$(get ARCHIVE_ENABLED)" = "true" ]; then
        [ "$(get S3_KIND)" = "рядом" ] && ARCHIVE_PROFILES+=(--profile archive-local)
        ARCHIVE_PROFILES+=(--profile archive)
    fi

    # ⚠️ Файлы развёртывания ОБНОВЛЯЮТСЯ, и это половина смысла режима.
    #
    # Новая версия может требовать новой переменной окружения или новой
    # службы в compose. Оставив прежние файлы, мы получили бы свежий
    # бинарник в прошлом окружении — расхождение, которое ломается молча.
    # Изменённое не затирается бесследно: прежний файл ложится рядом
    # с меткой времени, чтобы правку, сделанную руками на сервере, можно
    # было вернуть.
    say "Обновляю файлы развёртывания"
    UPD_TMP="$(mktemp -d)"
    STAMP="$(date +%Y%m%d-%H%M%S)"
    ИЗМЕНЕНО=0
    for f in deploy/docker-compose.yml deploy/otel.yaml deploy/scrape.yml              deploy/Caddyfile deploy/clickhouse/logs.xml deploy/vm-aggr.yaml              deploy/Dockerfile.release; do
        mkdir -p "$UPD_TMP/$(dirname "$f")"
        if ! download "$WG_FILES_BASE/$f" "$UPD_TMP/$f" 2>/dev/null || [ ! -s "$UPD_TMP/$f" ]; then
            warn "$f не скачался — оставляю прежний"
            continue
        fi
        if [ -f "$f" ] && cmp -s "$f" "$UPD_TMP/$f"; then
            continue
        fi
        if [ -f "$f" ]; then
            cp "$f" "$f.bak-$STAMP"
            info "$f обновлён (прежний: $f.bak-$STAMP)"
        else
            info "$f добавлен"
        fi
        mkdir -p "$(dirname "$f")"
        cp "$UPD_TMP/$f" "$f"
        ИЗМЕНЕНО=$((ИЗМЕНЕНО+1))
    done
    rm -rf "$UPD_TMP"
    [ "$ИЗМЕНЕНО" = "0" ] && info "файлы развёртывания не менялись"

    БЫЛО="$(curl -s -m 5 http://127.0.0.1:${WG_HTTP_PORT:-8080}/healthz 2>/dev/null || true)"
fi

say "Беру сборку $WATCHGOOSE_TAG"

# Архитектура машины в тех же словах, что и в именах файлов релиза.
case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "архитектура $(uname -m) не поддерживается: в релизе есть amd64 и arm64" ;;
esac
info "архитектура: $ARCH"

BIN_NAME="watchgoose_linux_${ARCH}"
if [ "$WATCHGOOSE_TAG" = "latest" ]; then
    BIN_URL="$WG_RELEASES/latest/download/$BIN_NAME"
    SUM_URL="$WG_RELEASES/latest/download/checksums.txt"
else
    BIN_URL="$WG_RELEASES/download/$WATCHGOOSE_TAG/$BIN_NAME"
    SUM_URL="$WG_RELEASES/download/$WATCHGOOSE_TAG/checksums.txt"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

download() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null; then
        curl -fsSL "$url" -o "$dest"
    else
        wget -qO "$dest" "$url"
    fi
}

info "скачиваю $BIN_NAME"
download "$BIN_URL" "$WORK/$BIN_NAME" || die "не удалось скачать сборку: $BIN_URL"
[ -s "$WORK/$BIN_NAME" ] || die "сборка скачалась пустой"

# ⚠️ Контрольная сумма проверяется ОБЯЗАТЕЛЬНО.
#
# Файл едет по открытой сети и попадает в образ, который запускается
# с доступом ко всем хранилищам. Оборванная закачка и подменённый ответ
# выглядят одинаково — как обычный файл, поэтому доверять размеру нельзя.
if download "$SUM_URL" "$WORK/checksums.txt" 2>/dev/null && [ -s "$WORK/checksums.txt" ]; then
    want="$(grep " \*\?$BIN_NAME\$" "$WORK/checksums.txt" | awk '{print $1}' | head -1)"
    if [ -z "$want" ]; then
        warn "в checksums.txt нет строки про $BIN_NAME — проверить сумму нечем"
    else
        got="$(sha256sum "$WORK/$BIN_NAME" | awk '{print $1}')"
        if [ "$want" != "$got" ]; then
            die "контрольная сумма не сошлась: ожидалось $want, получено $got"
        fi
        info "контрольная сумма сошлась"
    fi
else
    warn "checksums.txt не скачался: сборка принята без проверки суммы"
fi

chmod 0755 "$WORK/$BIN_NAME"
VER="$("$WORK/$BIN_NAME" --version 2>/dev/null | head -1 || echo '?')"
info "версия сборки: $VER"

say "Собираю образ из скачанной сборки"
# Образ собирается локально: реестр не нужен, а окружение внутри —
# то же самое, что и при сборке из исходников.
if [ -f deploy/Dockerfile.release ]; then
    # Запуск из исходников: берём местный файл, а не лезем в сеть.
    cp deploy/Dockerfile.release "$WORK/Dockerfile"
else
    fetch deploy/Dockerfile.release "$WORK/Dockerfile" || die "не удалось скачать deploy/Dockerfile.release"
fi
docker build -q -f "$WORK/Dockerfile" --build-arg "BINARY=$BIN_NAME" \
    -t "$WATCHGOOSE_IMAGE:$WATCHGOOSE_TAG" "$WORK" >/dev/null \
    || die "не удалось собрать образ из скачанной сборки"
info "образ $WATCHGOOSE_IMAGE:$WATCHGOOSE_TAG готов"

say "Поднимаю стек"
PROFILES=()
[ "$(get WG_TLS_MODE)" = "off" ] || PROFILES+=(--profile tls)
# ⚠️ Раскрытие пустого массива под set -u — ошибка в bash до 4.4,
# поэтому ветвимся, а не полагаемся на "${PROFILES[@]:-}".
if [ ${#ARCHIVE_PROFILES[@]} -gt 0 ]; then
    PROFILES+=("${ARCHIVE_PROFILES[@]}")
fi

if [ ${#PROFILES[@]} -gt 0 ]; then
    # В массиве «--profile» и имя лежат ОТДЕЛЬНЫМИ элементами, поэтому
    # для показа отбираем только имена, а не режем строку подстановкой.
    NAMES=()
    for p in "${PROFILES[@]}"; do [ "$p" = "--profile" ] || NAMES+=("$p"); done
    info "профили: ${NAMES[*]}"
    $COMPOSE "${PROFILES[@]}" up -d
else
    $COMPOSE up -d
fi

say "Жду готовности"
for i in $(seq 1 60); do
    if $COMPOSE exec -T watchgoose /watchgoose --version >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# ⚠️ Первый токен печатается в журнал ОДИН РАЗ при первом запуске.
# Второй раз его взять неоткуда: в базе лежит только хэш.
say "Первый токен доступа"
# ⚠️ Ищем строку СО ЗНАЧЕНИЕМ, а не предупреждение о ней.
#
# Само значение печатается отдельной строкой прямо в stderr, минуя
# структурный журнал: иначе токен уехал бы в сборщик логов и осел
# в собственном поисковом индексе, где его найдёт любой обладатель
# logs:read. Рядом в журнале есть предупреждение «СОЗДАН ПЕРВЫЙ ТОКЕН
# АДМИНИСТРАТОРА», и раньше установщик показывал именно его — то есть
# сообщал, что токен где-то напечатан, но не показывал сам токен.
# Опознаём нужную строку по хвосту printSecret.
TOKEN_LINE="$($COMPOSE logs watchgoose 2>/dev/null | grep -m1 'не сохраняйте эту строку в журналах' || true)"
if [ -n "$TOKEN_LINE" ]; then
    printf '  %s\n' "$TOKEN_LINE"
    warn "сохраните его: в базе лежит только хэш, повторно не показать"
else
    info "не найден в журнале — вероятно, база уже была и токены выпущены раньше"
    info "выпустить новый: раздел «Доступ» в интерфейсе"
fi

say "Готово"
case "$(get WG_TLS_MODE)" in
    off) info "интерфейс: http://$(get WG_DOMAIN):${WG_HTTP_PORT:-8080}" ;;
    *)   info "интерфейс: https://$(get WG_DOMAIN)"
         info "приём OTLP: $(get WG_DOMAIN):4317 (gRPC), $(get WG_DOMAIN):4318 (HTTP)"
         info "токен приёма — значение INGEST_TOKEN из $ENV_FILE" ;;
esac
echo
