#!/usr/bin/env bash
# ==========================================
# Dmusic — Інсталятор
# ==========================================
# Використання (після того, як виставиш репо на GitHub):
#   curl -fsSL https://raw.githubusercontent.com/<твій_акаунт>/dmusic/main/install.sh | bash
#
# Що робить:
#   1. Перевіряє залежності (yt-dlp, ffmpeg, curl, jq; playerctl — опційно)
#   2. Завантажує сам файл Dmusic з GitHub
#   3. Кладе його в /usr/local/bin/Dmusic і робить виконуваним
#   4. Після цього команда "Dmusic" доступна з будь-якого місця в терміналі
set -euo pipefail

# !!! ЗАМІНИ ЦЕ ПОСИЛАННЯ на raw-URL свого файлу Dmusic на GitHub !!!
DMUSIC_RAW_URL="https://raw.githubusercontent.com/limbo099/dmusic/main/Dmusic"

INSTALL_PATH="/usr/local/bin/Dmusic"

echo "========================================"
echo "   Встановлення Dmusic"
echo "========================================"
echo ""

# 1. Перевірка і АВТОМАТИЧНЕ встановлення залежностей
echo "==> Перевіряю залежності..."
missing=()
for cmd in yt-dlp ffmpeg curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "Бракує: ${missing[*]}. Встановлюю автоматично..."

    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm "${missing[@]}" \
            || { echo "ПОМИЛКА: не вдалося встановити залежності через pacman."; exit 1; }
    elif command -v apt >/dev/null 2>&1; then
        sudo apt update && sudo apt install -y "${missing[@]}" \
            || { echo "ПОМИЛКА: не вдалося встановити залежності через apt."; exit 1; }
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "${missing[@]}" \
            || { echo "ПОМИЛКА: не вдалося встановити залежності через dnf."; exit 1; }
    else
        echo "ПОМИЛКА: не розпізнано пакетний менеджер. Встанови вручну: ${missing[*]}"
        exit 1
    fi

    echo "==> Залежності встановлено."
else
    echo "Усі основні залежності вже на місці."
fi

# Опційна залежність — встановлюємо мовчки, якщо не вдасться, не критично
if ! command -v playerctl >/dev/null 2>&1; then
    echo "==> Встановлюю опційну залежність playerctl (для автотрек-листа зі Spotify-клієнта)..."
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm playerctl 2>/dev/null \
            || echo "    (не вдалося, не критично — без playerctl усі інші методи й так працюють)"
    elif command -v apt >/dev/null 2>&1; then
        sudo apt install -y playerctl 2>/dev/null \
            || echo "    (не вдалося, не критично — без playerctl усі інші методи й так працюють)"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y playerctl 2>/dev/null \
            || echo "    (не вдалося, не критично — без playerctl усі інші методи й так працюють)"
    fi
fi

# 2. Завантаження Dmusic
echo "==> Завантажую Dmusic..."
TMP_FILE=$(mktemp)
if ! curl -fsSL "$DMUSIC_RAW_URL" -o "$TMP_FILE"; then
    echo "ПОМИЛКА: не вдалося завантажити Dmusic з $DMUSIC_RAW_URL"
    echo "Перевір посилання або інтернет-з'єднання."
    rm -f "$TMP_FILE"
    exit 1
fi

chmod +x "$TMP_FILE"

# 3. Встановлення в систему (потребує sudo для /usr/local/bin)
echo "==> Встановлюю в $INSTALL_PATH (потрібен sudo)..."
sudo mv "$TMP_FILE" "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"

echo ""
echo "==> ГОТОВО! Команда Dmusic встановлена."
echo "    Спробуй:  Dmusic        — запустити завантаження"
echo "              Dmusic info   — довідка по функціоналу"
