#!/usr/bin/env bash
# ==========================================================
# Скрипт для сборки и установки far2l из исходников
# Автоматически определяет Ubuntu/Debian и подстраивает зависимости
# ==========================================================

# Выход при любой ошибке, неопределённых переменных или сбое в pipe
set -euo pipefail

# Цвета для удобного чтения лога
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

usage() {
   cat <<USAGE
Использование: sudo $0 [--gui=wx|sdl|both] [--ref=ТЕГ|ВЕТКА] [--python]
                    [--prefix=DIR | -i]
       sudo $0 --uninstall [--prefix=DIR | -i]

  --gui=wx     графический интерфейс на wxWidgets (по умолчанию)
  --gui=sdl    только графический интерфейс на SDL (экспериментальный)
  --gui=both   оба интерфейса: wxWidgets и SDL
  --ref=REF    тег или ветка far2l для сборки, например v_2.9.1 или master
               (по умолчанию — последний стабильный тег v_X.Y.Z)
  --python     собрать плагин Python для расширений far2l на Python
  --prefix=DIR каталог установки (по умолчанию /usr/local)
  -i, --interactive
               спросить каталог установки, подтверждение замены прежней
               установки и удаления пакетов far2l из репозитория
  --uninstall  удалить far2l, установленный этим скриптом (из --prefix или /usr/local)

Повторный запуск переустанавливает far2l: после успешной сборки файлы прежней
установки удаляются по сохранённому списку, затем ставится новая версия.
  -h, --help   показать эту справку
USAGE
}

# ----------------------------------------------------------
# 0. Разбор аргументов (до проверки root, чтобы --help работал без sudo)
# ----------------------------------------------------------
GUI="wx"
REF=""
USE_PYTHON=no
DEFAULT_PREFIX="/usr/local"
INSTALL_PREFIX=""
INTERACTIVE=no
ACTION=install

