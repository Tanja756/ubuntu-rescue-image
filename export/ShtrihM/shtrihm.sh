#!/bin/bash
# ============================================================
# Управление ККТ Штрих-М (whiptail)
# ============================================================

CONFIG_FILE="$HOME/.kkt_config"

# ---------- Конфиг ----------
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    HOST="192.168.137.111"
    PORT="7778"
    PASS="30"
    CONN_TYPE="net"          # net | serial
    SERIAL_PORT=""
    SERIAL_BAUD="115200"
fi

# Значения по умолчанию, если в старом конфиге их нет
: "${CONN_TYPE:=net}"
: "${SERIAL_PORT:=}"
: "${SERIAL_BAUD:=115200}"
: "${HOST:=192.168.137.111}"
: "${PORT:=7778}"
: "${PASS:=30}"

save_config() {
    cat > "$CONFIG_FILE" << EOF
HOST="$HOST"
PORT="$PORT"
PASS="$PASS"
CONN_TYPE="$CONN_TYPE"
SERIAL_PORT="$SERIAL_PORT"
SERIAL_BAUD="$SERIAL_BAUD"
EOF
    # ИНН (если задан)
    if [[ -n "${KKT_INN:-$RETAIL_INN}" ]]; then
        echo "KKT_INN=\"${KKT_INN:-$RETAIL_INN}\"" >> "$CONFIG_FILE"
    fi
}

# Строка текущего подключения для меню
conn_str() {
    if [[ "$CONN_TYPE" == "serial" ]]; then
        echo "COM: ${SERIAL_PORT:-?} @ ${SERIAL_BAUD}"
    else
        echo "NET: $HOST:$PORT"
    fi
}

# ---------- Протокол ----------

lrc() {
    local xor=0
    for b in "$@"; do
        xor=$((xor ^ b))
    done
    printf "%d" $xor
}

# Отправка по TCP (RNDIS / Ethernet).
# -N: после отправки пакета nc делает полузакрытие (shutdown на запись),
# ККТ обрабатывает пакет, отвечает и сама закрывает соединение —
# поэтому nc завершается самостоятельно, kill не требуется.
# Из потока (NAK/ACK/повторы) берём последний корректный пакет.
_send_net() {
    local hex="$1"
    local response
    # sleep 3.5 удерживает соединение открытым, чтобы полузакрытие (FIN)
    # не пришло раньше ответа ККТ: обычные ответы ~0.4 с, ФН — ~2.4 с
    response=$( ( printf '\x05'; sleep 0.2; printf '%s' "$hex" | xxd -r -p; sleep 3.5 ) \
        | nc -N -w 9 "$HOST" "$PORT" 2>/dev/null | xxd -p -c 1024)
    _extract_last_frame "$response"
}

