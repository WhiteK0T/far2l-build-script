# Оверлей far2l для Gentoo

Локальный оверлей с ebuild для `app-misc/far2l`. В отличие от `far-build.sh`, сборку и зависимости ведёт Portage: он сам пересобирает far2l при обновлении библиотек и удаляет его через `emerge -C`.

## Подключение
```bash
# 1. Клонировать репозиторий
sudo git clone https://github.com/WhiteK0T/far2l-build-script.git /var/db/repos/far2l-build-script

# 2. Подключить каталог gentoo/ как оверлей
sudo tee /etc/portage/repos.conf/far2l-build.conf <<'EOF'
[far2l-build]
location = /var/db/repos/far2l-build-script/gentoo
auto-sync = no
EOF
```
Обновление ebuild: `sudo git -C /var/db/repos/far2l-build-script pull`.

## Установка
```bash
# Релиз (ebuild помечен ~amd64)
echo "app-misc/far2l ~amd64" | sudo tee /etc/portage/package.accept_keywords/far2l
sudo emerge -av app-misc/far2l

# Или последняя версия из git master (нестабильная)
echo "=app-misc/far2l-9999 **" | sudo tee /etc/portage/package.accept_keywords/far2l
sudo emerge -av =app-misc/far2l-9999
```

## USE-флаги
| Флаг | По умолчанию | Что включает |
|------|:---:|--------------|
| `wxwidgets` | ✅ | Графический интерфейс на wxWidgets (`x11-libs/wxGTK:3.2-gtk3[X]`) |
| `sdl` | — | Экспериментальный графический интерфейс на SDL, запуск `far2l --SDL` |
| `X` | ✅ | Расширения X11/Xi для терминального режима (клавиатура, буфер обмена) |
| `uchardet` | ✅ | Автоопределение кодировки |
| `ssh` | ✅ | NetRocks: SFTP/SCP |
| `samba` | ✅ | NetRocks: SMB |
| `nfs` | ✅ | NetRocks: NFS |
| `webdav` | ✅ | NetRocks: WebDAV (вместе с `ssl` — ещё и AWS S3) |
| `ssl` | ✅ | NetRocks: FTPS (вместе с `webdav` — ещё и AWS S3) |
| `mtp` | ✅ | Плагин MTP для телефонов и плееров |

Пример: только SDL, без wxWidgets и Samba:
```bash
echo "app-misc/far2l sdl -wxwidgets -samba" | sudo tee /etc/portage/package.use/far2l
```

## Обновление до новых версий far2l
Раз в сутки GitHub Actions ([`.github/workflows/far2l-bump.yml`](../.github/workflows/far2l-bump.yml)) проверяет теги far2l. Если вышла новая версия, workflow создаёт ebuild, добавляет архив в `Manifest` и открывает PR с изменениями CMake-файлов между версиями. Перед мержем PR стоит проверить: новые опции или зависимости far2l нужно перенести в ebuild.

Проверить и обновить локально можно тем же скриптом:
```bash
./tools/bump-far2l-ebuild.sh --check   # код выхода 2 — вышла новая версия
./tools/bump-far2l-ebuild.sh --bump    # создать ebuild и обновить Manifest
```

Для работы с архивами рекомендуется `app-arch/7zip`. Плагин Python пока не поддерживается.