# Проверяет и нормализует путь установки: только абсолютный путь, без «/» в конце
normalize_prefix() {
   local path="$1"
   while [[ "$path" == */ && "$path" != / ]]; do
      path="${path%/}"
   done
   if [[ "$path" != /* ]]; then
      log_error "Путь установки должен быть абсолютным (начинаться с /): $1"
      return 1
   fi
   if [[ "$path" == / ]]; then
      log_error "Нельзя устанавливать в корень файловой системы, укажите каталог, например /opt/far2l"
      return 1
   fi
   echo "$path"
}
while [[ $# -gt 0 ]]; do
   case "$1" in
      --gui=*) GUI="${1#--gui=}" ;;
      --gui)
         if [[ $# -lt 2 ]]; then
            log_error "Не указано значение для --gui"
            exit 1
         fi
         GUI="$2"
         shift
         ;;
      --ref=*) REF="${1#--ref=}" ;;
      --ref)
         if [[ $# -lt 2 ]]; then
            log_error "Не указано значение для --ref"
            exit 1
         fi
         REF="$2"
         shift
         ;;
      --python) USE_PYTHON=yes ;;
      --prefix=*) INSTALL_PREFIX=$(normalize_prefix "${1#--prefix=}") || exit 1 ;;
      --prefix)
         if [[ $# -lt 2 ]]; then
            log_error "Не указано значение для --prefix"
            exit 1
         fi
         INSTALL_PREFIX=$(normalize_prefix "$2") || exit 1
         shift
         ;;
      -i|--interactive) INTERACTIVE=yes ;;
      --uninstall) ACTION=uninstall ;;
      -h|--help) usage; exit 0 ;;
      *)
         log_error "Неизвестный аргумент: $1"
         usage >&2
         exit 1
         ;;
   esac
   shift
done

case "$GUI" in
   wx)   USE_WX=yes; USE_SDL=no ;;
   sdl)  USE_WX=no;  USE_SDL=yes ;;
   both) USE_WX=yes; USE_SDL=yes ;;
   *)
      log_error "Недопустимое значение --gui: $GUI (ожидается wx, sdl или both)"
      exit 1
      ;;
esac

# ----------------------------------------------------------
# 1. Проверка прав root
# ----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
   log_error "Скрипт должен быть запущен с правами root (используйте sudo)"
   exit 1
fi

# Выбор пути установки: спрашиваем только с -i, иначе — --prefix или /usr/local
if [[ "$INTERACTIVE" == yes ]]; then
   if [[ ! -t 0 ]]; then
      log_error "Для -i/--interactive нужен терминал; без него используйте --prefix=DIR"
      exit 1
   fi
   default="${INSTALL_PREFIX:-$DEFAULT_PREFIX}"
   while true; do
      read -r -p "Путь установки far2l [$default]: " answer
      if INSTALL_PREFIX=$(normalize_prefix "${answer:-$default}"); then
         break
      fi
   done
fi
INSTALL_PREFIX="${INSTALL_PREFIX:-$DEFAULT_PREFIX}"
log_info "Путь установки: $INSTALL_PREFIX"

# Сюда сохраняется список установленных файлов для переустановки и удаления
MANIFEST_DIR="$INSTALL_PREFIX/share/far2l-build"
MANIFEST="$MANIFEST_DIR/install_manifest.txt"

# Вопрос «да/нет» (только в режиме -i); $2 — ответ по умолчанию: y или n
ask_yes_no() {
   local hint answer
   if [[ "$2" == y ]]; then hint="Y/n"; else hint="y/N"; fi
   while true; do
      read -r -p "$1 [$hint]: " answer
      case "${answer:-$2}" in
         [yYдД]*) return 0 ;;
         [nNнН]*) return 1 ;;
      esac
   done
}

# Удаляет far2l по списку установленных файлов из каталога $1.
# Удаляются только пути внутри $1, из каталогов — только пустые с «far2l» в пути
uninstall_far2l() {
   local prefix="$1"
   local manifest="$prefix/share/far2l-build/install_manifest.txt"
   local file dir removed=0 skipped=0
   local -a dirs=()

   while IFS= read -r file || [[ -n "$file" ]]; do
      [[ -z "$file" ]] && continue
      if [[ "$file" != "$prefix"/* || "$file" == *"/../"* || "$file" == */.. ]]; then
         log_warn "Пропущен путь вне $prefix: $file"
         skipped=$((skipped + 1))
         continue
      fi
      if [[ -f "$file" || -L "$file" ]]; then
         rm -f -- "$file"
         removed=$((removed + 1))
      fi
      dirs+=("$(dirname "$file")")
   done < "$manifest"
   rm -f -- "$manifest"
   dirs+=("$prefix/share/far2l-build")

   # Обратная сортировка ставит вложенные каталоги раньше родительских;
   # общие каталоги вроде share/applications не трогаем
   while IFS= read -r dir; do
      while [[ "$dir" == "$prefix"/* && "/${dir#"$prefix"/}" == */far2l* ]]; do
         rmdir -- "$dir" 2>/dev/null || break
         dir=$(dirname "$dir")
      done
   done < <(printf '%s\n' "${dirs[@]}" | sort -ru)

   log_info "Удалено файлов: $removed"
   if [[ $skipped -gt 0 ]]; then
      log_warn "Пропущено подозрительных путей: $skipped"
   fi
}

if [[ "$ACTION" == uninstall ]]; then
   if [[ ! -f "$MANIFEST" ]]; then
      log_error "В $INSTALL_PREFIX нет списка файлов far2l: $MANIFEST"
      if [[ -e "$INSTALL_PREFIX/bin/far2l" ]]; then
         log_error "far2l там есть, но установлен не этим скриптом или его версией до 1.1.0 — удалите его вручную"
      fi
      exit 1
   fi
   if [[ "$INTERACTIVE" == yes ]] && ! ask_yes_no "Удалить far2l из $INSTALL_PREFIX?" n; then
      log_warn "Удаление отменено"
      exit 0
   fi
   log_info "Удаление far2l из $INSTALL_PREFIX..."
   uninstall_far2l "$INSTALL_PREFIX"
   log_info "✅ far2l удалён. Настройки в ~/.config/far2l не тронуты"
   exit 0
fi

# ----------------------------------------------------------
# 2. Определение ОС и выбор зависимостей
# ----------------------------------------------------------
log_info "Определение операционной системы..."
# Поддерживаются только системы с apt
if ! command -v apt-get >/dev/null 2>&1; then
   log_error "apt-get не найден. Скрипт поддерживает только Debian/Ubuntu-подобные системы."
   if [[ -e /etc/gentoo-release ]]; then
      log_info "Для Gentoo используйте ebuild из каталога gentoo/ этого репозитория (см. gentoo/README.md)"
   fi
   exit 1