# Выделить из hex-потока последний корректный пакет (STX LEN payload LRC).
# LRC = XOR байтов, начиная с LEN и до конца payload.
# Нужен, потому что ККТ на ENQ может прислать повтор прошлого ответа,
# а нам нужен именно ответ на текущую команду.
_extract_last_frame() {
    local hex="$1"
    local n=${#hex} i=0 out="" fl total need j payload lexp xor
    while (( i <= n - 4 )); do
        if [[ "${hex:i:2}" == "02" ]]; then
            fl=$(( 16#${hex:i+2:2} ))
            total=$(( fl + 3 ))          # STX + LEN + payload(fl) + LRC
            need=$(( total * 2 ))
            if (( i + need <= n )); then
                payload=${hex:i+4:fl*2}
                lexp=${hex:i+4+fl*2:2}
                xor=$(( fl ))
                for (( j=0; j<${#payload}; j+=2 )); do
                    xor=$(( xor ^ 16#${payload:j:2} ))
                done
                if (( xor == 16#$lexp )); then
                    out=${hex:i:need}
                fi
                i=$(( i + need ))
                continue
            fi
        fi
        i=$(( i + 2 ))
    done
    echo "$out"
}

# Отправка по serial (USB-CDC / COM)
_send_serial() {
    local hex="$1"
    local port="$SERIAL_PORT"
    local baud="${SERIAL_BAUD:-115200}"

    if [[ -z "$port" || ! -e "$port" ]]; then
        echo "COM-порт $port не найден" >&2
        return 1
    fi
    if ! port_accessible "$port"; then
        echo "Нет прав доступа к $port." >&2
        echo "Выполните: sudo usermod -aG dialout \$USER и перезапустите сессию," >&2
        echo "либо запустите скрипт через sudo." >&2
        return 1
    fi

    # Открываем порт ОДИН РАЗ и держим открытым всё время обмена.
    # Если открывать/закрывать отдельно под каждую команду (printf/dd),
    # ответ ККТ теряется: при последнем закрытии входной буфер очищается.
    local fd
    if ! exec {fd}<>"$port"; then
        echo "Не удалось открыть $port" >&2
        return 1
    fi

    # Настраиваем порт
    stty -F "$port" "$baud" cs8 -cstopb -parenb raw -echo -icanon \
        min 0 time 2 2>/dev/null || { exec {fd}<&-; return 1; }

    # Сливаем остатки входного буфера
    timeout 0.1 dd <&"$fd" of=/dev/null bs=1024 count=4 2>/dev/null || true

    # 1) ENQ: ККТ отвечает NAK (готова принять команду)
    #    или ACK + повтор последнего неподтверждённого ответа
    printf '\x05' >&"$fd"
    local pre
    pre=$(timeout 0.4 dd <&"$fd" bs=64 count=1 2>/dev/null | xxd -p -c 64 || true)

    # 2) если пришёл повтор (ACK+пакет) — квитируем его своим ACK
    if [[ "${pre:0:2}" == "06" ]]; then
        printf '\x06' >&"$fd"
    fi

    # 3) пакет шлём немедленно: ККТ ждёт STX ~50 мс после ENQ,
    #    позже она возвращается в «Ожидание ENQ» и молча теряет пакет
    printf '%s' "$hex" | xxd -r -p >&"$fd"

    # 4) читаем ACK ККТ + ответ. Тяжёлые команды (ФН: FF03h, FF39h...)
    #    отвечают через 1-3 с после ACK, поэтому до появления кадра
    #    терпим ~3.5 с тишины; после кадра — 0.4 с тишины и завершаем.
    local response="" chunk empty=0
    local deadline=$(( SECONDS + 20 ))
    while (( SECONDS <= deadline )); do
        chunk=$(timeout 0.5 dd <&"$fd" bs=512 count=1 2>/dev/null | xxd -p -c 512 || true)
        if [[ -z "$chunk" ]]; then
            (( empty++ ))
            if [[ -n "$(_extract_last_frame "$response")" ]]; then
                (( empty >= 2 )) && break
            else
                (( empty >= 18 )) && break
            fi
        else
            response+="$chunk"
            empty=0
        fi
    done

    # 5) квитируем ответ ККТ, чтобы он не «висел» неподтверждённым
    printf '\x06' >&"$fd" 2>/dev/null || true

    exec {fd}<&- {fd}>&-

    # 6) из потока (мог быть повтор по ENQ + ACK + ответ) берём последний пакет
    _extract_last_frame "$response"
}

# Универсальная отправка. Аргументы — байты команды.
send() {
    local -a data=("$@")
    local len=${#data[@]}
    local lrc_val
    lrc_val=$(lrc $len "${data[@]}")

    local hex="02$(printf "%02x" $len)"
    for b in "${data[@]}"; do
        hex+=$(printf "%02x" $b)
    done
    hex+=$(printf "%02x" $lrc_val)

    local response=""
    if [[ "$CONN_TYPE" == "serial" ]]; then
        response=$(_send_serial "$hex")
    else
        response=$(_send_net "$hex")
    fi

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Убираем возможный ведущий ACK (06) и ENQ-ответы
    response=${response#06}
    while [[ ${response:0:2} == "06" ]]; do
        response=${response:2}
    done

    # Иногда приходит STX в начале — оставляем как есть (парсеры ждут с offset)
    echo "$response"
    return 0
}

# Человекочитаемое описание текущего канала (для сообщений об ошибках)
conn_desc() {
    if [[ "$CONN_TYPE" == "serial" ]]; then
        echo "${SERIAL_PORT:-COM?} @ ${SERIAL_BAUD}"
    else
        echo "$HOST:$PORT"
    fi
}

# ---------- Команды ККТ ----------

cmd_short_status() {
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x10 $p1 $p2 $p3 $p4); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi

    if [[ ${#resp} -lt 36 ]]; then
        whiptail --title "Результат" --msgbox "Ответ слишком короткий (${#resp})" 8 50
        return 1
    fi

    local err=${resp:6:2}
    if [[ "$err" != "00" ]]; then
        whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
        return 1
    fi

    local op=${resp:8:2}
    local f1=${resp:10:2} f2=${resp:12:2}
    local mode=${resp:14:2} submode=${resp:16:2}
    local ops_lo=${resp:18:2} bat_v=${resp:20:2} psu_v=${resp:22:2}
    local res1=${resp:24:2} key_err=${resp:26:2}
    local ops_hi=${resp:28:2} temp=${resp:30:2}
    local prev_mode=${resp:32:2} key_status=${resp:34:2} last_print=${resp:36:2}

    local flags=""
    (( 0x$f1 & 1 )) && flags+="Рулон ОЖ: есть\n" || flags+="Рулон ОЖ: нет\n"
    (( 0x$f1 & 2 )) && flags+="Рулон чековой ленты: есть\n" || flags+="Рулон чековой ленты: нет\n"
    (( 0x$f1 & 64 )) && flags+="Датчик ОЖ: есть\n" || flags+="Датчик ОЖ: нет\n"
    (( 0x$f1 & 128 )) && flags+="Датчик чековой ленты: есть\n" || flags+="Датчик чековой ленты: нет\n"
    (( 0x$f2 & 1 )) && flags+="Рычаг ТЛ ОЖ: опущен\n" || flags+="Рычаг ТЛ ОЖ: поднят\n"
    (( 0x$f2 & 2 )) && flags+="Рычаг ТЛ чековой ленты: опущен\n" || flags+="Рычаг ТЛ чековой ленты: поднят\n"
    (( 0x$f2 & 4 )) && flags+="Крышка корпуса: поднята\n" || flags+="Крышка корпуса: опущена\n"
    (( 0x$f2 & 8 )) && flags+="Денежный ящик: открыт\n" || flags+="Денежный ящик: закрыт\n"
    (( 0x$f2 & 16 )) && flags+="Крышка корпуса ОЖ: поднята\n" || flags+="Крышка корпуса ОЖ: опущена\n"

    local opers=$(( 0x${ops_hi:0:2} * 256 + 0x${ops_lo:0:2} ))
    local voltage=$(( 16#${psu_v:0:2} ))
    local battery=$(( 16#${bat_v:0:2} ))
    local temperature=$(( 16#${temp:0:2} ))
    local thermal=$(( 16#${res1:0:2} ))

    local msg="Связь OK\n\n"
    msg+="Оператор: 0x$op\n"
    msg+="Флаги:\n$flags"
    msg+="Режим ККТ: 0x$mode\nПодрежим: 0x$submode\n"
    msg+="Операций в чеке: $opers\n"
    msg+="Напряжение батареи: $battery\nНапряжение БП: $voltage\n"
    msg+="Темп. ТПГ: $temperature°C\n"
    msg+="Ошибка обновления ключей: 0x$key_err\n"
    msg+="Пред. режим: 0x$prev_mode\n"
    msg+="Статус обновления ключей: 0x$key_status\n"
    msg+="Результат послед. печати: 0x$last_print"

    whiptail --title "Короткий запрос состояния" --msgbox "$msg" 30 70
    return 0
}

# Расшифровка режима ККТ (Приложение 1 api.txt)
mode_decode() {
    local m=$((16#$1))
    local name sub
    case $(( m & 0x0F )) in
        1) name="Выдача данных" ;;
        2) name="Открытая смена (24 ч не истекли)" ;;
        3) name="Открытая смена (24 ч истекли)" ;;
        4) name="Закрытая смена" ;;
        5) name="Блокировка по неправильному паролю налогового инспектора" ;;
        6) name="Ожидание подтверждения ввода даты" ;;
        7) name="Разрешение изменения положения десятичной точки" ;;
        8) name="Открытый документ"
           case $(( m >> 4 )) in
               0) sub="(продажа)" ;;
               1) sub="(покупка)" ;;
               2) sub="(возврат продажи)" ;;
               3) sub="(возврат покупки)" ;;
               4) sub="(нефискальный)" ;;
               *) sub="(подрежим ${m})" ;;
           esac ;;&
        9) name="Режим разрешения технологического обнуления" ;;
        10) name="Тестовый прогон" ;;
        11) name="Печать полного фискального отчёта" ;;
        12) name="Работа с фискальным подкладным документом"
            case $(( m >> 4 )) in
                0) sub="(продажа открыта)" ;;
                1) sub="(покупка открыта)" ;;
                2) sub="(возврат продажи открыт)" ;;
                3) sub="(возврат покупки открыт)" ;;
                *) sub="(подрежим ${m})" ;;
            esac ;;&
        13) name="Печать подкладного документа"
            case $(( m >> 4 )) in
                0) sub="(ожидание загрузки)" ;;
                1) sub="(загрузка и позиционирование)" ;;
                2) sub="(позиционирование)" ;;
                3) sub="(печать)" ;;
                4) sub="(печать закончена)" ;;
                5) sub="(выброс документа)" ;;
                6) sub="(ожидание извлечения)" ;;
                *) sub="(подрежим ${m})" ;;
            esac ;;&
        14) name="Фискальный подкладной документ сформирован" ;;
        *) name="Неизвестный режим (0x$1)" ;;
    esac
    if [[ -n "${sub:-}" ]]; then
        echo "${name} ${sub}"
    else
        echo "$name"
    fi
}

# Расшифровка подрежима ККТ (Приложение 1)
submode_decode() {
    case $((16#$1)) in
        0) echo "Бумага есть, ККТ готова к печати" ;;
        1) echo "Пассивное отсутствие бумаги" ;;
        2) echo "Активное отсутствие бумаги (идёт печать)" ;;
        3) echo "После активного отсутствия бумаги — ждёт продолжения печати" ;;
        4) echo "Фаза печати полных фискальных отчётов" ;;
        5) echo "Фаза печати операции" ;;
        *) echo "Неизвестный подрежим (0x$1)" ;;
    esac
}

