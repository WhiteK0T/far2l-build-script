#!/usr/bin/env bash
# ==========================================================
# Выпуск новой версии проекта по правилам Semantic Versioning:
# переносит [Unreleased] из Changelog.md в раздел новой версии,
# создаёт коммит «release: X.Y.Z» и тег vX.Y.Z. Push — вручную;
# после push тега workflow release.yml создаёт GitHub Release.
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
Использование: $0 patch|minor|major [--dry-run]

Версия имеет вид MAJOR.MINOR.PATCH (Semantic Versioning):
  patch   только исправления, совместимые с прежней версией     1.2.0 -> 1.2.1
  minor   новые возможности, прежнее поведение сохранено        1.2.0 -> 1.3.0
  major   несовместимые изменения (убран ключ, сменено поведение
          по умолчанию, удалён USE-флаг)                         1.2.0 -> 2.0.0

  --dry-run   показать новую версию и раздел Changelog, ничего не меняя
  -h, --help  показать эту справку

Опубликованную версию (после push тега) менять нельзя — только выпускать новую.
USAGE
}

LEVEL=""
DRY_RUN=no
for arg in "$@"; do
   case "$arg" in
      patch|minor|major) LEVEL="$arg" ;;
      --dry-run) DRY_RUN=yes ;;
      -h|--help) usage; exit 0 ;;
      *) log_error "Неизвестный аргумент: $arg"; usage >&2; exit 1 ;;
   esac
done
if [[ -z "$LEVEL" ]]; then
   usage >&2
   exit 1
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHANGELOG="$REPO_ROOT/Changelog.md"
AWK_LIB="$REPO_ROOT/tools/lib/changelog.awk"
cd "$REPO_ROOT"

if [[ "$DRY_RUN" == no && -n "$(git status --porcelain)" ]]; then
   log_error "В рабочем дереве есть незакоммиченные изменения — закоммитьте или уберите их перед релизом"
   exit 1
fi

# Последний релизный тег vX.Y.Z
LAST_TAG=$(git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
if [[ -z "$LAST_TAG" ]]; then
   log_error "Не найден ни один тег вида vX.Y.Z"
   exit 1
fi
IFS=. read -r MAJOR MINOR PATCH <<< "${LAST_TAG#v}"

# При увеличении числа все числа правее него сбрасываются в 0
case "$LEVEL" in
   patch) PATCH=$((PATCH + 1)) ;;
   minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
   major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac
VERSION="$MAJOR.$MINOR.$PATCH"
DATE=$(date +%F)

if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
   log_error "Тег v$VERSION уже существует"
   exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

rc=0
awk -v mode=release -v version="$VERSION" -v date="$DATE" -f "$AWK_LIB" "$CHANGELOG" > "$TMP" || rc=$?
case $rc in
   0) ;;
   3) log_error "В [Unreleased] нет изменений — выпускать нечего"; exit 1 ;;
   4) log_error "В Changelog.md нет раздела [Unreleased]"; exit 1 ;;
   *) log_error "Не удалось обработать Changelog.md"; exit 1 ;;
esac

log_info "Версия: $LAST_TAG -> v$VERSION ($LEVEL)"

if [[ "$DRY_RUN" == yes ]]; then
   log_info "Раздел Changelog, который будет создан:"
   awk -v hdr="## [$VERSION] - $DATE" '$0 == hdr {p = 1} p && /^## \[/ && $0 != hdr {exit} p' "$TMP"
   log_warn "--dry-run: ничего не изменено"
   exit 0
fi

cp "$TMP" "$CHANGELOG"
git add "$CHANGELOG"
git commit -q -m "release: $VERSION"
git tag -a "v$VERSION" -m "far2l-build $VERSION"

log_info "✅ Создан коммит «release: $VERSION» и тег v$VERSION"
log_info "Опубликовать: git push origin HEAD --tags (GitHub Release создастся автоматически)"