fi

# Читаем стандартный файл идентификации дистрибутива (VERSION_ID может отсутствовать, например в Debian sid)
if [[ -r /etc/os-release ]]; then
   # shellcheck source=/dev/null
   . /etc/os-release
fi
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
log_info "Обнаружено: $OS_ID $OS_VERSION${ID_LIKE:+ (на базе: $ID_LIKE)}"

# Базовые зависимости (одинаковы для всех поддерживаемых систем)
COMMON_DEPS=(
   libx11-dev libxi-dev libxml2-dev libuchardet-dev
   libssh-dev libssl-dev libsmbclient-dev libnfs-dev
   libneon27-dev libarchive-dev
   cmake pkg-config g++ git
)

# Зависимости графического интерфейса на SDL (только для --gui=sdl|both)
SDL_DEPS=(libsdl2-dev libfreetype-dev libharfbuzz-dev libfontconfig-dev)

# Зависимости плагина Python (только для --python): cffi нужен far2l во время работы
PYTHON_DEPS=(python3-dev python3-cffi)

# Печатает первый пакет из списка, который есть в репозиториях
first_available() {
   local pkg
   for pkg in "$@"; do
      if apt-cache show "$pkg" >/dev/null 2>&1; then
         echo "$pkg"
         return 0
      fi
   done
   return 1
}

# ----------------------------------------------------------
# 3. Установка зависимостей
# ----------------------------------------------------------
# Прежняя установка этим скриптом в тот же каталог заменяется после успешной сборки
REPLACE_OLD=no
if [[ -f "$MANIFEST" ]]; then
   log_info "Найдена установка far2l в $INSTALL_PREFIX: после успешной сборки она будет заменена"
   if [[ "$INTERACTIVE" == yes ]] && ! ask_yes_no "Заменить установленный far2l?" y; then
      log_warn "Установка отменена"
      exit 0
   fi
   REPLACE_OLD=yes
elif [[ -e "$INSTALL_PREFIX/bin/far2l" ]]; then
   log_warn "В $INSTALL_PREFIX уже есть far2l без списка файлов: новые файлы запишутся поверх, устаревшие останутся"
fi

# Пакеты far2l из репозитория дистрибутива ставят свою копию в /usr/bin
mapfile -t APT_FAR2L < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'far2l*' 2>/dev/null \
   | awk '$1 == "installed" {print $2}')
