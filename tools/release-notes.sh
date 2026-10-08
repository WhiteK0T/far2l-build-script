#!/usr/bin/env bash
# ==========================================================
# Печатает текст GitHub Release для версии X.Y.Z:
# раздел [X.Y.Z] из Changelog.md и ссылку на сравнение с прошлой версией
# ==========================================================

set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
   echo "Использование: $0 X.Y.Z" >&2
   exit 1
fi
VERSION="${1#v}"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHANGELOG="$REPO_ROOT/Changelog.md"

# Содержимое раздела без заголовка, без пустых строк в начале и в конце
NOTES=$(awk -v hdr="## [$VERSION]" '
   index($0, hdr) == 1 { p = 1; next }
   p && /^## \[/ { exit }
   p
' "$CHANGELOG" | sed -e '/./,$!d')
NOTES=$(printf '%s\n' "$NOTES" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
if [[ -z "$NOTES" ]]; then
   echo "В Changelog.md нет раздела [$VERSION] или он пуст" >&2
   exit 1
fi

# owner/repo: из GitHub Actions или из адреса origin (ssh или https)
REPO="${GITHUB_REPOSITORY:-}"
if [[ -z "$REPO" ]]; then
   REPO=$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
fi

# Предыдущая версия — ближайший меньший тег vX.Y.Z
PREV=$(git -C "$REPO_ROOT" tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
   | { cat; echo "v$VERSION"; } | sort -uV | grep -B1 -x "v$VERSION" | grep -vx "v$VERSION" || true)

printf '%s\n\n' "$NOTES"
if [[ -n "$PREV" ]]; then
   echo "**Все изменения:** https://github.com/$REPO/compare/$PREV...v$VERSION"
else
   echo "**Исходный код:** https://github.com/$REPO/tree/v$VERSION"
fi
