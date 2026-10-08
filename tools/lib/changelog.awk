# ==========================================================
# Работа с разделом [Unreleased] в Changelog.md (формат Keep a Changelog)
#
#   -v mode=add -v section="### Добавлено" -v entry="- текст"
#       добавить пункт в подраздел (подраздел создаётся, если его нет)
#   -v mode=release -v version=X.Y.Z -v date=YYYY-MM-DD
#       перенести всё из [Unreleased] в новый раздел [X.Y.Z] - дата
#
# Подраздел «### Запланировано» всегда остаётся в [Unreleased].
# Коды выхода: 3 — в [Unreleased] нечего выпускать, 4 — нет раздела [Unreleased]
# ==========================================================

function trim(s) {
    sub(/(\n[ \t]*)+$/, "", s)
    return s
}

function out_block(name) {
    print name
    if (body[name] != "") print body[name]
    print ""
}

function print_preamble() {
    if (preamble != "") {
        print preamble
        print ""
    }
}

function emit(    i, name, has_release) {
    for (i = 1; i <= n; i++) body[order[i]] = trim(body[order[i]])

    print "## [Unreleased]"
    print ""
    print_preamble()

    if (mode == "add") {
        if (!(section in body)) body[section] = ""
        body[section] = (body[section] == "") ? entry : body[section] "\n" entry
        # Новый пункт — в начало: порядок подразделов как в Keep a Changelog
        out_block(section)
        for (i = 1; i <= n; i++) {
            name = order[i]
            if (name != section && name != PLANNED) out_block(name)
        }
        if (PLANNED in body) out_block(PLANNED)
        return
    }

    # mode == "release"
    has_release = 0
    for (i = 1; i <= n; i++)
        if (order[i] != PLANNED && body[order[i]] != "") has_release = 1
    if (!has_release) {
        failed = 1
        return
    }

    if (PLANNED in body) out_block(PLANNED)
    print "## [" version "] - " date
    print ""
    for (i = 1; i <= n; i++) {
        name = order[i]
        if (name != PLANNED && body[name] != "") out_block(name)
    }
}

BEGIN {
    PLANNED = "### Запланировано"
    state = 0      # 0 — до [Unreleased], 1 — внутри, 2 — после
    n = 0
    cur = ""
    preamble = ""
}

state == 0 && /^## \[Unreleased\]/ { state = 1; next }

state == 1 && /^## \[/ { emit(); state = 2 }

state == 1 {
    if (/^### /) {
        cur = $0
        if (!(cur in body)) { order[++n] = cur; body[cur] = "" }
    } else if (cur == "") {
        if ($0 !~ /^[ \t]*$/) preamble = (preamble == "") ? $0 : preamble "\n" $0
    } else if (!(body[cur] == "" && $0 ~ /^[ \t]*$/)) {
        body[cur] = (body[cur] == "") ? $0 : body[cur] "\n" $0
    }
    next
}

{ print }

END {
    if (state == 1) emit()
    if (state == 0) exit 4
    if (failed) exit 3
}