REMOVE_APT=no
if [[ ${#APT_FAR2L[@]} -gt 0 ]]; then
   log_warn "Установлены пакеты far2l из репозитория: ${APT_FAR2L[*]}"
   if [[ "$INTERACTIVE" == yes ]] && ask_yes_no "Удалить их после успешной сборки?" n; then
      REMOVE_APT=yes
   else
      log_warn "Две копии far2l будут мешать друг другу. Удалить пакеты: sudo apt-get remove ${APT_FAR2L[*]}"
   fi
fi

export DEBIAN_FRONTEND=noninteractive

log_info "Обновление списков пакетов..."
apt-get update

DEPS=("${COMMON_DEPS[@]}")

# Выбор пакета wxWidgets по фактическому наличию в репозиториях,
# а не по имени дистрибутива: работает и для Mint, Pop!_OS и т.п.
if [[ "$USE_WX" == yes ]]; then
   if ! WX_PKG=$(first_available libwxgtk3.2-dev libwxgtk3.0-gtk3-dev); then
      log_error "В репозиториях не найден пакет wxWidgets (libwxgtk3.2-dev / libwxgtk3.0-gtk3-dev)"
      exit 1
   fi
   log_info "Выбран пакет wxWidgets: $WX_PKG"
   DEPS+=("$WX_PKG")
fi

if [[ "$USE_SDL" == yes ]]; then
   log_info "Добавлены зависимости для SDL: ${SDL_DEPS[*]}"
   DEPS+=("${SDL_DEPS[@]}")
fi

if [[ "$USE_PYTHON" == yes ]]; then
   log_info "Добавлены зависимости для плагина Python: ${PYTHON_DEPS[*]}"
   DEPS+=("${PYTHON_DEPS[@]}")
fi

# 7-Zip не нужен для сборки, но используется far2l для работы с архивами (multiarc/arclite)
if SEVENZIP_PKG=$(first_available 7zip p7zip-full); then
   log_info "Выбран пакет 7-Zip: $SEVENZIP_PKG"
   DEPS+=("$SEVENZIP_PKG")
else
   log_warn "Пакет 7-Zip (7zip / p7zip-full) не найден в репозиториях, поддержка архивов будет ограничена"
fi

log_info "Установка зависимостей для сборки..."
apt-get install -y "${DEPS[@]}"

# ----------------------------------------------------------
# 4. Подготовка рабочей директории
# ----------------------------------------------------------
GIT_REPO="https://github.com/elfmz/far2l.git"
# Сборка идёт от обычного пользователя: root нужен только для apt и установки.
# При запуске через sudo это тот, кто вызвал sudo, иначе — nobody
BUILD_USER="${SUDO_USER:-}"
if [[ -z "$BUILD_USER" || "$BUILD_USER" == root ]]; then
   BUILD_USER="nobody"
fi
if ! id "$BUILD_USER" >/dev/null 2>&1; then
   log_error "Пользователь для сборки не найден: $BUILD_USER"
   exit 1
fi
if ! command -v runuser >/dev/null 2>&1; then
   log_error "Не найдена команда runuser (пакет util-linux)"
   exit 1
fi

# mktemp создаёт каталог с непредсказуемым именем и правами 0700;
# владельцем делаем пользователя сборки, права 0700 сохраняются
BUILD_DIR=$(mktemp -d /tmp/far2l-build.XXXXXXXXXX)
SRC_DIR="$BUILD_DIR/far2l"
log_info "Создана временная директория сборки: $BUILD_DIR"

# Удаляем временные файлы при любом завершении, в том числе при ошибке
cleanup() {
   local rc=$?
   log_info "Очистка временных файлов сборки..."
   rm -rf "$BUILD_DIR"
   if [[ $rc -ne 0 ]]; then
      log_error "Установка прервана с ошибкой (код $rc)"
   fi
}
trap cleanup EXIT

chown "$BUILD_USER:" "$BUILD_DIR"
log_info "Сборка будет выполняться от пользователя: $BUILD_USER"

# HOME указывает в каталог сборки: у nobody своего HOME нет,
# а git не должен читать настройки из /root
as_build_user() {
   runuser -u "$BUILD_USER" -- env HOME="$BUILD_DIR" "$@"
}

# ----------------------------------------------------------
# 5. Клонирование репозитория
# ----------------------------------------------------------
# По умолчанию — последний стабильный тег: авторы far2l считают master нестабильным
if [[ -z "$REF" ]]; then
   REF=$(git ls-remote --tags --refs "$GIT_REPO" 'v_*' \
      | sed -n 's#.*refs/tags/\(v_[0-9]\+\.[0-9]\+\.[0-9]\+\)$#\1#p' \
      | sort -V | tail -n 1)
   if [[ -z "$REF" ]]; then
      log_error "Не удалось определить последний стабильный тег far2l"
      exit 1
   fi
   log_info "Версия far2l: $REF (последний стабильный тег)"
else
   log_info "Версия far2l: $REF (задано через --ref)"
fi

log_info "Клонирование исходного кода far2l..."
as_build_user git clone --depth 1 --branch "$REF" "$GIT_REPO" "$SRC_DIR"

# ----------------------------------------------------------
# 6. Конфигурация и сборка через CMake
# ----------------------------------------------------------
log_info "Конфигурация проекта через CMake..."

# -DUSEWX включает графический интерфейс на wxWidgets
# -DUSESDL включает графический интерфейс на SDL
# -DPYTHON включает плагин Python
# -DCMAKE_BUILD_TYPE=Release собирает оптимизированную версию
log_info "Графический интерфейс: $GUI (USEWX=$USE_WX, USESDL=$USE_SDL), плагин Python: $USE_PYTHON"
as_build_user cmake -S "$SRC_DIR" -B "$SRC_DIR/_build" \
   -DUSEWX="$USE_WX" -DUSESDL="$USE_SDL" -DPYTHON="$USE_PYTHON" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"

# Определяем количество ядер для параллельной сборки
CORES=$(nproc || echo 4)
log_info "Сборка far2l (используется $CORES потоков)..."
as_build_user cmake --build "$SRC_DIR/_build" -j"$CORES"

# ----------------------------------------------------------
# 7. Установка в систему
# ----------------------------------------------------------
# Прежнюю версию убираем только сейчас: если сборка упала, far2l у пользователя остаётся
if [[ "$REPLACE_OLD" == yes ]]; then
   log_info "Удаление предыдущей установки far2l из $INSTALL_PREFIX..."
   uninstall_far2l "$INSTALL_PREFIX"
fi
if [[ "$REMOVE_APT" == yes ]]; then
   log_info "Удаление пакетов far2l из репозитория: ${APT_FAR2L[*]}"
   apt-get remove -y "${APT_FAR2L[@]}"
fi

# Установка — единственный шаг сборки, которому нужен root
log_info "Установка far2l в систему ($INSTALL_PREFIX)..."
cmake --install "$SRC_DIR/_build"

# Сохраняем список установленных файлов: каталог сборки будет удалён,
# а без манифеста far2l потом нельзя чисто удалить
mkdir -p "$MANIFEST_DIR"
cp "$SRC_DIR/_build/install_manifest.txt" "$MANIFEST"
log_info "Список установленных файлов: $MANIFEST"

# ----------------------------------------------------------
# 8. Завершение (временные файлы удалит cleanup по trap EXIT)
# ----------------------------------------------------------
log_info "✅ Установка завершена успешно!"
if [[ "$GUI" == sdl ]]; then
   log_info "Для запуска введите: far2l --SDL"
elif [[ "$GUI" == both ]]; then
   log_info "Для запуска введите: far2l (wxWidgets) или far2l --SDL (SDL)"
else
   log_info "Для запуска введите: far2l"
fi
# Нестандартный путь: подсказываем, как сделать far2l доступным из PATH
if [[ ":$PATH:" != *":$INSTALL_PREFIX/bin:"* ]]; then
   log_warn "Каталог $INSTALL_PREFIX/bin не входит в PATH. Добавьте в ~/.profile:"
   log_warn "   export PATH=\"$INSTALL_PREFIX/bin:\$PATH\""
   log_warn "или запускайте far2l по полному пути: $INSTALL_PREFIX/bin/far2l"
fi
# Другая копия far2l раньше в PATH будет запускаться вместо новой
hash -r
FIRST_FAR2L=$(type -P far2l || true)
if [[ -n "$FIRST_FAR2L" && "$FIRST_FAR2L" != "$INSTALL_PREFIX/bin/far2l" ]]; then
   log_warn "Команда far2l сейчас запускает другую копию: $FIRST_FAR2L"
   OTHER_PREFIX=$(dirname "$(dirname "$FIRST_FAR2L")")
   if [[ -f "$OTHER_PREFIX/share/far2l-build/install_manifest.txt" ]]; then
      log_warn "Её установил этот скрипт. Удалить: sudo $0 --uninstall --prefix=$OTHER_PREFIX"
   elif OTHER_PKG=$(dpkg -S "$FIRST_FAR2L" 2>/dev/null); then
      log_warn "Она из пакета ${OTHER_PKG%%:*}. Удалить: sudo apt-get remove ${OTHER_PKG%%:*}"
   fi
fi

# Ярлыки и иконки окружение рабочего стола ищет в XDG_DATA_DIRS
# (по умолчанию /usr/local/share:/usr/share), нестандартный DIR/share туда не входит
DESKTOP_FILES=("$INSTALL_PREFIX"/share/applications/far2l*.desktop)
if [[ -e "${DESKTOP_FILES[0]}" && ":${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:" != *":$INSTALL_PREFIX/share:"* ]]; then
   log_warn "Ярлыки far2l установлены в $INSTALL_PREFIX/share/applications и не появятся в меню."
   log_warn "Чтобы они появились, добавьте в ~/.profile и перезайдите в сеанс:"
   log_warn "   export XDG_DATA_DIRS=\"$INSTALL_PREFIX/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\""
fi
if [[ "$USE_PYTHON" == yes ]]; then
   log_info "Свои Python-плагины кладите в ~/.config/far2l/plugins/python"
   log_info "Примеры и описание: $INSTALL_PREFIX/share/far2l/Plugins/python/plugins"
fi