# Модель устройства (0xFC)
kkt_get_model() {
    local resp
    if ! resp=$(send 0xFC); then
        echo ""
        return 1
    fi
    [[ ${#resp} -lt 16 ]] && { echo ""; return 1; }
    local err=${resp:6:2}
    [[ "$err" != "00" ]] && { echo ""; return 1; }
    # Данные: cmd(2hex)+err(2hex)+тип(2)+подтип(2)+протокол(2)+модель(2)+язык(2)
    # → название устройства начинается с байта 8 payload, в resp — с симв. 20
    local h=${resp:20}
    h=${h:0:-2}
    local out="" b
    for ((i=0; i<${#h}; i+=2)); do
        b=${h:i:2}
        [[ "$b" == "00" ]] && break
        out+=$(printf "\\x$b")
    done
    if command -v iconv >/dev/null 2>&1; then
        out=$(printf '%b' "$out" | iconv -f CP1251 -t UTF-8 2>/dev/null)
    fi
    echo "$out"
}

# Имя кассира из таблицы 2, поля f2 (0x1F)
kkt_get_cashier() {
    local row=$1
    [[ -z "$row" ]] && row=30
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))
    local r1=$((row & 0xFF)) r2=$(( (row >> 8) & 0xFF ))
    local resp
    if ! resp=$(send 0x1F $p1 $p2 $p3 $p4 2 $r1 $r2 2); then
        echo ""
        return 1
    fi
    [[ ${#resp} -lt 10 ]] && { echo ""; return 1; }
    local err=${resp:6:2}
    [[ "$err" != "00" ]] && { echo ""; return 1; }
    local h=${resp:8}
    h=${h:0:-2}
    local out="" b
    for ((i=0; i<${#h}; i+=2)); do
        b=${h:i:2}
        [[ "$b" == "00" ]] && break
        out+=$(printf "\\x$b")
    done
    if command -v iconv >/dev/null 2>&1; then
        out=$(printf '%b' "$out" | iconv -f CP1251 -t UTF-8 2>/dev/null)
    fi
    echo "$out"
}

# ---------- Дополнительные команды ККТ ----------

# Полное состояние ККТ (0x11)
cmd_full_status() {
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x11 $p1 $p2 $p3 $p4); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi

    if [[ ${#resp} -lt 86 ]]; then
        whiptail --title "Результат" --msgbox "Ответ слишком короткий (${#resp} hex)" 8 50
        return 1
    fi

    local err=${resp:6:2}
    if [[ "$err" != "00" ]]; then
        whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
        return 1
    fi

    local op=${resp:8:2}
    local ver_lo=${resp:10:2} ver_hi=${resp:12:2}
    local build_lo=${resp:14:2} build_hi=${resp:16:2}
    local po_d=${resp:18:2} po_m=${resp:20:2} po_y=${resp:22:2}
    local place=${resp:24:2}
    local doc_lo=${resp:26:2} doc_hi=${resp:28:2}
    local f1=${resp:30:2} f2=${resp:32:2}
    local mode=${resp:34:2} submode=${resp:36:2} port=${resp:38:2}
    # Реальные смещения для этого апарата (48 байт, после STX+LEN):
    local d=${resp:54:2} mo=${resp:56:2} y=${resp:58:2}
    local t_h=${resp:60:2} t_m=${resp:62:2} t_s=${resp:64:2}
    local shift_lo=${resp:76:2} shift_hi=${resp:78:2}
    local regs=${resp:80:2} regs_left=${resp:82:2}

    # Дата/время/год передаются двоичными числами -> показываем десятичные
    local dd=$((16#$d)) mm=$((16#$mo)) yy=$((16#$y))
    local th=$((16#$t_h)) tm=$((16#$t_m)) ts=$((16#$t_s))
    local po_dd=$((16#$po_d)) po_mm=$((16#$po_m)) po_yy=$((16#$po_y))

    # Версия ПО: 2 символа WIN1251 с точкой между ними
    local vchar1 vchar2
    printf -v vchar1 '%b' "\\x$ver_lo"
    printf -v vchar2 '%b' "\\x$ver_hi"
    local version="${vchar1}.${vchar2}"

    local flags=""
    (( 0x$f1 & 1 )) && flags+="Рулон ОЖ: есть\n" || flags+="Рулон ОЖ: нет\n"
    (( 0x$f1 & 2 )) && flags+="Рулон чековой ленты: есть\n" || flags+="Рулон чековой ленты: нет\n"
    (( 0x$f1 & 64 )) && flags+="Датчик ОЖ: есть\n" || flags+="Датчик ОЖ: нет\n"
    (( 0x$f1 & 128 )) && flags+="Датчик чековой: есть\n" || flags+="Датчик чековой: нет\n"
    (( 0x$f2 & 1 )) && flags+="Рычаг ТЛ ОЖ: опущен\n" || flags+="Рычаг ТЛ ОЖ: поднят\n"
    (( 0x$f2 & 2 )) && flags+="Рычаг ТЛ чековой: опущен\n" || flags+="Рычаг ТЛ чековой: поднят\n"
    (( 0x$f2 & 4 )) && flags+="Крышка корпуса: поднята\n" || flags+="Крышка корпуса: опущена\n"
    (( 0x$f2 & 8 )) && flags+="Денежный ящик: открыт\n" || flags+="Денежный ящик: закрыт\n"
    (( 0x$f2 & 16 )) && flags+="Крышка корпуса ОЖ: поднята\n" || flags+="Крышка корпуса ОЖ: опущена\n"

    local doc_num=$(( (16#$doc_hi << 8) | 16#$doc_lo ))
    local shift_num=$(( (16#$shift_hi << 8) | 16#$shift_lo ))
    local build=$(( (16#$build_hi << 8) | 16#$build_lo ))

    # ИНН: это 6-байтовое число little-endian (ответ 0x11, 48 байт)
    # Смещение ИНН в 48-байтном ответе: payload[42..47] = resp[86..98]
    local inn=${resp:88:12}
    local inn_num=$(( (16#${inn:10:2} << 40) | (16#${inn:8:2} << 32) | (16#${inn:6:2} << 24) | (16#${inn:4:2} << 16) | (16#${inn:2:2} << 8) | 16#${inn:0:2} ))
    if (( inn_num == 0xFFFFFFFFFFFF )); then
        inn_text="не введён"
    else
        inn_text=$(printf '%d' $inn_num)
    fi

    local model cashier
    model=$(kkt_get_model)
    cashier=$(kkt_get_cashier 30)
    [[ -z "$model" ]] && model="—"
    [[ -z "$cashier" ]] && cashier="—"

    local msg="Полное состояние ККТ\n\n"
    msg+="Модель: $model\n"
    msg+="Оператор: 0x$op\n"
    msg+="Кассир: $cashier\n"
    msg+="Версия ПО: $version (сборка $build)\n"
    msg+="Дата ПО: $po_dd.$po_mm.20$po_yy\n"
    msg+="Номер в зале: 0x$place\n"
    msg+="Сквозной номер документа: $doc_num\n"
    msg+="Флаги:\n$flags\n"
    msg+="Режим ККТ: $(mode_decode $mode)\n"
    msg+="Подрежим: $(submode_decode $submode)\n"
    msg+="Порт ККТ: 0x$port\n"
    msg+="Дата: $dd.$mm.20$yy  Время: $th:$tm:$ts\n"
    msg+="Номер посл. закрытой смены: $shift_num\n"
    msg+="Перерегистраций: $(printf '%d' $((16#$regs)))  (осталось: $(printf '%d' $((16#$regs_left))))\n"
    if [[ -n "${KKT_INN:-$RETAIL_INN}" ]]; then
        msg+="ИНН: ${KKT_INN:-$RETAIL_INN}\n"
    else
        msg+="ИНН: $inn_text\n"
    fi

    # ----- Сеть: RNDIS (таб.21 п.9) и IP (таб.16) -----
    msg+="\n"
    local net=""

    local rndis
    rndis=$(cmd_read_table 21 1 9 2>/dev/null)
    case "$rndis" in
        00) net+="RNDIS: выключен\n" ;;
        01) net+="RNDIS: включен (1)\n" ;;
        02) net+="RNDIS: включен (2)\n" ;;
        *)  net+="RNDIS: нет данных\n" ;;
    esac

    local f_static ip_hex="" gw_hex="" mask_hex="" i b
    f_static=$(cmd_read_table 16 1 1 2>/dev/null)
    for i in 3 4 5 6;  do b=$(cmd_read_table 16 1 $i 2>/dev/null); [[ "$b" =~ ^[0-9A-Fa-f]{2}$ ]] && ip_hex+="$b";   done
    for i in 11 12 13 14; do b=$(cmd_read_table 16 1 $i 2>/dev/null); [[ "$b" =~ ^[0-9A-Fa-f]{2}$ ]] && mask_hex+="$b"; done
    for i in 7 8 9 10; do b=$(cmd_read_table 16 1 $i 2>/dev/null); [[ "$b" =~ ^[0-9A-Fa-f]{2}$ ]] && gw_hex+="$b";  done

    if [[ ${#ip_hex} -eq 8 ]]; then
        local mode_str="DHCP"
        [[ "$f_static" == "01" ]] && mode_str="статический"
        net+="Тип адреса: $mode_str\n"
        net+="IP:   $((16#${ip_hex:0:2})).$((16#${ip_hex:2:2})).$((16#${ip_hex:4:2})).$((16#${ip_hex:6:2}))\n"
        if [[ ${#mask_hex} -eq 8 ]]; then
            net+="Маска: $((16#${mask_hex:0:2})).$((16#${mask_hex:2:2})).$((16#${mask_hex:4:2})).$((16#${mask_hex:6:2}))\n"
        fi
        if [[ ${#gw_hex} -eq 8 ]]; then
            net+="Шлюз: $((16#${gw_hex:0:2})).$((16#${gw_hex:2:2})).$((16#${gw_hex:4:2})).$((16#${gw_hex:6:2}))\n"
        fi
    else
        net+="Сеть (таб.16): нет данных\n"
    fi

    msg+="$net"

    whiptail --title "Информация о ККТ (0x11)" --msgbox "$msg" 44 75
    return 0
}

# Технологическое обнуление (0x16) — без пароля
cmd_tech_reset() {
    local resp
    if ! resp=$(send 0x16); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    if [[ ${#resp} -lt 8 ]]; then
        whiptail --title "Результат" --msgbox "Ответ слишком короткий (${#resp} hex)" 8 50
        return 1
    fi
    local err=${resp:6:2}
    if [[ "$err" == "00" ]]; then
        whiptail --title "Технологическое обнуление" --msgbox "Команда выполнена." 8 50
        return 0
    fi
    whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
    return 1
}

# Тестовый прогон (0x19)
cmd_test_run() {
    local period
    period=$(whiptail --title "Тестовый прогон" --inputbox "Период вывода теста в минутах (1-99):" 9 50 "5" 3>&1 1>&2 2>&3)
    [[ $? -ne 0 || -z "$period" ]] && return 1
    if ! [[ "$period" =~ ^[0-9]+$ ]]; then
        whiptail --msgbox "Введите число" 7 40
        return 1
    fi
    period=$((10#$period))
    if (( period < 1 || period > 99 )); then
        whiptail --msgbox "Диапазон 1-99 минут" 7 40
        return 1
    fi

    if ! whiptail --title "Тестовый прогон" --yesno "Запустить тестовый прогон?\n\nБудет напечатан тестовый чек, период: $period мин." 10 60; then
        return 1
    fi

    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x19 $p1 $p2 $p3 $p4 $period); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    local err=${resp:6:2}
    if [[ "$err" == "00" ]]; then
        whiptail --title "Тестовый прогон" --msgbox "Тестовый прогон запущен." 8 50
        return 0
    fi
    whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
    return 1
}

# Прерывание тестового прогона (0x2B)
cmd_test_abort() {
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x2B $p1 $p2 $p3 $p4); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    local err=${resp:6:2}
    if [[ "$err" == "00" ]]; then
        whiptail --title "Прерывание тестового прогона" --msgbox "Выполнено." 8 50
        return 0
    fi
    whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
    return 1
}

# Установка времени из системного времени хоста (0x21)
cmd_set_time() {
    local H=$(date +%H) M=$(date +%M) S=$(date +%S)
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x21 $p1 $p2 $p3 $p4 $((10#$H)) $((10#$M)) $((10#$S))); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    local err=${resp:6:2}
    if [[ "$err" == "00" ]]; then
        whiptail --title "Установка времени" --msgbox "Время установлено: $H:$M:$S" 8 50
        return 0
    fi
    whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
    return 1
}

# Установка даты из системной даты хоста (0x22)
cmd_set_date() {
    local D=$(date +%d) M=$(date +%m) Y=$(date +%y)
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x22 $p1 $p2 $p3 $p4 $((10#$D)) $((10#$M)) $((10#$Y))); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    local err=${resp:6:2}
    if [[ "$err" == "00" ]]; then
        whiptail --title "Установка даты" --msgbox "Дата запрограммирована: $D.$M.20$Y\n\nНе забудьте подтвердить дату (команда 0x23)!" 9 55
        return 0
    fi
    whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
    return 1
}

# Подтверждение программирования даты (0x23)
cmd_confirm_date() {
    local D=$(date +%d) M=$(date +%m) Y=$(date +%y)
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x23 $p1 $p2 $p3 $p4 $((10#$D)) $((10#$M)) $((10#$Y))); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    local err=${resp:6:2}
    if [[ "$err" == "00" ]]; then
        whiptail --title "Подтверждение даты" --msgbox "Дата подтверждена: $D.$M.20$Y" 8 50
        return 0
    fi
    whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
    return 1
}
# Синхронизация даты/времени с хостом: 0x22 (дата) -> 0x21 (время) -> 0x23 (подтверждение)
# Выполняется сразу, без запросов; коды ошибок ККТ игнорируются.
cmd_sync_time() {
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))
    local D=$(date +%d) M=$(date +%m) Y=$(date +%y)
    local H=$(date +%H) Min=$(date +%M) S=$(date +%S)
    local errs="" resp="" e=""

    # 1. Дата (0x22)
    resp=$(send 0x22 $p1 $p2 $p3 $p4 $((10#$D)) $((10#$M)) $((10#$Y)) 2>/dev/null) || resp=""
    e="00"
    [[ -z "$resp" || "$e" != "00" ]] && errs+="  Дата (0x22): ${resp:+ошибка 0x$e}${resp:-нет ответа}\n"

    # 2. Время (0x21)
    resp=$(send 0x21 $p1 $p2 $p3 $p4 $((10#$H)) $((10#$Min)) $((10#$S)) 2>/dev/null) || resp=""
    e="00"
    [[ -z "$resp" || "$e" != "00" ]] && errs+="  Время (0x21): ${resp:+ошибка 0x$e}${resp:-нет ответа}\n"

    # 3. Подтверждение даты (0x23)
    resp=$(send 0x23 $p1 $p2 $p3 $p4 $((10#$D)) $((10#$M)) $((10#$Y)) 2>/dev/null) || resp=""
    e=${resp:6:2}
    [[ -z "$resp" || "$e" != "00" ]] && errs+="  Подтверждение (0x23): ${resp:+ошибка 0x$e}${resp:-нет ответа}\n"

    local msg="Отправлено в ККТ:

Дата:  $D.$M.20$Y
Время: $H:$Min:$S"
    if [[ -n "$errs" ]]; then
        msg+="\n\nКоды ответов (игнорируются):\n$errs"
    fi
    whiptail --title "Синхронизация времени" --msgbox "$msg" 14 55
    return 0
}



# Включить RNDIS (таблица 21, поле 9): сначала 1, затем пытаемся 2
cmd_set_rndis() {
    if ! whiptail --title "RNDIS" --yesno "Включить RNDIS?\n(ККТ перейдёт в USB-режим.)" 10 55; then
        return 1
    fi
    local res1 res2
    res1=$(cmd_write_table 21 1 9 "01") || true
    if [[ "$res1" != "OK" ]]; then
        whiptail --title "RNDIS" --msgbox "Не удалось установить RNDIS=1\nОтвет: $res1" 9 50
        return 1
    fi
    whiptail --title "RNDIS" --msgbox "RNDIS=1 записано.\nПытаемся установить RNDIS=2 (расширенный)..." 9 50
    res2=$(cmd_write_table 21 1 9 "02") || true
    if [[ "$res2" == "OK" ]]; then
        whiptail --title "RNDIS" --msgbox "RNDIS=2 — запись удалась." 8 50
    else
        whiptail --title "RNDIS" --msgbox "RNDIS=2 не поддерживается.\nRNDIS=1 осталось." 8 50
    fi
    return 0
}

# Установить статический IP и шлюз (таблица 16)
cmd_set_ip() {
    if ! whiptail --title "IP" --yesno "Установить статические сетевые параметры ККТ?\nIP: 192.168.137.111  маска: 255.255.255.0  шлюз: 192.168.137.1" 12 65; then
        return 1
    fi
    cmd_write_table 16 1 1 "01" || { whiptail --title "IP" --msgbox "Ошибка f1: $?" 7 40; return 1; }
    cmd_write_table 16 1 3 "C0" || true   # 192
    cmd_write_table 16 1 4 "A8" || true   # 168
    cmd_write_table 16 1 5 "89" || true   # 137
    cmd_write_table 16 1 6 "6F" || true   # 111
    cmd_write_table 16 1 7 "C0" || true   # GW
    cmd_write_table 16 1 8 "A8" || true
    cmd_write_table 16 1 9 "89" || true
    cmd_write_table 16 1 10 "01" || true
    cmd_write_table 16 1 11 "FF" || true  # MASK
    cmd_write_table 16 1 12 "FF" || true
    cmd_write_table 16 1 13 "FF" || true
    cmd_write_table 16 1 14 "00" || true
    whiptail --title "IP" --msgbox "Сетевые параметры записаны.\nПерезагрузите ККТ (FE F3)." 9 50
    return 0
}

# Перезагрузка ККТ: команда FEh с подтипом F3h, пароль 0x00000000
cmd_reboot() {
    if ! whiptail --title "Перезагрузка ККТ" --yesno "Перезагрузить ККТ сейчас?\n\nККТ недоступна ~10–15 сек." 10 55; then
        return 1
    fi
    # data = FE F3 00 00 00 00 (команда FEh + код подтипа F3h + пароль 4 байта 0)
    local resp
    if ! resp=$(send 0xFE 0xF3 0x00 0x00 0x00 0x00); then
        whiptail --title "Перезагрузка" --msgbox "Нет ответа — ККТ, скорее всего, ушла в перезагрузку." 8 55
        return 0
    fi
    local err=${resp:6:2}
    if [[ "$err" == "00" || -z "$err" ]]; then
        whiptail --title "Перезагрузка" --msgbox "ККТ перезагружается.\nПодождите 10–15 сек." 8 50
    else
        whiptail --title "Перезагрузка" --msgbox "Код ответа: 0x$err\nПодождите 10–15 сек." 8 50
    fi
    return 0
}


cmd_close_shift() {
    if ! whiptail --title "Закрытие смены" --yesno "Закрыть текущую смену?\n(будет сформирован закрывающий отчёт)" 10 60; then
        return 1
    fi

    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0xFF 0x42 $p1 $p2 $p3 $p4); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    local err=${resp:8:2}
    if [[ "$err" == "00" ]]; then
        whiptail --title "Закрытие смены" --msgbox "Закрытие смены инициировано." 8 50
        return 0
    fi
    whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
    return 1
}

# Запрос срока действия ФН (FF03h)
cmd_fn_expiry() {
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0xFF 0x03 $p1 $p2 $p3 $p4); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    if [[ ${#resp} -lt 16 ]]; then
        whiptail --title "Результат" --msgbox "Ответ слишком короткий (${#resp} hex)" 8 50
        return 1
    fi

    local err=${resp:8:2}
    if [[ "$err" != "00" ]]; then
        whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
        return 1
    fi

    local y=$((16#${resp:10:2})) m=$((16#${resp:12:2})) d=$((16#${resp:14:2}))
    local expiry_date="20$y-$m-$d"
    local exp_sec today_sec days="?"
    if exp_sec=$(date -d "$expiry_date" +%s 2>/dev/null); then
        today_sec=$(date +%s)
        days=$(( (exp_sec - today_sec) / 86400 ))
    fi

    local msg="Срок действия ФН: $d.$m.20$y\n\nОсталось дней: $days\n"
    if [[ "$days" != "?" ]] && (( days < 0 )); then
        msg+="\nВНИМАНИЕ: срок действия ФН истёк!"$'\n'"Необходима замена ФН."
    elif [[ "$days" != "?" ]] && (( days <= 30 )); then
        msg+="\nВНИМАНИЕ: до окончания срока действия ФН осталось менее 30 дней!"
    fi

    whiptail --title "Срок действия ФН (FF03h)" --msgbox "$msg" 12 55
    return 0
}

# Статус информационного обмена с ОФД (FF39h)
cmd_ofd_status() {
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0xFF 0x39 $p1 $p2 $p3 $p4); then
        whiptail --title "Результат" --msgbox "Нет ответа от $(conn_desc)" 8 50
        return 1
    fi
    if [[ ${#resp} -lt 30 ]]; then
        whiptail --title "Результат" --msgbox "Ответ слишком короткий (${#resp} hex)" 8 50
        return 1
    fi

    local err=${resp:8:2}
    if [[ "$err" != "00" ]]; then
        whiptail --title "Результат" --msgbox "Код ошибки ККТ: 0x$err" 8 50
        return 1
    fi

    local status=${resp:10:2}
    local read_state=${resp:12:2}
    local cnt_lo=${resp:14:2} cnt_hi=${resp:16:2}
    local doc_lo=${resp:18:2} doc_hi_1=${resp:20:2} doc_hi_2=${resp:22:2} doc_hi_3=${resp:24:2}
    local d1=$((16#${resp:26:2})) d2=$((16#${resp:28:2})) d3=$((16#${resp:30:2})) t1=$((16#${resp:32:2})) t2=$((16#${resp:34:2}))

    local cnt=$(( (16#$cnt_hi << 8) | 16#$cnt_lo ))
    local doc_num=$(( (16#$doc_hi_3 << 24) | (16#$doc_hi_2 << 16) | (16#$doc_hi_1 << 8) | 16#$doc_lo ))

    local s=$((16#$status))
    local msg="Статус обмена с ОФД (FF39h)\n\n"
    msg+="Количество сообщений для ОФД (не отправленных): $cnt\n"
    if (( cnt > 0 )); then
        msg+="\nПервый в очереди документ:\n"
        msg+="  Номер ФД: $doc_num\n"
        msg+="  Дата/время: $d1.$d2.$d3 $t1:$t2\n"
    fi
    msg+="\nСтатус (биты):\n"
    (( s & 1 ))  && msg+="● Транспортное соединение установлено\n" || msg+="○ Транспортное соединение не установлено\n"
    (( s & 2 ))  && msg+="● Есть сообщение для передачи в ОФД\n" || msg+="○ Сообщений для передачи в ОФД нет\n"
    (( s & 4 ))  && msg+="● Ожидание квитанции от ОФД\n" || msg+="○ Квитанция не ожидается\n"
    (( s & 8 ))  && msg+="● Есть команда от ОФД\n" || msg+="○ Команд от ОФД нет\n"
    (( s & 16 )) && msg+="● Изменились настройки соединения с ОФД\n" || msg+="○ Настройки соединения не менялись\n"
    (( s & 32 )) && msg+="● Ожидание ответа на команду от ОФД\n" || msg+="○ Ответ на команду не ожидается\n"
    local rs=$((16#$read_state))
    msg+="\nСостояние чтения сообщения: $([ $rs -eq 1 ] && echo "Да" || echo "Нет")"

    whiptail --title "Статус обмена с ОФД (FF39h)" --msgbox "$msg" 20 60
    return 0
}

cmd_read_table() {
    local table=$1 row=$2 field=$3
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))
    local r1=$((row & 0xFF)) r2=$(( (row >> 8) & 0xFF ))

    local resp
    if ! resp=$(send 0x1F $p1 $p2 $p3 $p4 $table $r1 $r2 $field); then
        echo "ОШИБКА_СВЯЗИ"
        return 1
    fi

    if [[ ${#resp} -ge 8 ]]; then
        local err=${resp:6:2}
        if [[ "$err" == "00" ]]; then
            local value=${resp:8}
            value=${value:0:-2}
            echo "$value"
            return 0
        else
            echo "ERR:$err"
            return 1
        fi
    fi
    echo "SHORT"
    return 1
}

cmd_write_table() {
    local table=$1 row=$2 field=$3 value_hex=$4
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))
    local r1=$((row & 0xFF)) r2=$(( (row >> 8) & 0xFF ))

    local -a val_bytes=()
    for ((i=0; i<${#value_hex}; i+=2)); do
        val_bytes+=($((16#${value_hex:i:2})))
    done

    local resp
    if ! resp=$(send 0x1E $p1 $p2 $p3 $p4 $table $r1 $r2 $field "${val_bytes[@]}"); then
        echo "ОШИБКА_СВЯЗИ"
        return 1
    fi

    if [[ ${#resp} -ge 6 ]]; then
        local err=${resp:6:2}
        if [[ "$err" == "00" ]]; then
            echo "OK"
            return 0
        else
            echo "ERR:$err"
            return 1
        fi
    fi
    echo "SHORT"
    return 1
}

cmd_table_struct() {
    local table=$1
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local resp
    if ! resp=$(send 0x2D $p1 $p2 $p3 $p4 $table); then
        return 1
    fi

    if [[ ${#resp} -lt 10 ]]; then
        return 1
    fi

    local err=${resp:6:2}
    [[ "$err" != "00" ]] && return 1

    local name_hex=${resp:8:80}
    local name=""
    for ((i=0; i<80; i+=2)); do
        local b=${name_hex:i:2}
        [[ "$b" == "00" ]] && break
        name+=$(printf "\\x$b")
    done

    # little-endian
    local rows_hex=${resp:88:4}
    local rows=$((16#${rows_hex:2:2}${rows_hex:0:2}))

    local fields_hex=${resp:92:2}
    local fields=$((16#$fields_hex))

    echo "$name|$rows|$fields"
    return 0
}

# ---------- Вспомогательные ----------

# Определяет тип значения (текст или бинарное) и форматирует для отображения
format_value() {
    local val="$1"
    if [[ ${#val} -eq 2 ]]; then
        echo "$val (dec: $((16#$val)))"
        return
    fi

    local text_count=0
    local total_count=0
    local txt=""
    local has_nonzero=0

    for ((i=0; i<${#val}; i+=2)); do
        local b=${val:i:2}
        [[ "$b" == "00" ]] && break
        local code=$((16#$b))
        ((total_count++))
        ((code != 0)) && has_nonzero=1
        if (( code >= 32 && code <= 126 )); then
            ((text_count++))
            printf -v char '%b' "\\x$b"
            txt+="$char"
        elif (( code == 9 || code == 10 || code == 13 )); then
            ((text_count++))
            printf -v char '%b' "\\x$b"
            txt+="$char"
        else
            txt+="."
        fi
    done

    if (( total_count > 0 && text_count == total_count )); then
        echo "$val [text: \"$txt\"]"
    elif (( has_nonzero )); then
        echo "$val (hex)"
    else
        echo "$val (zero)"
    fi
}

# Чтение всех полей таблицы сразу (пакетное чтение)
cmd_batch_read() {
    local table=$1
    local p1=$((PASS & 0xFF)) p2=$(( (PASS >> 8) & 0xFF ))
    local p3=$(( (PASS >> 16) & 0xFF )) p4=$(( (PASS >> 24) & 0xFF ))

    local results=""
    for ((r=1; r<=30; r++)); do
        for ((f=1; f<=255; f++)); do
            local val
            val=$(cmd_read_table $table $r $f 2>/dev/null) || continue
            [[ -z "$val" || "$val" == "SHORT" ]] && continue
            # Проверяем, не пустое ли значение (все нули)
            local stripped
            stripped=$(echo "$val" | tr -d ' ')
            [[ "$stripped" == "00" || -z "$stripped" ]] && continue
            results+="${r}:${f}=${val}"$'\n'
        done
    done
    echo "$results"
}

# Бэкап таблицы в файл
cmd_backup_table() {
    local table=$1
    local info
    if ! info=$(cmd_table_struct $table); then
        return 1
    fi
    IFS='|' read -r name rows fields <<< "$info"

    local backup_file="$HOME/.kkt_backup_table${table}"
    {
        echo "# ККТ таблица $table: $name"
        echo "# Рядов: $rows, Полей: $fields"
        echo "# Формат: ряд:поле=hex_value"
        for ((r=1; r<=rows; r++)); do
            for ((f=1; f<=fields; f++)); do
                local val
                val=$(cmd_read_table $table $r $f 2>/dev/null) || continue
                [[ -z "$val" || "$val" == "SHORT" ]] && continue
                local stripped
                stripped=$(echo "$val" | tr -d ' ')
                [[ "$stripped" == "00" ]] && continue
                echo "${r}:${f}=${stripped}"
            done
        done
    } > "$backup_file"
    echo "$backup_file"
}

# Восстановление таблицы из файла
cmd_restore_table() {
    local table=$1
    local backup_file=$2
    if [[ ! -f "$backup_file" ]]; then
        echo "Файл бэкапа не найден"
        return 1
    fi

    local restored=0
    local failed=0
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        local row field val
        row=${line%%:*}
        local rest=${line#*:}
        field=${rest%%=*}
        val=${rest#*=}
        if cmd_write_table "$table" "$row" "$field" "$val" 2>/dev/null; then
            ((restored++))
        else
            ((failed++))
        fi
    done < "$backup_file"
    echo "Восстановлено: $restored, Ошибок: $failed"
}

# ---------- Поиск COM-портов и автодетект ККТ ----------

# Список всех кандидатов в serial-порты.
# ttyACM*/ttyUSB* показываем даже без прав доступа (иначе непонятно,
# почему устройство есть в /dev, а скрипт его "не видит").
list_serial_ports_all() {
    local -a ports=()
    local p
    for p in /dev/ttyACM* /dev/ttyUSB*; do
        [[ -e "$p" ]] && ports+=("$p")
    done
    # ttyS* — только доступные (их много и все системные)
    for p in /dev/ttyS*; do
        [[ -e "$p" && -r "$p" && -w "$p" ]] && ports+=("$p")
    done
    # Симлинки драйверов Штрих (если есть)
    for p in /dev/shtrih* /dev/fr*; do
        [[ -e "$p" ]] && ports+=("$p")
    done
    printf '%s\n' "${ports[@]}" | sort -u
}

# Проверка прав доступа к порту
port_accessible() {
    [[ -r "$1" && -w "$1" ]]
}

# Список портов, доступных для работы (с правами на чтение/запись)
list_serial_ports() {
    local p
    for p in $(list_serial_ports_all); do
        port_accessible "$p" && echo "$p"
    done
}

# Быстрая проверка: это Штрих-М? (короткий статус 0x10)
# Возвращает 0 если ответила валидно
probe_kkt_on_port() {
    local port="$1"
    local baud="${2:-115200}"
    local saved_type="$CONN_TYPE"
    local saved_port="$SERIAL_PORT"
    local saved_baud="$SERIAL_BAUD"

    CONN_TYPE="serial"
    SERIAL_PORT="$port"
    SERIAL_BAUD="$baud"

    local resp
    resp=$(send 0x10 $((PASS & 0xFF)) $(( (PASS >> 8) & 0xFF )) \
                 $(( (PASS >> 16) & 0xFF )) $(( (PASS >> 24) & 0xFF )) 2>/dev/null) || resp=""

    CONN_TYPE="$saved_type"
    SERIAL_PORT="$saved_port"
    SERIAL_BAUD="$saved_baud"

    # Минимальная проверка: длина + код ошибки 00
    if [[ ${#resp} -ge 10 && "${resp:6:2}" == "00" ]]; then
        return 0
    fi
    return 1
}

# Автопоиск ККТ на всех доступных COM-портах
auto_detect_serial() {
    local ports
    ports=$(list_serial_ports)
    if [[ -z "$ports" ]]; then
        whiptail --msgbox "COM-порты не найдены.\n\nПодключите ККТ по USB и убедитесь,\nчто драйвер создал /dev/ttyACM* или /dev/ttyUSB*." 11 60
        return 1
    fi

    local found=()
    local p baud
    # Пробуем типичные скорости
    local bauds=(115200 57600 38400 19200 9600)

    whiptail --title "Автопоиск" --infobox "Идёт поиск ККТ на COM-портах...\nЭто может занять несколько секунд." 8 55

    for p in $ports; do
        for baud in "${bauds[@]}"; do
            if probe_kkt_on_port "$p" "$baud"; then
                found+=("$p|$baud")
                break
            fi
        done
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        local noaccess=""
        local p
        for p in /dev/ttyACM* /dev/ttyUSB*; do
            if [[ -e "$p" ]] && ! port_accessible "$p"; then
                noaccess+="$p (нет прав доступа)\n"
            fi
        done
        local hint=""
        if [[ -n "$noaccess" ]]; then
            hint="\nНайдены порты без прав доступа:\n${noaccess}\nДобавьте себя в группу dialout:\n  sudo usermod -aG dialout \$USER\nи перезапустите сессию (или запустите скрипт через sudo).\n"
        fi
        whiptail --msgbox "ККТ на COM-портах не найдена.\n\nПроверенные порты:\n$ports\n\nПроверьте пароль, кабель и питание.\n$hint" 20 60
        return 1
    fi

    if [[ ${#found[@]} -eq 1 ]]; then
        local item="${found[0]}"
        SERIAL_PORT="${item%%|*}"
        SERIAL_BAUD="${item##*|}"
        CONN_TYPE="serial"
        save_config
        whiptail --msgbox "Найдена ККТ:\n\nПорт: $SERIAL_PORT\nСкорость: $SERIAL_BAUD\n\nПодключение переключено на COM." 12 50
        return 0
    fi

    # Несколько устройств — даём выбрать
    local menu_items=()
    local i=1
    for item in "${found[@]}"; do
        local prt="${item%%|*}"
        local bd="${item##*|}"
        menu_items+=("$i" "$prt @ $bd")
        ((i++))
    done

    local choice
    choice=$(whiptail --title "Найдено несколько ККТ" \
        --menu "Выберите устройство:" 16 60 8 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    [[ $? -ne 0 || -z "$choice" ]] && return 1

    local selected="${found[$((choice-1))]}"
    SERIAL_PORT="${selected%%|*}"
    SERIAL_BAUD="${selected##*|}"
    CONN_TYPE="serial"
    save_config
    whiptail --msgbox "Выбрано:\n$SERIAL_PORT @ $SERIAL_BAUD" 9 45
    return 0
}

# Ручной выбор порта из списка
menu_select_serial_port() {
    local all
    all=$(list_serial_ports_all)
    if [[ -z "$all" ]]; then
        whiptail --msgbox "COM-порты не найдены." 8 45
        return 1
    fi

    local menu_items=()
    local p
    while IFS= read -r p; do
        if port_accessible "$p"; then
            menu_items+=("$p" "$p")
        else
            menu_items+=("$p" "$p  [нет прав доступа]")
        fi
    done <<< "$all"

    local choice
    choice=$(whiptail --title "Выбор COM-порта" \
        --menu "Текущий: ${SERIAL_PORT:-не выбран}\nБез прав доступа порты помечены [нет прав доступа]\n(sudo usermod -aG dialout \$USER)" 20 70 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    [[ $? -ne 0 || -z "$choice" ]] && return 1

    if ! port_accessible "$choice"; then
        whiptail --msgbox "Нет прав доступа к $choice\n(владелец: root, группа: dialout).\n\nВыполните:\n  sudo usermod -aG dialout \$USER\nи перезапустите сессию,\nлибо запустите скрипт через sudo." 12 60
        return 1
    fi

    SERIAL_PORT="$choice"
    CONN_TYPE="serial"
    save_config
    return 0
}

# ---------- Меню Параметры ----------

menu_params() {
    while true; do
        local type_label
        if [[ "$CONN_TYPE" == "serial" ]]; then
            type_label="COM-порт"
        else
            type_label="Сеть (TCP)"
        fi

        choice=$(whiptail --title "Параметры подключения" \
            --menu "Сейчас: $(conn_str)   пароль=$PASS" 18 72 10 \
            "1" "Тип соединения: $type_label" \
            "2" "Автопоиск ККТ на COM-портах" \
            "3" "Выбрать COM-порт вручную" \
            "4" "Скорость COM (сейчас $SERIAL_BAUD)" \
            "5" "IP-адрес (сеть)" \
            "6" "TCP-порт (сеть)" \
            "7" "Пароль системного администратора" \
            "8" "Проверить связь с ККТ" \
            "0" "Назад" \
            3>&1 1>&2 2>&3)

        case $choice in
            1)
                local new_type
                new_type=$(whiptail --title "Тип соединения" \
                    --menu "Выберите тип:" 12 50 3 \
                    "net"    "Сеть (RNDIS / Ethernet)" \
                    "serial" "COM-порт (USB-serial)" \
                    3>&1 1>&2 2>&3)
                if [[ $? -eq 0 && -n "$new_type" ]]; then
                    CONN_TYPE="$new_type"
                    if [[ "$CONN_TYPE" == "serial" && -z "$SERIAL_PORT" ]]; then
                        # Сразу предложить автопоиск
                        if whiptail --yesno "COM-порт ещё не выбран.\nЗапустить автопоиск?" 9 50; then
                            auto_detect_serial
                        fi
                    fi
                    save_config
                fi
                ;;
            2)
                auto_detect_serial
                ;;
            3)
                menu_select_serial_port
                ;;
            4)
                local new_baud
                new_baud=$(whiptail --title "Скорость COM" \
                    --menu "Выберите скорость:" 15 40 6 \
                    "115200" "115200 (рекомендуется)" \
                    "9600"   "9600" \
                    "57600"  "57600" \
                    "38400"  "38400" \
                    "19200"  "19200" \
                    3>&1 1>&2 2>&3)
                if [[ $? -eq 0 && -n "$new_baud" ]]; then
                    SERIAL_BAUD="$new_baud"
                    save_config
                fi
                ;;
            5)
                new=$(whiptail --title "IP-адрес" --inputbox "Введите IP-адрес:" 8 50 "$HOST" 3>&1 1>&2 2>&3)
                if [[ $? -eq 0 && -n "$new" ]]; then
                    HOST="$new"
                    save_config
                fi
                ;;
            6)
                new=$(whiptail --title "TCP-порт" --inputbox "Введите порт:" 8 40 "$PORT" 3>&1 1>&2 2>&3)
                if [[ $? -eq 0 && -n "$new" ]]; then
                    PORT="$new"
                    save_config
                fi
                ;;
            7)
                new=$(whiptail --title "Пароль" --passwordbox "Введите пароль системного администратора:" 8 50 3>&1 1>&2 2>&3)
                if [[ $? -eq 0 && "$new" =~ ^[0-9]+$ ]]; then
                    PASS="$new"
                    save_config
                    whiptail --msgbox "Пароль обновлён" 7 30
                elif [[ $? -eq 0 ]]; then
                    whiptail --msgbox "Пароль должен состоять только из цифр" 7 40
                fi
                ;;
            8)
                cmd_short_status
                ;;
            0|"") return ;;
        esac
    done
}

# ---------- Работа с таблицами ----------

# Получаем список существующих таблиц
get_tables_list() {
    local -a tables=()
    for t in $(seq 1 30); do
        local info
        if info=$(cmd_table_struct $t 2>/dev/null); then
            IFS='|' read -r name rows fields <<< "$info"
            # Формат: "номер|имя|рядов|полей"
            tables+=("$t|$name|$rows|$fields")
        fi
    done
    printf '%s\n' "${tables[@]}"
}

# Меню выбора таблицы
menu_select_table() {
    local tables
    tables=$(get_tables_list)

    if [[ -z "$tables" ]]; then
        whiptail --msgbox "Таблицы не найдены.\nПроверьте связь и пароль." 9 50
        return 1
    fi

    local menu_items=()
    while IFS='|' read -r num name rows fields; do
        menu_items+=("$num" "$name  (рядов:$rows полей:$fields)")
    done <<< "$tables"

    local choice
    choice=$(whiptail --title "Выбор таблицы" \
        --menu "Выберите таблицу:" 20 70 12 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$choice" ]] && return 1
    echo "$choice"
}

# Просмотр всех непустых полей таблицы
menu_batch_read() {
    local table=$1
    local info
    if ! info=$(cmd_table_struct $table); then
        whiptail --msgbox "Не удалось получить структуру таблицы $table" 8 50
        return
    fi
    IFS='|' read -r name rows fields <<< "$info"

    local data
    data=$(cmd_batch_read $table)

    if [[ -z "$data" ]]; then
        whiptail --msgbox "Таблица $table пуста или все значения нулевые" 8 50
        return
    fi

    local display=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local row field val
        row=${line%%:*}
        local rest=${line#*:}
        field=${rest%%=*}
        val=${rest#*=}
        local display_val
        display_val=$(format_value "$val")
        display+="${name}"$'\n'"Ряд:$row Поле:$field"$'\n'"$display_val"$'\n\n'
    done <<< "$data"

    whiptail --title "Таблица $table: $name" --msgbox "$display" 40 80
}

# Резервное копирование / восстановление
menu_backup_restore() {
    local table=$1

    while true; do
        local choice
        choice=$(whiptail --title "Бэкап таблицы" \
            --menu "Выберите действие:" 15 60 3 \
            "1" "Создать бэкап" \
            "2" "Восстановить из бэкапа" \
            "0" "Назад" \
            3>&1 1>&2 2>&3)

        case $choice in
            1)
                local bfile
                bfile=$(cmd_backup_table $table)
                if [[ -n "$bfile" && -f "$bfile" ]]; then
                    whiptail --msgbox "Бэкап сохранён:"$'\n'"$bfile" 8 60
                else
                    whiptail --msgbox "Ошибка создания бэкапа" 8 40
                fi
                ;;
            2)
                local selected=""
                local menu_items=()
                for bf in "$HOME"/.kkt_backup_table*; do
                    [[ -f "$bf" ]] || continue
                    local bn
                    bn=$(basename "$bf")
                    menu_items+=("$bn" "Файл: $bn")
                done
                if [[ ${#menu_items[@]} -eq 0 ]]; then
                    whiptail --msgbox "Файлы бэкапа не найдены" 8 40
                    continue
                fi
                selected=$(whiptail --title "Выбор бэкапа" \
                    --menu "Выберите файл бэкапа:" 20 70 10 \
                    "${menu_items[@]}" \
                    3>&1 1>&2 2>&3)
                [[ $? -ne 0 || -z "$selected" ]] && continue
                local result
                result=$(cmd_restore_table "$table" "$HOME/$selected" 2>&1)
                whiptail --msgbox "Результат: $result" 8 50
                ;;
            0|"") return ;;
        esac
    done
}

# Просмотр и редактирование параметров выбранной таблицы
menu_table_params() {
    local table=$1

    local info
    if ! info=$(cmd_table_struct $table); then
        whiptail --msgbox "Не удалось получить структуру таблицы $table" 8 50
        return
    fi

    IFS='|' read -r name rows fields <<< "$info"

    while true; do
        local menu_items=()
        local idx=1

        for ((r=1; r<=rows; r++)); do
            for ((f=1; f<=fields; f++)); do
                local val
                val=$(cmd_read_table $table $r $f 2>/dev/null)
                local display="?"
                if [[ $? -eq 0 ]]; then
                    display=$(format_value "$val")
                fi
                menu_items+=("$r:$f" "Ряд $r / Поле $f  =  $display")
                ((idx++))
            done
        done

        menu_items+=("b" "Пакетное чтение всех полей")
        menu_items+=("B" "Бэкап / Восстановление")

        local choice
        choice=$(whiptail --title "Таблица $table: $name" \
            --menu "Выберите параметр:\n(рядов: $rows, полей: $fields)" 25 90 15 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3)

        [[ $? -ne 0 || -z "$choice" ]] && return

        if [[ "$choice" == "b" ]]; then
            menu_batch_read "$table"
            continue
        fi
        if [[ "$choice" == "B" ]]; then
            menu_backup_restore "$table"
            continue
        fi

        local row=${choice%%:*}
        local field=${choice##*:}

        local current
        current=$(cmd_read_table $table $row $field 2>/dev/null)
        local current_text="не удалось прочитать"
        if [[ $? -eq 0 ]]; then
            current_text=$(format_value "$current")
        fi

        local new_val
        new_val=$(whiptail --title "Редактирование" \
            --inputbox "Таблица $table / Ряд $row / Поле $field\n\nТекущее значение:\n$current_text\n\nНовое значение (HEX):" \
            14 60 3>&1 1>&2 2>&3)

        [[ $? -ne 0 || -z "$new_val" ]] && continue

        new_val=$(echo "$new_val" | tr 'a-f' 'A-F' | tr -d ' ')
        if ! [[ "$new_val" =~ ^[0-9A-F]+$ ]]; then
            whiptail --msgbox "Неверный формат HEX" 7 40
            continue
        fi
        if (( ${#new_val} % 2 != 0 )); then
            new_val="0$new_val"
        fi

        local result
        result=$(cmd_write_table $table $row $field "$new_val")
        if [[ "$result" == "OK" ]]; then
            whiptail --msgbox "Запись успешна" 7 30
        else
            whiptail --msgbox "Ошибка записи: $result" 8 50
        fi
    done
}

# Главное меню таблиц
menu_tables() {
    while true; do
        local table
        table=$(menu_select_table) || return

        menu_table_params "$table"
    done
}

# ---------- Меню: Сервис ----------

menu_service() {
    while true; do
        local choice
        choice=$(whiptail --title "Сервис" \
            --menu "Выберите действие:" 15 60 4 \
            "1" "Установить текущую дату/время" \
            "2" "Тестовый прогон (0x19)" \
            "3" "Тех. обнуление (0x16)" \
            "0" "Назад" \
            3>&1 1>&2 2>&3)

        case $choice in
            1) cmd_sync_time ;;
            2) cmd_test_run ;;
            3) confirm_tech_reset ;;
            0|"") return ;;
        esac
    done
}

# ---------- Меню: Настройка ККТ ----------

menu_kkt() {
    while true; do
        local choice
        choice=$(whiptail --title "Настройка ККТ" \
            --menu "Выберите действие:" 14 60 3 \
            "1" "Включить RNDIS" \
            "2" "Установить IP (статический)" \
            "0" "Назад" \
            3>&1 1>&2 2>&3)

        case $choice in
            1) cmd_set_rndis ;;
            2) cmd_set_ip ;;
            0|"") return ;;
        esac
    done
}

# ---------- Подтверждение тех. обнуления (двойное) ----------

confirm_tech_reset() {
    if ! whiptail --title "Технологическое обнуление" \
        --yesno "ВНИМАНИЕ!\n\nТехнологическое обнуление полностью очистит\nнастройки и фискальную память ККТ.\nВыполняется только после вскрытия пломбы.\n\nВы ТОЧНО уверены, что хотите продолжить?" 14 60; then
        return 1
    fi
    if ! whiptail --title "Технологическое обнуление" \
        --yesno "ПОСЛЕДНЕЕ ПРЕДУПРЕЖДЕНИЕ!\n\nОперация необратима.\nВыполнить тех. обнуление?" 10 55; then
        return 1
    fi
    cmd_tech_reset
}

# ---------- Главное меню ----------

main_menu() {
    while true; do
        choice=$(whiptail --title "Управление ККТ Штрих-М" \
            --menu "Подключение: $(conn_str)" 17 65 7 \
            "1" "Настройка соединения" \
            "2" "Информация о ККТ" \
            "3" "Сервис" \
            "4" "Настройка" \
            "5" "Перезагрузка ККТ" \
            "0" "Выход" \
            3>&1 1>&2 2>&3)

        case $choice in
            1) menu_params ;;
            2) cmd_full_status ;;
            3) menu_service ;;
            4) menu_kkt ;;
            5) cmd_reboot ;;
            0|"")
                clear
                exit 0
                ;;
        esac
    done
}

# ---------- Запуск ----------
if ! command -v whiptail &>/dev/null; then
    echo "whiptail не найден. Установите: sudo apt install whiptail"
    exit 1
fi
if ! command -v xxd &>/dev/null; then
    echo "xxd не найден. Установите: sudo apt install xxd  (или vim-common)"
    exit 1
fi
# stty и timeout нужны для serial
if [[ "$CONN_TYPE" == "serial" ]]; then
    if ! command -v stty &>/dev/null || ! command -v timeout &>/dev/null; then
        echo "Для работы с COM-портом нужны stty и timeout (пакет coreutils)."
        sleep 2
    fi
fi

save_config
main_menu