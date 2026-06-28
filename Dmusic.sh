#!/usr/bin/env bash
# ==========================================
# ДІДО-КАЧАТОР 4000 PRO MAX (Arch Edition, Reliable Build)
# ==========================================
set -uo pipefail

# ---------- Налаштування ----------
WORK_ROOT="$HOME/Music"
TMP_PREFIX="didokachator"

# ---------- Допоміжні функції ----------

log()  { echo -e "$1"; }
fail() { echo "ПОМИЛКА: $1" >&2; exit 1; }

# Перевірка залежностей
check_deps() {
    local missing=()
    for cmd in yt-dlp ffmpeg curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Бракує наступних утиліт: ${missing[*]}"
        echo "Встанови їх командою:"
        echo "  sudo pacman -S ${missing[*]}"
        echo "(якщо yt-dlp немає в офіційних репо — sudo pacman -S yt-dlp, або через AUR: yt-dlp-git)"
        exit 1
    fi
}

# Очищення тимчасових файлів (викликається завжди при виході)
cleanup() {
    [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Безпечна нормалізація імені файлу/папки (зберігає кирилицю, прибирає тільки небезпечні символи)
sanitize_name() {
    local name="$1"
    name=$(echo "$name" | tr ' ' '_')
    name=$(echo "$name" | tr -d "'\"\`\$\\\\/:*?\"<>|")
    echo "$name"
}

# Отримати назву Spotify-об'єкта без авторизації (публічний oEmbed)
get_spotify_title() {
    local url="$1"
    local json title
    json=$(curl -s "https://open.spotify.com/oembed?url=${url}")
    [ -z "$json" ] && fail "Не вдалося звʼязатися з Spotify oEmbed (перевір інтернет)."
    title=$(echo "$json" | jq -r '.title // empty')
    [ -z "$title" ] && fail "Spotify не повернув назву. Можливо, посилання некоректне."
    echo "$title"
}

# Завантажити один трек за назвою через пошук на YouTube (без офіційного API)
# index — порядковий номер треку в плейлисті, додається як префікс до імені файлу,
# щоб після склеювання порядок треків точно відповідав оригінальному плейлисту
# (звичайне алфавітне сортування імен файлів з YouTube цього не гарантує).
download_by_search() {
    local query="$1"
    local outdir="$2"
    local index="${3:-0}"
    local prefix
    prefix=$(printf "%03d" "$index")
    log "==> Шукаю на YouTube: $query"

    local attempt max_attempts=3
    for attempt in 1 2 3; do
        if yt-dlp \
            --no-playlist \
            --default-search "ytsearch1" \
            --format "bestaudio/best" \
            --extract-audio --audio-format mp3 \
            --output "${outdir}/${prefix}_%(title)s.%(ext)s" \
            -- "$query"; then
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            log "    [спроба $attempt не вдалась (можливо, тимчасовий 403 від YouTube), повтор через 3с...]"
            sleep 3
        fi
    done

    log "    [пропускаю: не вдалося знайти/завантажити '$query' після $max_attempts спроб]"
}

# Завантажити пряме YouTube-посилання (відео або плейлист)
download_youtube_url() {
    local url="$1"
    local outdir="$2"
    log "==> Бачу YouTube. Качаю напряму..."
    yt-dlp \
        --ignore-errors \
        --format "bestaudio/best" \
        --extract-audio --audio-format mp3 \
        --output "${outdir}/%(playlist_index|1)03d_%(title)s.%(ext)s" \
        "$url"
}

# Безпечне склеювання всіх mp3 у папці в один файл (екранує апострофи/пробіли коректно для ffmpeg concat)
merge_mp3_files() {
    local dir="$1"
    local list_file="$2"
    local out_file="$3"

    > "$list_file"
    # find -print0 + read -d '' — єдиний надійний спосіб обробити імена з пробілами/апострофами/кирилицею
    while IFS= read -r -d '' f; do
        # ВАЖЛИВО: пишемо ПОВНИЙ абсолютний шлях, бо list_file лежить в іншій
        # тимчасовій папці (TMP_DIR), а не поряд із самими mp3 — ffmpeg шукає
        # відносні шляхи відносно розташування list.txt, а не поточної директорії.
        local abs_path
        abs_path=$(realpath "$f")
        local escaped="${abs_path//\'/\'\\\'\'}"
        printf "file '%s'\n" "$escaped" >> "$list_file"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.mp3' -print0 | sort -z)

    [ -s "$list_file" ] || fail "Жодного mp3-файлу не знайдено для склеювання."

    local ffmpeg_err
    ffmpeg_err=$(ffmpeg -y -f concat -safe 0 -i "$list_file" -c copy "$out_file" 2>&1 >/dev/null)
    if [ $? -ne 0 ]; then
        echo "---- Деталі помилки ffmpeg ----" >&2
        echo "$ffmpeg_err" >&2
        echo "--------------------------------" >&2
        fail "ffmpeg не зміг склеїти файли (деталі вище)."
    fi
}

# Отримати анонімний тимчасовий токен з open.spotify.com (так само, як це робить сам веб-плеєр
# для відображення сторінки — без логіну, без client_id/secret розробника).
get_anonymous_spotify_token() {
    local resp token
    resp=$(curl -s "https://open.spotify.com/get_access_token?reason=transport&productType=web_player")
    token=$(echo "$resp" | jq -r '.accessToken // empty' 2>/dev/null)
    echo "$token"
}

# Витягнути тип (playlist/album/track) та ID з Spotify-URL
parse_spotify_url() {
    local url="$1"
    if [[ "$url" =~ /playlist/([a-zA-Z0-9]+) ]]; then
        echo "playlist:${BASH_REMATCH[1]}"
    elif [[ "$url" =~ /album/([a-zA-Z0-9]+) ]]; then
        echo "album:${BASH_REMATCH[1]}"
    elif [[ "$url" =~ /track/([a-zA-Z0-9]+) ]]; then
        echo "track:${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# Отримати повний трек-лист плейлиста/альбому через публічний api.spotify.com/v1
# (тільки публічні дані, без приватного акаунту користувача).
get_spotify_playlist_tracks() {
    local kind_id="$1"
    local token="$2"
    local kind="${kind_id%%:*}"
    local id="${kind_id##*:}"
    local url resp next

    if [ "$kind" == "playlist" ]; then
        url="https://api.spotify.com/v1/playlists/${id}/tracks?fields=items(track(name,artists(name))),next&limit=100"
    elif [ "$kind" == "album" ]; then
        url="https://api.spotify.com/v1/albums/${id}/tracks?limit=50"
    else
        return 1
    fi

    while [ -n "$url" ] && [ "$url" != "null" ]; do
        resp=$(curl -s -H "Authorization: Bearer ${token}" "$url")

        if [ "$kind" == "playlist" ]; then
            echo "$resp" | jq -r '.items[]? | select(.track != null) | "\(.track.artists[0].name) - \(.track.name)"'
            next=$(echo "$resp" | jq -r '.next // empty')
        else
            echo "$resp" | jq -r '.items[]? | "\(.artists[0].name) - \(.name)"'
            next=$(echo "$resp" | jq -r '.next // empty')
        fi

        url="$next"
    done
}

# Резервний метод №2: витягнути трек-лист просто з HTML-сторінки плейлиста
# (без жодного API/токена). Spotify вшиває JSON зі станом сторінки прямо в HTML,
# щоб їхній фронтенд міг намалювати список треків без додаткового запиту.
# Метод крихкий (ламається, якщо Spotify змінить структуру сторінки),
# тому використовується тільки якщо метод з API-токеном не спрацював.
get_spotify_tracks_html_scrape() {
    local url="$1"
    local exclude_title="${2:-}"
    local html

    html=$(curl -sL \
        -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
        "$url")

    [ -z "$html" ] && return 1

    # Спроба №1: знайти пари "артист ... назва треку" у JSON-блоці сторінки.
    # Шаблон ловить шматки виду:  "artists":[{"name":"АРТИСТ" ... "name":"ТРЕК"
    # Це не ідеальний парсер JSON, а прицільний regex саме під структуру Spotify-плейлиста.
    local pairs
    pairs=$(echo "$html" | grep -oP '"artists":\[\{"name":"[^"]+".*?"name":"[^"]+"(?=,"album")' 2>/dev/null \
        | grep -oP '"name":"[^"]+"' \
        | cut -d'"' -f4)

    if [ -n "$pairs" ]; then
        # Парні рядки: артист, трек, артист, трек...
        local artist track
        echo "$pairs" | paste -d'|' - - | while IFS='|' read -r artist track; do
            [ -n "$artist" ] && [ -n "$track" ] && echo "${artist} - ${track}"
        done
        return 0
    fi

    # Спроба №2 (грубий fallback, як у дідовому скрипті v3000-regex):
    # просто всі "name":"..." з відсіюванням явного сміття. Без чіткого
    # звʼязку артист/трек, але yt-dlp зазвичай влучає за самою назвою.
    # ВАЖЛИВО: на сторінці Spotify в JSON є список кодів країн
    # (availableMarkets) типу "name":"AD","name":"AE" — це НЕ треки,
    # тому відсіюємо все, що схоже на 2-3-буквений код країни/мови,
    # а також надто короткі/однослівні службові значення.
    echo "$html" | grep -oP '"name":"[^"]+"' \
        | cut -d'"' -f4 \
        | grep -v -E '^[A-Z]{2,3}$' \
        | grep -v -E '^(Spotify|Потужні|Playlist|Premium|Open|spotify:|null|true|false)$' \
        | grep -v -E '^[a-z]{2}-[A-Z]{2}$' \
        | { if [ -n "$exclude_title" ]; then grep -vFx "$exclude_title"; else cat; fi; } \
        | sort -u
}

# Найнадійніший метод: пройти весь плейлист через ВЛАСНИЙ запущений Spotify-клієнт
# користувача (playerctl читає метадані через D-Bus — це твій локальний плеєр,
# у якому ти вже залогінений; жодного скрейпінгу чужих серверів, жодної captcha).
# Вимагає: щоб у користувача був відкритий Spotify-десктоп/веб-клієнт із цим
# плейлистом, і щоб він натиснув Play на першому треці перед запуском.
get_spotify_tracks_via_playerctl() {
    command -v playerctl >/dev/null 2>&1 || return 1
    playerctl --player=spotify status >/dev/null 2>&1 || return 1

    local tmp_list="${TMP_DIR}/playerctl_raw.txt"
    > "$tmp_list"

    echo "" >&2
    echo "==> Знайдено активний Spotify-клієнт." >&2
    echo "==> Переконайся, що в ньому ВІДКРИТО потрібний плейлист і натиснуто Play на ПЕРШІЙ пісні." >&2
    read -p "Готовий? Натисни Enter, щоб почати автоматичне перемикання треків... " _

    local counter=0 prev_track="" dup_count=0
    local first_track
    first_track=$(playerctl --player=spotify metadata --format "{{ artist }} - {{ title }}" 2>/dev/null)

    while true; do
        local current_track
        current_track=$(playerctl --player=spotify metadata --format "{{ artist }} - {{ title }}" 2>/dev/null)

        if [ -z "$current_track" ]; then
            sleep 0.05
            continue
        fi

        # Захист від другого кола плейлиста
        if [ "$current_track" == "$first_track" ] && [ "$counter" -gt 5 ]; then
            echo "" >&2
            echo "==> Коло замкнулося, повернулися до першого треку ($first_track)." >&2
            break
        fi

        # Захист від зависання Spotify на одному треці
        if [ "$current_track" == "$prev_track" ]; then
            dup_count=$((dup_count + 1))
            if [ "$dup_count" -gt 10 ]; then
                echo "" >&2
                echo "==> Spotify завис на одному треці. Зупиняюся." >&2
                break
            fi
        else
            dup_count=0
        fi

        echo "$current_track" >> "$tmp_list"
        counter=$((counter + 1))
        echo "    [$counter] Смикнув: $current_track" >&2

        prev_track="$current_track"
        playerctl --player=spotify next
        sleep 0.1
    done

    # Прибираємо повтори, зберігаючи порядок
    awk '!seen[$0]++' "$tmp_list"
}

# ---------- Початок ----------

check_deps

echo "========================================"
echo "    ДІДІВ МАГНІТОФОН v5.0 (Reliable)     "
echo "========================================"
echo ""

read -p "Встав посилання на плейлист/трек (Spotify або YouTube): " URL
[ -z "$URL" ] && fail "Йой! Ти ж нічого не ввів, гий би його качка копнула."

echo ""
read -p "Як назвемо цей шедевр? " CUSTOM_NAME_RAW
if [ -z "$CUSTOM_NAME_RAW" ]; then
    CUSTOM_NAME_RAW="Mishanya_Mix"
    echo "Нічого не придумав? Ну то буде називатися $CUSTOM_NAME_RAW!"
fi
CUSTOM_NAME=$(sanitize_name "$CUSTOM_NAME_RAW")

echo ""
echo "Як хочеш дістати ту музику?"
echo "1) Одним великим файлом (для платівки в Майнкрафті)"
echo "2) Різними файлами (кожна пісня окремо)"
read -p "Твій вибір (1 або 2): " MODE
[[ "$MODE" =~ ^[12]$ ]] || fail "Треба ввести 1 або 2."

FORMAT_CHOICE=""
if [ "$MODE" == "1" ]; then
    echo ""
    echo "Який формат для склеєного мега-файлу?"
    echo "1) mp3"
    echo "2) ogg (для платівки в Енігматі/Майнкрафті)"
    read -p "Твій вибір (1 або 2): " FORMAT_CHOICE
    [[ "$FORMAT_CHOICE" =~ ^[12]$ ]] || fail "Треба ввести 1 або 2."
fi

WORK_DIR="${WORK_ROOT}/${CUSTOM_NAME}"
mkdir -p "$WORK_DIR" || fail "Не вдалося створити папку $WORK_DIR"

TMP_DIR=$(mktemp -d "/tmp/${TMP_PREFIX}.XXXXXX")
LIST_FILE="${TMP_DIR}/list.txt"
TEMP_FINAL="${TMP_DIR}/temp_final.mp3"

echo ""
echo "==> Запускаємо турбіни..."

if [[ "$URL" == *"spotify.com"* ]]; then
    echo "==> Бачу Spotify."

    if [[ "$URL" == *"/track/"* ]]; then
        TITLE=$(get_spotify_title "$URL")
        echo "==> Знайдено назву треку: $TITLE"
        download_by_search "$TITLE" "$WORK_DIR" 1
    else
        TITLE=$(get_spotify_title "$URL")
        echo "==> Плейлист/альбом: $TITLE"

        TRACKS=()

        echo "==> Пробую метод №1: через твій локальний Spotify-клієнт (playerctl)..."
        while IFS= read -r line; do
            [ -n "$line" ] && TRACKS+=("$line")
        done < <(get_spotify_tracks_via_playerctl)

        if [ "${#TRACKS[@]}" -eq 0 ]; then
            echo "==> playerctl недоступний або Spotify не запущено. Пробую метод №2: API-токен..."
            KIND_ID=$(parse_spotify_url "$URL")
            TOKEN=$(get_anonymous_spotify_token)

            if [ -n "$KIND_ID" ] && [ -n "$TOKEN" ]; then
                while IFS= read -r line; do
                    [ -n "$line" ] && TRACKS+=("$line")
                done < <(get_spotify_playlist_tracks "$KIND_ID" "$TOKEN")
            fi
        fi

        if [ "${#TRACKS[@]}" -eq 0 ]; then
            echo "==> Метод через API не дав результату. Пробую метод №3: HTML-scrape..."
            while IFS= read -r line; do
                [ -n "$line" ] && TRACKS+=("$line")
            done < <(get_spotify_tracks_html_scrape "$URL" "$TITLE")
        fi

        if [ "${#TRACKS[@]}" -eq 0 ]; then
            echo ""
            echo "Не вдалося автоматично дістати трек-лист (Spotify міг змінити механізм видачі токена)."
            echo "Введи список треків вручну — кожен у форматі 'Виконавець - Назва',"
            echo "по одному на рядок. Завершуй введення порожнім рядком."
            echo ""
            while IFS= read -r line; do
                [ -z "$line" ] && break
                TRACKS+=("$line")
            done
            [ "${#TRACKS[@]}" -eq 0 ] && fail "Не введено жодного треку."
        else
            echo "==> Знайдено ${#TRACKS[@]} треків автоматично."
        fi

        i=1
        for t in "${TRACKS[@]}"; do
            download_by_search "$t" "$WORK_DIR" "$i"
            i=$((i + 1))
        done
    fi
else
    download_youtube_url "$URL" "$WORK_DIR"
fi

# Перевірка, що хоч щось завантажилось
shopt -s nullglob
mp3_files=("$WORK_DIR"/*.mp3)
shopt -u nullglob
[ "${#mp3_files[@]}" -eq 0 ] && fail "Жодного файлу не завантажено. Перевір посилання/інтернет."

if [ "$MODE" == "2" ]; then
    echo ""
    echo "==> ВСЕ ГОТОВО! Твої пісні лежать у папці $WORK_DIR окремими файлами."
    exit 0
fi

echo ""
echo "==> Створюємо список для склеювання..."
merge_mp3_files "$WORK_DIR" "$LIST_FILE" "$TEMP_FINAL"

if [ "$FORMAT_CHOICE" == "2" ]; then
    echo "==> Переганяємо в .ogg..."
    RESULT_FILE="${WORK_DIR}/${CUSTOM_NAME}.ogg"
    ffmpeg -y -i "$TEMP_FINAL" -c:a libvorbis -q:a 5 "$RESULT_FILE" \
        > /dev/null 2>&1 || fail "Не вдалося перекодувати в ogg."
else
    RESULT_FILE="${WORK_DIR}/${CUSTOM_NAME}.mp3"
    mv "$TEMP_FINAL" "$RESULT_FILE"
fi

echo "==> Прибираємо за собою окремі пісні..."
find "$WORK_DIR" -maxdepth 1 -type f -name '*.mp3' ! -name "$(basename "$RESULT_FILE")" -delete

echo ""
echo "==> ЧИСТА ПЕРЕМОГА! Файл готовий: $RESULT_FILE"
