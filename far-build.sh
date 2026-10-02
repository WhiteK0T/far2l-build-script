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
Использование: sudo $0 [--gui=wx|sdl|both]

  --gui=wx     графический интерфейс на wxWidgets (по умолчанию)
  --gui=sdl    только графический интерфейс на SDL (экспериментальный)
  --gui=both   оба интерфейса: wxWidgets и SDL
  -h, --help   показать эту справку
USAGE
}

# ----------------------------------------------------------
# 0. Разбор аргументов (до проверки root, чтобы --help работал без sudo)
# ----------------------------------------------------------
GUI="wx"
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

# ----------------------------------------------------------
# 2. Определение ОС и выбор зависимостей
# ----------------------------------------------------------
log_info "Определение операционной системы..."
# Поддерживаются только системы с apt
if ! command -v apt-get >/dev/null 2>&1; then
   log_error "apt-get не найден. Скрипт поддерживает только Debian/Ubuntu-подобные системы."
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
INSTALL_PREFIX="/usr/local"
# Сюда сохраняется список установленных файлов для последующего удаления
MANIFEST_DIR="$INSTALL_PREFIX/share/far2l-build"

# mktemp создаёт каталог с непредсказуемым именем и правами 0700
BUILD_DIR=$(mktemp -d /tmp/far2l-build.XXXXXXXXXX)
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

# ----------------------------------------------------------
# 5. Клонирование репозитория
# ----------------------------------------------------------
log_info "Клонирование исходного кода far2l..."
git clone --depth 1 "$GIT_REPO" "$BUILD_DIR"

# ----------------------------------------------------------
# 6. Конфигурация и сборка через CMake
# ----------------------------------------------------------
log_info "Конфигурация проекта через CMake..."
cd "$BUILD_DIR"
mkdir -p _build
cd _build

# -DUSEWX включает графический интерфейс на wxWidgets
# -DUSESDL включает графический интерфейс на SDL
# -DCMAKE_BUILD_TYPE=Release собирает оптимизированную версию
log_info "Графический интерфейс: $GUI (USEWX=$USE_WX, USESDL=$USE_SDL)"
cmake -DUSEWX="$USE_WX" -DUSESDL="$USE_SDL" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" ..

# Определяем количество ядер для параллельной сборки
CORES=$(nproc || echo 4)
log_info "Сборка far2l (используется $CORES потоков)..."
cmake --build . -j"$CORES"

# ----------------------------------------------------------
# 7. Установка в систему
# ----------------------------------------------------------
log_info "Установка far2l в систему ($INSTALL_PREFIX)..."
cmake --install .

# Сохраняем список установленных файлов: каталог сборки будет удалён,
# а без манифеста far2l потом нельзя чисто удалить
mkdir -p "$MANIFEST_DIR"
cp install_manifest.txt "$MANIFEST_DIR/install_manifest.txt"
log_info "Список установленных файлов: $MANIFEST_DIR/install_manifest.txt"

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
