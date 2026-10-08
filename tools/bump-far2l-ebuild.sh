#!/usr/bin/env bash
# ==========================================================
# Проверка новой версии far2l и обновление ebuild в оверлее gentoo/
#
#   --check   только проверить (код 0 — актуально, 2 — есть новая версия)
#   --bump    создать ebuild новой версии и добавить архив в Manifest
#
# Работает и локально, и в GitHub Actions (пишет результат в $GITHUB_OUTPUT)
# ==========================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

usage() {
   cat <<USAGE
Использование: $0 --check | --bump

  --check     проверить, вышла ли новая версия far2l (код выхода 2, если вышла)
  --bump      создать ebuild новой версии и обновить Manifest
  -h, --help  показать эту справку
USAGE
}

MODE=""
case "${1:-}" in
   --check) MODE=check ;;
   --bump)  MODE=bump ;;
   -h|--help) usage; exit 0 ;;
   *) usage >&2; exit 1 ;;
esac

GIT_REPO="https://github.com/elfmz/far2l.git"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKG_DIR="$REPO_ROOT/gentoo/app-misc/far2l"

# Записывает key=value в $GITHUB_OUTPUT, если скрипт запущен в GitHub Actions
set_output() {
   if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "$1=$2" >> "$GITHUB_OUTPUT"
   fi
}

# Последний релизный тег far2l вида v_X.Y.Z -> X.Y.Z
UPSTREAM_VERSION=$(git ls-remote --tags --refs "$GIT_REPO" 'v_*' \
   | sed -n 's#.*refs/tags/v_\([0-9]\+\.[0-9]\+\.[0-9]\+\)$#\1#p' \
   | sort -V | tail -n 1)
if [[ -z "$UPSTREAM_VERSION" ]]; then
   log_error "Не удалось получить список тегов far2l"
   exit 1
fi

# Самая новая релизная версия ebuild в оверлее (9999 не учитывается)
LOCAL_VERSION=$(find "$PKG_DIR" -maxdepth 1 -name 'far2l-*.ebuild' ! -name 'far2l-9999.ebuild' -printf '%f\n' \
   | sed 's/^far2l-\(.*\)\.ebuild$/\1/' \
   | sort -V | tail -n 1)
if [[ -z "$LOCAL_VERSION" ]]; then
   log_error "В $PKG_DIR нет релизного ebuild far2l"
   exit 1
fi

set_output old_version "$LOCAL_VERSION"
set_output new_version "$UPSTREAM_VERSION"

LATEST=$(printf '%s\n%s\n' "$LOCAL_VERSION" "$UPSTREAM_VERSION" | sort -V | tail -n 1)
if [[ "$LATEST" == "$LOCAL_VERSION" ]]; then
   log_info "Ebuild актуален: far2l $LOCAL_VERSION"
   set_output updated false
   exit 0
fi

log_warn "Вышла far2l $UPSTREAM_VERSION, в оверлее последняя $LOCAL_VERSION"
if [[ "$MODE" == check ]]; then
   set_output updated false
   exit 2
fi

# ----------------------------------------------------------
# Создание ebuild новой версии
# ----------------------------------------------------------
NEW_EBUILD="$PKG_DIR/far2l-$UPSTREAM_VERSION.ebuild"
cp "$PKG_DIR/far2l-$LOCAL_VERSION.ebuild" "$NEW_EBUILD"
log_info "Создан $(basename "$NEW_EBUILD")"

# Скачиваем архив и считаем контрольные суммы для Manifest
# (формат строки DIST тот же, что пишет 'ebuild ... manifest')
DISTFILE="far2l-$UPSTREAM_VERSION.tar.gz"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log_info "Скачивание $DISTFILE..."
curl -fsSL -o "$TMP_DIR/$DISTFILE" \
   "https://github.com/elfmz/far2l/archive/refs/tags/v_$UPSTREAM_VERSION.tar.gz"

SIZE=$(stat -c %s "$TMP_DIR/$DISTFILE")
BLAKE2B=$(b2sum "$TMP_DIR/$DISTFILE" | cut -d' ' -f1)
SHA512=$(sha512sum "$TMP_DIR/$DISTFILE" | cut -d' ' -f1)

MANIFEST="$PKG_DIR/Manifest"
{
   grep -v "^DIST $DISTFILE " "$MANIFEST" 2>/dev/null || true
   echo "DIST $DISTFILE $SIZE BLAKE2B $BLAKE2B SHA512 $SHA512"
} | sort > "$TMP_DIR/Manifest"
cp "$TMP_DIR/Manifest" "$MANIFEST"
log_info "Manifest обновлён"

set_output updated true
log_info "✅ Готово: far2l $LOCAL_VERSION -> $UPSTREAM_VERSION"
