#!/bin/sh
# ============================================================
# E5573 Control Script - FINAL v22
# Mode SMS = GSM only (01) → auto attach GSM 900
# State LTE disimpan & di-restore otomatis
# ============================================================

BASE="http://192.168.8.1"
USER="admin"
PASS='r3z12n'
HDR="/tmp/e5573_hdr"
WAN_CACHE="/tmp/e5573_wan.cache"
WAN_CACHE_TTL=30
TRANSIT_BAND_DEFAULT="1"

# Mode jaringan
NETWORK_MODE_IP="03"       # LTE only — untuk lock band & ganti IP
NETWORK_MODE_SMS="01"      # GSM only — auto attach GSM 900 (B8), cepat
NETWORK_MODE_AUTO="00"     # Auto (fallback)

# State LTE disimpan sebelum switch ke GSM (untuk restore)
_SAVED_LTE_BAND=""
_SAVED_LTE_NETBAND=""
_SAVED_LTE_MODE=""

# ============================================================
# HELPER
# ============================================================

extract_t1() {
    local T
    T=$(grep -i "^__RequestVerificationTokenone:" "$HDR" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | tr -d '\r\n')
    [ -z "$T" ] && T=$(grep -i "^__RequestVerificationToken:" "$HDR" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | tr -d '\r\n' | cut -d'#' -f1)
    echo "$T"
}

extract_sc() {
    grep -i "^set-cookie:" "$HDR" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | sed 's/;.*//' | tr -d '\r\n'
}

xval() {
    echo "$1" | tr -d '\r\n' | sed -n "s:.*<$2>\([^<]*\)</$2>.*:\1:p"
}

decode_sms() {
    echo "$1" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&#x2F;/\//g; s/&#x3D;/=/g'
}

xml_escape() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

band_to_bit() {
    case "$1" in
        800|20)  echo "80000" ;;
        850|5)   echo "10" ;;
        900|8)   echo "80" ;;
        1800|3)  echo "4" ;;
        1900|2)  echo "2" ;;
        2100|1)  echo "1" ;;
        2300|40) echo "8000000000" ;;
        2500|41) echo "10000000000" ;;
        2600|7)  echo "40" ;;
        *)       return 1 ;;
    esac
}

hex_to_label() {
    case "$1" in
        7FFFFFFFFFFFFFFF) echo "Auto (semua band)" ;;
        80000)            echo "800MHz (B20)" ;;
        10)               echo "850MHz (B5)" ;;
        80)               echo "900MHz (B8)" ;;
        4)                echo "1800MHz (B3)" ;;
        2)                echo "1900MHz (B2)" ;;
        1)                echo "2100MHz (B1)" ;;
        8000000000)       echo "2300MHz (B40)" ;;
        10000000000)      echo "2500MHz (B41)" ;;
        40)               echo "2600MHz (B7)" ;;
        5)                echo "2100(B1) + 1800(B3)" ;;
        11)               echo "2100(B1) + 850(B5)" ;;
        15)               echo "2100(B1) + 1800(B3) + 850(B5)" ;;
        8000000005)       echo "2100(B1) + 1800(B3) + 2300(B40)" ;;
        8000000015)       echo "2100(B1) + 1800(B3) + 850(B5) + 2300(B40)" ;;
        *)                echo "Custom hex: $1" ;;
    esac
}

# ============================================================
# CORE API
# ============================================================

_login_and_get_creds() {
    local SR SES_A TOK_A H1 B1 H2 B2 REQ
    SR=$(curl -s -m 5 "$BASE/api/webserver/SesTokInfo" | tr -d '\r\n')
    SES_A=$(echo "$SR" | sed -n 's:.*<SesInfo>\([^<]*\)</SesInfo>.*:\1:p')
    TOK_A=$(echo "$SR" | sed -n 's:.*<TokInfo>\([^<]*\)</TokInfo>.*:\1:p')
    [ -z "$TOK_A" ] && return 1
    H1=$(printf '%s' "$PASS" | openssl dgst -sha256 -r | awk '{print $1}')
    B1=$(printf '%s' "$H1" | openssl base64 -A)
    H2=$(printf '%s' "${USER}${B1}${TOK_A}" | openssl dgst -sha256 -r | awk '{print $1}')
    B2=$(printf '%s' "$H2" | openssl base64 -A)
    REQ="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Username>${USER}</Username><Password>${B2}</Password><password_type>4</password_type></request>"
    curl -s -m 8 -X POST -D "$HDR" \
        -H "Cookie: $SES_A" \
        -H "__RequestVerificationToken: $TOK_A" \
        -H "Content-Type: application/xml" \
        --data "$REQ" "$BASE/api/user/login" >/dev/null
    SES_B=$(extract_sc)
    T1=$(extract_t1)
    [ -z "$SES_B" ] && return 1
    [ -z "$T1" ] && return 1
    return 0
}

auth_post() {
    local URL="$1" BODY="$2"
    _login_and_get_creds || { echo "ERR_LOGIN"; return 1; }
    curl -s -m 15 -X POST \
        -H "Cookie: $SES_B" \
        -H "__RequestVerificationToken: $T1" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Origin: http://192.168.8.1" \
        -H "Referer: http://192.168.8.1/html/reboot.html" \
        --data "$BODY" "$URL" 2>/dev/null | tr -d '\r\n'
}

auth_get() {
    local URL="$1"
    _login_and_get_creds || { echo "ERR_LOGIN"; return 1; }
    curl -s -m 10 \
        -H "Cookie: $SES_B" \
        -H "__RequestVerificationToken: $T1" \
        "$URL" 2>/dev/null | tr -d '\r\n'
}

simple_get() {
    local URL="$1" SR SES TOK
    SR=$(curl -s -m 5 "$BASE/api/webserver/SesTokInfo" | tr -d '\r\n')
    SES=$(echo "$SR" | sed -n 's:.*<SesInfo>\([^<]*\)</SesInfo>.*:\1:p')
    TOK=$(echo "$SR" | sed -n 's:.*<TokInfo>\([^<]*\)</TokInfo>.*:\1:p')
    curl -s -m 8 -H "Cookie: $SES" -H "__RequestVerificationToken: $TOK" "$URL" 2>/dev/null | tr -d '\r\n'
}

# ============================================================
# WAN IP
# ============================================================

get_wan_ip() {
    local NOW=$(date +%s) CACHED_TS=0 CACHED_VAL=""
    if [ -f "$WAN_CACHE" ]; then read CACHED_TS CACHED_VAL < "$WAN_CACHE" 2>/dev/null; fi
    if [ -n "$CACHED_VAL" ] && [ "${CACHED_TS:-0}" -gt 0 ] 2>/dev/null && [ $((NOW - CACHED_TS)) -lt "$WAN_CACHE_TTL" ]; then
        echo "$CACHED_VAL"; return 0
    fi
    local X IP
    X=$(auth_get "$BASE/api/device/information")
    IP=$(xval "$X" WanIPAddress)
    [ -z "$IP" ] && IP=$(echo "$X" | grep -o '<WanIPAddress>[^<]*</WanIPAddress>' | sed 's/<[^>]*>//g')
    case "$IP" in
        0.0.0.0|"") return 1 ;;
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "$NOW $IP" > "$WAN_CACHE"; echo "$IP"; return 0 ;;
        *) return 1 ;;
    esac
}
invalidate_wan_cache() { rm -f "$WAN_CACHE"; }

# ============================================================
# BAND SETTING & MODE SWITCHING
# ============================================================

_set_lte_band() {
    local HEXBAND="$1" NETBAND="${2:-3FFFFFFF}"
    local BODY="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><NetworkMode>${NETWORK_MODE_IP}</NetworkMode><NetworkBand>${NETBAND}</NetworkBand><LTEBand>${HEXBAND}</LTEBand></request>"
    local R=$(auth_post "$BASE/api/net/net-mode" "$BODY")
    case "$R" in *"<response>OK</response>"*) return 0 ;; *112003*) return 2 ;; *) return 1 ;; esac
}

# Switch mode jaringan on-the-fly (tanpa ubah band LTE kecuali mode GSM)
switch_network_mode() {
    local MODE="$1"
    local X=$(simple_get "$BASE/api/net/net-mode")
    local BAND=$(xval "$X" LTEBand)
    local NETBAND=$(xval "$X" NetworkBand)
    [ -z "$NETBAND" ] && NETBAND="3FFFFFFF"
    [ -z "$BAND" ] && BAND="7FFFFFFFFFFFFFFF"
    
    local BODY="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><NetworkMode>${MODE}</NetworkMode><NetworkBand>${NETBAND}</NetworkBand><LTEBand>${BAND}</LTEBand></request>"
    local R=$(auth_post "$BASE/api/net/net-mode" "$BODY")
    case "$R" in
        *"<response>OK</response>"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Switch ke GSM-only (untuk SMS, auto attach GSM 900)
_sms_mode_on() {
    echo "  ⏳ Simpan state LTE, switch ke GSM..."
    
    # Simpan state LTE
    local X=$(simple_get "$BASE/api/net/net-mode")
    _SAVED_LTE_BAND=$(xval "$X" LTEBand)
    _SAVED_LTE_NETBAND=$(xval "$X" NetworkBand)
    _SAVED_LTE_MODE=$(xval "$X" NetworkMode)
    [ -z "$_SAVED_LTE_BAND" ] && _SAVED_LTE_BAND="7FFFFFFFFFFFFFFF"
    [ -z "$_SAVED_LTE_NETBAND" ] && _SAVED_LTE_NETBAND="3FFFFFFF"
    [ -z "$_SAVED_LTE_MODE" ] && _SAVED_LTE_MODE="$NETWORK_MODE_IP"
    
    # Switch ke GSM only (01)
    local BODY="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><NetworkMode>${NETWORK_MODE_SMS}</NetworkMode><NetworkBand>3FFFFFFF</NetworkBand><LTEBand>7FFFFFFFFFFFFFFF</LTEBand></request>"
    if ! auth_post "$BASE/api/net/net-mode" "$BODY" | grep -q "OK"; then
        echo "  ⚠ Gagal switch ke GSM. Coba lanjut..."
        return 1
    fi
    
    # Tunggu attach GSM (biasanya 5-10 detik)
    local i=0
    while [ $i -lt 10 ]; do
        sleep 1
        local ST=$(simple_get "$BASE/api/monitoring/status" | xval ConnectionStatus)
        [ "$ST" = "901" ] && break
        i=$((i+1))
    done
    sleep 2
    return 0
}

# Restore ke LTE state semula
_sms_mode_off() {
    echo "  ⏳ Restore state LTE semula..."
    local BODY="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><NetworkMode>${_SAVED_LTE_MODE}</NetworkMode><NetworkBand>${_SAVED_LTE_NETBAND}</NetworkBand><LTEBand>${_SAVED_LTE_BAND}</LTEBand></request>"
    auth_post "$BASE/api/net/net-mode" "$BODY" >/dev/null 2>&1
    sleep 3
}

# ============================================================
# SMS CORE
# ============================================================

sms_total() {
    local BOX="${1:-1}" X
    X=$(auth_get "$BASE/api/sms/sms-count")
    case "$BOX" in
        1) xval "$X" LocalInbox ;;
        2) xval "$X" LocalOutbox ;;
        3) xval "$X" LocalDraft ;;
        *) echo "0" ;;
    esac
}

sms_unread() {
    local X=$(auth_get "$BASE/api/sms/sms-count")
    local U=$(xval "$X" LocalUnread)
    echo "${U:-0}"
}

sms_count_brief() {
    local X=$(auth_get "$BASE/api/sms/sms-count")
    local IN=$(xval "$X" LocalInbox); local UN=$(xval "$X" LocalUnread)
    local OUT=$(xval "$X" LocalOutbox); local DRAFT=$(xval "$X" LocalDraft)
    echo "📨 Inbox: ${IN:-0} (Unread: ${UN:-0}) | Outbox: ${OUT:-0} | Konsep: ${DRAFT:-0}"
}

sms_fetch_page() {
    local PAGE="$1" PER_PAGE="${2:-10}" BOX="${3:-1}" UNREAD_ONLY="${4:-0}"
    local REQ="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><PageIndex>${PAGE}</PageIndex><ReadCount>${PER_PAGE}</ReadCount><BoxType>${BOX}</BoxType><SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>${UNREAD_ONLY}</UnreadPreferred></request>"
    auth_post "$BASE/api/sms/sms-list" "$REQ"
}

# Kirim SMS — auto switch ke GSM (untuk 900), kirim, restore LTE
sms_send() {
    local PHONE="$1" CONTENT="$2" IS_REPLY="${3:-0}" SKIP_MODE_SWITCH="${4:-0}"
    local MAX_ATTEMPT=3 ATTEMPT=1

    [ -z "$PHONE" ] && { echo "  ❌ Nomor kosong"; return 1; }
    [ -z "$CONTENT" ] && { echo "  ❌ Pesan kosong"; return 1; }

    local CLEAN_PHONE=$(echo "$PHONE" | sed 's/^+//; s/[^0-9]//g')
    [ -z "$CLEAN_PHONE" ] && { echo "  ❌ Nomor tidak valid"; return 1; }

    local LEN=$(printf '%s' "$CONTENT" | wc -c | tr -d ' ')
    local CONTENT_XML=$(xml_escape "$CONTENT")
    local NOW=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo "  ┌─ Mengirim SMS ────────────────────────────"
    echo "  │ Ke    : $PHONE (→ $CLEAN_PHONE)"
    echo "  │ Panjang: $LEN byte"
    echo "  │ Mode  : $([ "$IS_REPLY" = "1" ] && echo "Balasan" || echo "SMS Baru")"
    echo "  │ GSM   : auto-attach (900MHz jika tersedia)"
    echo "  └───────────────────────────────────────────"

    # Switch ke GSM-only
    if [ "$SKIP_MODE_SWITCH" != "1" ]; then
        _sms_mode_on
    fi

    local BODY="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>-1</Index><Phones><Phone>${CLEAN_PHONE}</Phone></Phones><Sca></Sca><Content>${CONTENT_XML}</Content><Length>${LEN}</Length><Reserved>1</Reserved><Date>${NOW}</Date></request>"
    local SENT=0

    while [ $ATTEMPT -le $MAX_ATTEMPT ]; do
        echo "  ▶ Percobaan $ATTEMPT/$MAX_ATTEMPT..."
        local R=$(auth_post "$BASE/api/sms/send-sms" "$BODY")
        case "$R" in
            *"<response>OK</response>"*)
                echo "  ✅ BERHASIL terkirim ke jaringan"
                SENT=1
                break
                ;;
            *113001*) echo "  ❌ Storage SMS penuh"; break ;;
            *113002*) echo "  ❌ Nomor tidak valid"; break ;;
            *113009*) echo "  ❌ Nomor kosong"; break ;;
            *)
                echo "  ⚠ Respons: $(echo "$R" | cut -c1-100)"
                if [ $ATTEMPT -lt $MAX_ATTEMPT ]; then echo "  ⏳ Tunggu 3 detik..."; sleep 3; fi
                ;;
        esac
        ATTEMPT=$((ATTEMPT+1))
    done

    # Restore ke LTE state
    if [ "$SKIP_MODE_SWITCH" != "1" ]; then
        _sms_mode_off
    fi

    if [ $SENT -eq 1 ]; then
        return 0
    fi
    echo "  ❌ GAGAL terkirim."
    echo "  💡 Jika masuk Konsep, cek pulsa atau SMSC."
    return 1
}

# ============================================================
# SMS DELETE
# ============================================================

sms_delete_single() {
    local BOX="$1" NUM="$2" PAGE="$3" PER_PAGE="$4" UNREAD="$5"
    local RESP MSG IDX PHONE CONTENT
    RESP=$(sms_fetch_page "$PAGE" "$PER_PAGE" "$BOX" "$UNREAD")
    MSG=$(echo "$RESP" | sed 's:</Message>:</Message>\n:g' | grep '<Message>' | sed -n "${NUM}p")
    [ -z "$MSG" ] && { echo "  ❌ Pesan #$NUM tidak ada"; return 1; }

    IDX=$(xval "$MSG" Index)
    PHONE=$(decode_sms "$(xval "$MSG" Phone)")
    CONTENT=$(decode_sms "$(xval "$MSG" Content)")
    [ ${#CONTENT} -gt 45 ] && CONTENT="${CONTENT:0:42}..."

    echo ""
    echo "  ┌─ Pesan yang akan dihapus ────────────────"
    echo "  │ Dari  : $PHONE"
    echo "  │ Isi   : $CONTENT"
    echo "  └──────────────────────────────────────────"
    printf "  Konfirmasi hapus? (y/n): "; read yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "  Dibatalkan"; return 0; }

    local R=$(auth_post "$BASE/api/sms/delete-sms" "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>${IDX}</Index></request>")
    case "$R" in *"<response>OK</response>"*) echo "  ✅ Pesan dihapus"; return 0 ;; *) echo "  ❌ Gagal: $R"; return 1 ;; esac
}

sms_delete_all() {
    local BOX="$1" BOXNAME="Inbox"
    [ "$BOX" = "2" ] && BOXNAME="Outbox"
    [ "$BOX" = "3" ] && BOXNAME="Konsep"
    local TOTAL=$(sms_total "$BOX")
    [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ] && { echo "  Tidak ada pesan."; return 0; }

    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║ ⚠  HAPUS SEMUA PESAN — $BOXNAME"
    echo "  ╠══════════════════════════════════════════╣"
    echo "  ║ Jumlah : $TOTAL pesan"
    echo "  ╚══════════════════════════════════════════╝"
    printf "  Ketik angka $TOTAL untuk konfirmasi: "; read confirm
    [ "$confirm" != "$TOTAL" ] && { echo "  ❌ Dibatalkan"; return 1; }

    echo "  ▶ Menghapus $TOTAL pesan..."
    local DELETED=0 ITER=0
    while [ $ITER -lt 30 ]; do
        local RESP=$(sms_fetch_page 1 50 "$BOX" 0)
        local MSGS=$(echo "$RESP" | sed 's:</Message>:</Message>\n:g' | grep '<Message>')
        [ -z "$MSGS" ] && break
        local BODY='<?xml version="1.0" encoding="UTF-8"?><request>'
        local CNT=0
        for idx in $(echo "$MSGS" | sed -n 's:.*<Index>\([^<]*\)</Index>.*:\1:p'); do
            BODY="$BODY<Index>${idx}</Index>"; CNT=$((CNT+1))
        done
        BODY="$BODY</request>"
        [ $CNT -eq 0 ] && break
        local R=$(auth_post "$BASE/api/sms/delete-sms" "$BODY")
        if echo "$R" | grep -q "OK"; then
            DELETED=$((DELETED + CNT)); printf "    ✓ %d/%d\r" "$DELETED" "$TOTAL"
        else echo ""; break; fi
        ITER=$((ITER+1))
    done
    echo ""
    echo "  ✅ Terhapus: $DELETED pesan"
}

# ============================================================
# SMS BROWSER
# ============================================================

sms_browse() {
    local BOX="${1:-1}" UNREAD="${2:-0}"
    local PER_PAGE=10 PAGE=1 TOTAL PAGES BOXNAME
    case "$BOX" in 1) BOXNAME="INBOX" ;; 2) BOXNAME="OUTBOX" ;; 3) BOXNAME="KONSEP (DRAFT)" ;; esac

    while true; do
        clear
        TOTAL=$(sms_total "$BOX"); [ -z "$TOTAL" ] && TOTAL=0
        PAGES=$(( (TOTAL + PER_PAGE - 1) / PER_PAGE )); [ "$PAGES" -lt 1 ] && PAGES=1; [ "$PAGE" -gt "$PAGES" ] && PAGE=$PAGES

        echo "══════════════════════════════════════════════"
        local U=$(sms_unread)
        if [ "$UNREAD" = "1" ]; then
            echo "   $BOXNAME  —  Total: $TOTAL  |  Unread: $U  |  Hal $PAGE/$PAGES (Filter: Unread)"
        else
            echo "   $BOXNAME  —  Total: $TOTAL pesan  (Unread: $U)  |  Hal $PAGE/$PAGES"
        fi
        echo "══════════════════════════════════════════════"

        local RESP=$(sms_fetch_page "$PAGE" "$PER_PAGE" "$BOX" "$UNREAD")
        local MSGS=$(echo "$RESP" | sed 's:</Message>:</Message>\n:g' | grep '<Message>')

        if [ -z "$MSGS" ]; then
            echo "  (Tidak ada pesan di halaman ini)"
        else
            local LOCAL_NUM=0
            echo "$MSGS" | while IFS= read -r MSG; do
                LOCAL_NUM=$((LOCAL_NUM+1))
                local PHONE CONTENT DATE STATUS
                PHONE=$(decode_sms "$(xval "$MSG" Phone)"); CONTENT=$(decode_sms "$(xval "$MSG" Content)")
                DATE=$(xval "$MSG" Date); STATUS=$(xval "$MSG" Smstat)
                
                printf "  [%2d] %-18s %s %s\n" "$LOCAL_NUM" "$(echo "$PHONE" | cut -c1-18)" "${DATE:5:14}" "$([ "$STATUS" = "0" ] && echo "●" || echo "○")"
                
                if command -v fold >/dev/null 2>&1; then
                    echo "$CONTENT" | fold -s -w 65 | sed 's/^/        /'
                else
                    echo "        $CONTENT"
                fi
                echo ""
            done
        fi

        echo "──────────────────────────────────────────────"
        echo "  [n]Next [p]Prev [g]Goto [r]Refresh [f]Filter"
        echo "  [d]Hapus(1-$PER_PAGE)  [D]Hapus SEMUA"
        [ "$BOX" != "3" ] && echo "  [b]Balas(1-$PER_PAGE)  [s]Kirim baru"
        [ "$BOX" = "3" ] && echo "  [k]Kirim Draft(1-$PER_PAGE)  [s]Kirim baru"
        echo "  [q]Kembali"
        printf "  Pilih: "; read cmd
        case "$cmd" in
            n|N) [ $PAGE -lt $PAGES ] && PAGE=$((PAGE+1)) ;;
            p|P) [ $PAGE -gt 1 ] && PAGE=$((PAGE-1)) ;;
            g|G) printf "  Halaman (1-$PAGES): "; read p
                 case "$p" in ''|*[!0-9]*) echo "  ❌ Harus angka" ;; *) [ "$p" -ge 1 ] && [ "$p" -le "$PAGES" ] && PAGE=$p ;; esac ;;
            r|R) ;;
            f|F) [ "$BOX" = "1" ] && { UNREAD=$((1 - UNREAD)); PAGE=1; } ;;
            q|Q) return ;;
            d)   printf "  Hapus nomor [1-$PER_PAGE]: "; read num
                 case "$num" in ''|*[!0-9]*) echo "  ❌ Harus angka" ;; *) [ "$num" -ge 1 ] && [ "$num" -le "$PER_PAGE" ] && sms_delete_single "$BOX" "$num" "$PAGE" "$PER_PAGE" "$UNREAD" ;; esac
                 printf "\n  Enter..."; read _ ;;
            D)   sms_delete_all "$BOX"; printf "\n  Enter..."; read _ ;;
            s|S) clear
                 printf "  Nomor: "; read phone
                 [ -z "$phone" ] && { printf "\n  Enter..."; read _; continue; }
                 printf "  Pesan: "; read content
                 [ -z "$content" ] && { echo "  ❌ Kosong"; printf "\n  Enter..."; read _; continue; }
                 sms_send "$phone" "$content" 0
                 printf "\n  Enter..."; read _ ;;
            b|B) [ "$BOX" = "3" ] && continue
                 printf "  Balas nomor [1-$PER_PAGE]: "; read num
                 case "$num" in
                     ''|*[!0-9]*) echo "  ❌ Harus angka" ;;
                     *) if [ "$num" -ge 1 ] && [ "$num" -le "$PER_PAGE" ]; then
                            local MSG=$(echo "$RESP" | sed 's:</Message>:</Message>\n:g' | grep '<Message>' | sed -n "${num}p")
                            if [ -z "$MSG" ]; then echo "  ❌ Pesan #$num tidak ada"
                            else
                                local PHONE=$(decode_sms "$(xval "$MSG" Phone)")
                                local ORIG=$(decode_sms "$(xval "$MSG" Content)")
                                echo ""
                                echo "  ┌─ Balas ke ────────────────────────────────"
                                echo "  │ Nomor : $PHONE"
                                [ ${#ORIG} -gt 60 ] && ORIG="${ORIG:0:57}..."
                                echo "  │ Pesan : $ORIG"
                                echo "  └───────────────────────────────────────────"
                                printf "  Balasan: "; read reply
                                [ -n "$reply" ] && sms_send "$PHONE" "$reply" 1 || echo "  ❌ Kosong"
                            fi
                        else echo "  ❌ Max 1-$PER_PAGE"; fi ;;
                 esac
                 printf "\n  Enter..."; read _ ;;
            k|K) [ "$BOX" != "3" ] && continue
                 printf "  Kirim Draft nomor [1-$PER_PAGE]: "; read num
                 case "$num" in
                     ''|*[!0-9]*) echo "  ❌ Harus angka" ;;
                     *) if [ "$num" -ge 1 ] && [ "$num" -le "$PER_PAGE" ]; then
                            local MSG=$(echo "$RESP" | sed 's:</Message>:</Message>\n:g' | grep '<Message>' | sed -n "${num}p")
                            if [ -z "$MSG" ]; then echo "  ❌ Draft #$num tidak ada"
                            else
                                local IDX=$(xval "$MSG" Index)
                                local PHONE=$(decode_sms "$(xval "$MSG" Phone)")
                                local CONTENT=$(decode_sms "$(xval "$MSG" Content)")
                                echo ""
                                if sms_send "$PHONE" "$CONTENT" 0; then
                                    auth_post "$BASE/api/sms/delete-sms" "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>${IDX}</Index></request>" >/dev/null
                                    echo "  ✅ Draft terkirim & dihapus dari Konsep"
                                fi
                            fi
                        else echo "  ❌ Max 1-$PER_PAGE"; fi ;;
                 esac
                 printf "\n  Enter..."; read _ ;;
            *) echo "  ❌ Pilihan tidak dikenal"; sleep 1 ;;
        esac
    done
}

# ============================================================
# AKSI LAIN
# ============================================================

do_reboot() {
    invalidate_wan_cache
    echo "▶ Reboot..."
    local R=$(auth_post "$BASE/api/device/control" '<?xml version="1.0" encoding="UTF-8"?><request><Control>1</Control></request>')
    case "$R" in *"<response>OK</response>"*) echo "✅ Reboot OK"; return 0 ;; *) echo "❌ Gagal: $R"; return 1 ;; esac
}

do_data() {
    local ON="$1" BODY R
    [ "$ON" = "1" ] && BODY='<?xml version="1.0" encoding="UTF-8"?><request><dataswitch>1</dataswitch></request>' || BODY='<?xml version="1.0" encoding="UTF-8"?><request><dataswitch>0</dataswitch></request>'
    R=$(auth_post "$BASE/api/dialup/mobile-dataswitch" "$BODY")
    case "$R" in *"<response>OK</response>"*) [ "$ON" = "1" ] && echo "✅ Data ON" || echo "✅ Data OFF"; return 0 ;; *) echo "❌ Gagal: $R"; return 1 ;; esac
}

do_ganti_ip() {
    invalidate_wan_cache
    local OLD CURRENT_BAND CURRENT_NETBAND TRANSIT_HEX NEW i X ST RC RESTORE_RC
    
    OLD=$(get_wan_ip)
    echo "  IP lama : ${OLD:-unknown}"
    
    X=$(simple_get "$BASE/api/net/net-mode")
    CURRENT_BAND=$(xval "$X" LTEBand); CURRENT_NETBAND=$(xval "$X" NetworkBand)
    [ -z "$CURRENT_NETBAND" ] && CURRENT_NETBAND="3FFFFFFF"
    [ -z "$CURRENT_BAND" ] && { echo "  ❌ Gagal baca band"; return 1; }
    
    echo "  Band saat ini : $(hex_to_label "$CURRENT_BAND")"
    
    TRANSIT_HEX="$TRANSIT_BAND_DEFAULT"
    case "$CURRENT_BAND" in
        *"$TRANSIT_HEX"*)
            if [ "$TRANSIT_HEX" != "4" ]; then
                TRANSIT_HEX="4"
            else
                TRANSIT_HEX="8000000000"
            fi
            ;;
    esac

    echo "  ▶ [1/2] Switch ke $(hex_to_label "$TRANSIT_HEX")..."
    _set_lte_band "$TRANSIT_HEX" "$CURRENT_NETBAND"; RC=$?
    if [ $RC -eq 2 ]; then
        echo "  ❌ Band tidak didukung. Fallback ke Data Off/On..."
        sleep 2
        do_ganti_ip_data
        return $?
    elif [ $RC -ne 0 ]; then
        echo "  ❌ Gagal set band"
        return 1
    fi

    _SR=$(curl -s -m 5 "$BASE/api/webserver/SesTokInfo" | tr -d '\r\n')
    _PSES=$(echo "$_SR" | sed -n 's:.*<SesInfo>\([^<]*\)</SesInfo>.*:\1:p')
    _PTOK=$(echo "$_SR" | sed -n 's:.*<TokInfo>\([^<]*\)</TokInfo>.*:\1:p')
    printf "     Reattach"; i=0; ST=""; SIG=""; NOSVC=0
    while [ $i -lt 20 ]; do
        sleep 1; printf "."
        _RESP=$(curl -s -m 3 -H "Cookie: $_PSES" -H "__RequestVerificationToken: $_PTOK" "$BASE/api/monitoring/status" 2>/dev/null | tr -d '\r\n')
        ST=$(echo "$_RESP" | sed -n 's:.*<ConnectionStatus>\([^<]*\)</ConnectionStatus>.*:\1:p')
        SIG=$(echo "$_RESP" | sed -n 's:.*<SignalIcon>\([^<]*\)</SignalIcon>.*:\1:p')
        [ "$ST" = "901" ] && { echo " ✓ ($((i+1))s)"; break; }
        if [ "$ST" = "905" ] || [ "$SIG" = "0" ] || [ -z "$ST" ]; then NOSVC=$((NOSVC+1)); [ $NOSVC -ge 3 ] && { echo " ✗ No BTS"; break; }; else NOSVC=0; fi
        i=$((i+1))
    done
    [ "$ST" != "901" ] && echo "     ⚠ Transit gagal"

    echo "  ▶ [2/2] Restore ke $(hex_to_label "$CURRENT_BAND")..."
    _set_lte_band "$CURRENT_BAND" "$CURRENT_NETBAND"; RESTORE_RC=$?
    [ $RESTORE_RC -ne 0 ] && { echo "  ⚠ Gagal restore!"; return 1; }

    invalidate_wan_cache
    printf "     Menunggu IP baru"; NEW=""; i=0
    while [ $i -lt 90 ]; do
        sleep 1; NEW=$(get_wan_ip)
        [ -n "$NEW" ] && [ "$NEW" != "0.0.0.0" ] && [ "$NEW" != "$OLD" ] && { echo ""; echo "  ✅ IP berubah: ${OLD:-?} → $NEW"; return 0; }
        printf "."; i=$((i+1))
    done
    echo ""; [ -z "$NEW" ] || [ "$NEW" = "0.0.0.0" ] && { echo "  ❌ IP kosong"; return 1; }
    echo "  ⚠ IP tetap: $NEW"; return 1
}

do_ganti_ip_data() {
    invalidate_wan_cache
    local OLD NEW i
    OLD=$(get_wan_ip)
    echo "  IP lama : ${OLD:-unknown}"
    echo "  ▶ Memutus data..."; do_data 0; sleep 3
    echo "  ▶ Menyambung..."; do_data 1; invalidate_wan_cache
    printf "  Menunggu IP baru"; i=0
    while [ $i -lt 45 ]; do
        sleep 1; NEW=$(get_wan_ip)
        [ -n "$NEW" ] && [ "$NEW" != "0.0.0.0" ] && [ "$NEW" != "$OLD" ] && { echo ""; echo "  ✅ IP: ${OLD:-?} → $NEW"; return 0; }
        printf "."; i=$((i+1))
    done
    echo ""; [ -z "$NEW" ] && { echo "  ❌ Gagal"; return 1; }
    echo "  ⚠ IP tetap: $NEW"; return 1
}

do_lock_band() {
    local BAND LABEL
    case "$1" in auto|all) BAND="7FFFFFFFFFFFFFFF" ;; *) BAND=$(band_to_bit "$1") ;; esac
    [ -z "$BAND" ] && { echo "❌ Band tidak dikenal"; return 1; }
    LABEL=$(hex_to_label "$BAND")
    echo "▶ Lock: $LABEL"
    local R=$(auth_post "$BASE/api/net/net-mode" "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><NetworkMode>${NETWORK_MODE_IP}</NetworkMode><NetworkBand>3FFFFFFF</NetworkBand><LTEBand>${BAND}</LTEBand></request>")
    case "$R" in *"<response>OK</response>"*) echo "✅ Locked: $LABEL"; return 0 ;; *112003*) echo "❌ Tidak didukung"; return 1 ;; *) echo "❌ $R"; return 1 ;; esac
}

do_lock_multi() {
    local TOTAL=0 BITS LABELS=""
    [ -z "$1" ] && { echo "❌ Usage: lock-multi <b1> <b2> ..."; return 1; }
    for band in "$@"; do
        BITS=$(band_to_bit "$band")
        [ -z "$BITS" ] && { echo "❌ Band tidak dikenal: $band"; return 1; }
        TOTAL=$(( TOTAL | 0x$BITS ))
        [ -z "$LABELS" ] && LABELS="$(hex_to_label "$BITS")" || LABELS="$LABELS + $(hex_to_label "$BITS")"
    done
    local HEX=$(printf "%X" "$TOTAL")
    echo "▶ Multi-band: $LABELS"
    local R=$(auth_post "$BASE/api/net/net-mode" "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><NetworkMode>${NETWORK_MODE_IP}</NetworkMode><NetworkBand>3FFFFFFF</NetworkBand><LTEBand>${HEX}</LTEBand></request>")
    case "$R" in *"<response>OK</response>"*) echo "✅ Aktif: $LABELS"; return 0 ;; *112003*) echo "❌ Band tidak didukung"; return 1 ;; *) echo "❌ $R"; return 1 ;; esac
}

do_cleardata() {
    local R=$(auth_post "$BASE/api/monitoring/clear-traffic" '<?xml version="1.0" encoding="UTF-8"?><request><ClearTraffic>1</ClearTraffic></request>')
    case "$R" in *"<response>OK</response>"*) echo "✅ Counter direset"; return 0 ;; *) echo "❌ $R"; return 1 ;; esac
}

# ============================================================
# TAMPILAN
# ============================================================

show_status() {
    local X
    echo "══════════════════════════════════════════════"
    X=$(simple_get "$BASE/api/monitoring/status")
    local conn=$(xval "$X" ConnectionStatus)
    case "$conn" in 901) conn="🟢 Connected" ;; 902) conn="🔴 Disconnected" ;; 900) conn="🟡 Connecting" ;; 905) conn="⚫ No service" ;; *) conn="Status $conn" ;; esac
    printf "  Koneksi  : %s\n" "$conn"
    printf "  Tipe     : %s\n" "$(xval "$X" CurrentNetworkTypeEx)"
    printf "  Sinyal   : %s/5\n" "$(xval "$X" SignalIcon)"
    printf "  Baterai  : %s%%\n" "$(xval "$X" BatteryPercent)"
    X=$(auth_get "$BASE/api/device/information")
    printf "  WAN IP   : %s\n" "$(get_wan_ip || echo unknown)"
    X=$(simple_get "$BASE/api/net/current-plmn")
    printf "  Operator : %s\n" "$(xval "$X" FullName)"
    echo ""
    sms_count_brief
}

show_signal() {
    local X=$(simple_get "$BASE/api/device/signal")
    echo "══════════════════════════════════════════════"
    printf "  LTE Band : %s\n" "$(xval "$X" band)"
    printf "  PCI      : %s\n" "$(xval "$X" pci)"
    printf "  Cell ID  : %s\n" "$(xval "$X" cell_id)"
    printf "  RSRP     : %s\n" "$(xval "$X" rsrp)"
    printf "  SINR     : %s\n" "$(xval "$X" sinr)"
}

show_band() {
    local X=$(simple_get "$BASE/api/net/net-mode")
    echo "══════════════════════════════════════════════"
    local LB=$(xval "$X" LTEBand)
    local NM=$(xval "$X" NetworkMode)
    local NM_DESC
    case "$NM" in
        00)   NM_DESC="Auto (LTE/3G/2G)" ;;
        01)   NM_DESC="GSM only (2G) — auto band 900/1800" ;;
        02)   NM_DESC="WCDMA only (3G)" ;;
        03)   NM_DESC="LTE only" ;;
        0301|301) NM_DESC="LTE + GSM" ;;
        0302|302) NM_DESC="LTE + WCDMA" ;;
        "")   NM_DESC="(kosong)" ;;
        *)    NM_DESC="Unknown ($NM)" ;;
    esac
    printf "  LTEBand : %s\n" "$LB"
    printf "  Desc    : %s\n" "$(hex_to_label "$LB")"
    printf "  NetMode : %s — %s\n" "${NM:-?}" "$NM_DESC"
    X=$(simple_get "$BASE/api/net/current-plmn")
    printf "  Operator: %s\n" "$(xval "$X" FullName)"
}

show_traffic() {
    local X=$(simple_get "$BASE/api/monitoring/traffic-statistics")
    local ct=$(xval "$X" CurrentConnectTime)
    echo "══════════════════════════════════════════════"
    printf "  Waktu konek : %02d:%02d:%02d\n" $((ct/3600)) $(((ct%3600)/60)) $((ct%60))
    printf "  Rate        : ↓%s  ↑%s B/s\n" "$(xval "$X" CurrentDownloadRate)" "$(xval "$X" CurrentUploadRate)"
}

pause() { printf "\n  Enter..."; read _; }

fetch_header() {
    HDR_IP=""; HDR_CONN="?"; HDR_SIG="?"; HDR_TYPE=""
    local X=$(simple_get "$BASE/api/monitoring/status")
    local raw_conn=$(xval "$X" ConnectionStatus)
    HDR_SIG=$(xval "$X" SignalIcon)
    local raw_type=$(xval "$X" CurrentNetworkTypeEx)
    case "$raw_conn" in 901) HDR_CONN="ON" ;; 902) HDR_CONN="OFF" ;; 900) HDR_CONN="CONN" ;; 905) HDR_CONN="NO-SVC" ;; "") HDR_CONN="?" ;; *) HDR_CONN="$raw_conn" ;; esac
    case "$raw_type" in 101|19) HDR_TYPE="LTE" ;; 1011) HDR_TYPE="LTE+" ;; "") HDR_TYPE="?" ;; *) HDR_TYPE="T$raw_type" ;; esac
    HDR_IP=$(get_wan_ip); [ -z "$HDR_IP" ] && HDR_IP="(no-ip)"; [ -z "$HDR_SIG" ] && HDR_SIG="?"
}

menu_sms() {
    while true; do
        clear
        echo "══════════════════════════════════════════════"
        echo "             MENU SMS"
        echo "══════════════════════════════════════════════"
        sms_count_brief
        echo "──────────────────────────────────────────────"
        echo "  1) 📥 Inbox (browse, balas, hapus)"
        echo "  2) 📤 Outbox (browse, hapus)"
        echo "  3) 📝 Konsep / Draft (kirim ulang, hapus)"
        echo "  4) ✉  Kirim SMS baru"
        echo "  5) 📊 Refresh jumlah SMS"
        echo "  0) Kembali"
        echo "══════════════════════════════════════════════"
        printf "  Pilih: "; read c
        case "$c" in
            1) sms_browse 1 ;;
            2) sms_browse 2 ;;
            3) sms_browse 3 ;;
            4) clear
               printf "  Nomor tujuan: "; read phone
               [ -z "$phone" ] && continue
               printf "  Pesan: "; read content
               [ -z "$content" ] && { echo "  ❌ Kosong"; sleep 1; continue; }
               sms_send "$phone" "$content" 0
               printf "\n  Enter..."; read _ ;;
            5) ;;
            0|q) return ;;
            *) echo "  ❌ Pilihan '$c' tidak valid"; sleep 1 ;;
        esac
    done
}

menu() {
    while true; do
        clear
        fetch_header
        echo "╔══════════════════════════════════════════════╗"
        printf "║ 🌐 %-15s  %-5s  %s/5  %-5s ║\n" "$HDR_IP" "$HDR_CONN" "$HDR_SIG" "$HDR_TYPE"
        echo "╠══════════════════════════════════════════════╣"
        echo "║  INFO                                        ║"
        echo "║   1) Status       2) Sinyal                  ║"
        echo "║   3) Band/Op      4) Trafik                  ║"
        echo "║  AKSI                                        ║"
        echo "║   5) 🔄 Ganti IP   6) 📡 Reboot              ║"
        echo "║  BAND                                        ║"
        echo "║   7) 🔒 Lock band  8) 🔗 Multi-band          ║"
        echo "║  DATA & SMS                                  ║"
        echo "║   9) Data ON      10) Data OFF               ║"
        echo "║  11) Reset        12) Ganti IP (data off)    ║"
        echo "║  13) 📨 SMS       14) 🔧 Manual Mode         ║"
        echo "║                                              ║"
        echo "║   0) Keluar                                  ║"
        echo "╚══════════════════════════════════════════════╝"
        printf "Pilih: "; read c
        case "$c" in
            1) clear; show_status; pause ;;
            2) clear; show_signal; pause ;;
            3) clear; show_band; pause ;;
            4) clear; show_traffic; pause ;;
            5) clear; do_ganti_ip; pause ;;
            6) clear; echo "⚠ Reboot? (y/n)"; read ok; [ "$ok" = "y" ] || [ "$ok" = "Y" ] || continue; do_reboot; pause ;;
            7) clear; echo "1=2100 3=1800 5=850 40=2300 0=Auto q=Kembali"; printf "  Band: "; read b; [ "$b" = "q" ] && continue; [ "$b" = "0" ] && { do_lock_band auto; pause; } || { do_lock_band "$b"; pause; } ;;
            8) clear; echo "  Contoh: 1 3 40"; printf "  Bands: "; read bands; [ -n "$bands" ] && { do_lock_multi $bands; pause; } ;;
            9) clear; do_data 1; pause ;;
            10) clear; do_data 0; pause ;;
            11) clear; do_cleardata; pause ;;
            12) clear; do_ganti_ip_data; pause ;;
            13) clear; menu_sms ;;
            14) clear
                echo "══════════════════════════════════════════════"
                echo "     MANUAL MODE SWITCH"
                echo "══════════════════════════════════════════════"
                echo "  1) LTE only (03)       → untuk ganti IP / lock band"
                echo "  2) GSM only (01)       → untuk SMS (auto band 900)"
                echo "  3) LTE+GSM (0301)      → LTE untuk internet + GSM untuk SMS"
                echo "  4) Auto (00)           → modem pilih otomatis"
                echo "  0) Kembali"
                printf "  Pilih: "; read m
                case "$m" in
                    1) switch_network_mode "03" && echo "✅ Mode: LTE only" ;;
                    2) switch_network_mode "01" && echo "✅ Mode: GSM only (auto 900)" ;;
                    3) switch_network_mode "0301" && echo "✅ Mode: LTE+GSM" ;;
                    4) switch_network_mode "00" && echo "✅ Mode: Auto" ;;
                    0|q) continue ;;
                    *) echo "  ❌ Pilihan invalid" ;;
                esac
                pause ;;
            0|q|exit) clear; echo "Bye 👋"; exit 0 ;;
            *) echo "  ❌ Pilihan tidak valid"; sleep 1 ;;
        esac
    done
}

# ============================================================
# CLI DISPATCH & HELP
# ============================================================

case "$1" in
    reboot)        do_reboot ;;
    ganti-ip)      do_ganti_ip ;;
    ganti-ip-data) do_ganti_ip_data ;;
    status)        show_status ;;
    signal)        show_signal ;;
    band)          show_band ;;
    traffic)       show_traffic ;;
    ip|wanip)      get_wan_ip ;;
    data)          [ "$2" = "on" ] && do_data 1 || do_data 0 ;;
    lock)          do_lock_band "$2" ;;
    lock-multi)    shift; do_lock_multi "$@" ;;
    cleardata)     do_cleardata ;;
    mode)
        case "$2" in
            lte)  switch_network_mode "03" && echo "✅ Mode: LTE only" ;;
            gsm)  switch_network_mode "01" && echo "✅ Mode: GSM only (auto 900)" ;;
            sms)  switch_network_mode "0301" && echo "✅ Mode: LTE+GSM" ;;
            auto) switch_network_mode "00" && echo "✅ Mode: Auto" ;;
            *)    echo "Usage: mode lte|gsm|sms|auto" ;;
        esac ;;
    sms)
        case "$2" in
            inbox)   sms_browse 1 ;;
            outbox)  sms_browse 2 ;;
            draft)   sms_browse 3 ;;
            count)   sms_count_brief ;;
            send)    sms_send "$3" "$4" 0 ;;
            *)       sms_browse 1 ;;
        esac
        ;;
    help|-h|--help)
        cat <<'HELPEOF'
╔══════════════════════════════════════════════════════════════╗
║           E5573 CONTROL SCRIPT — HELP (v22)                  ║
╚══════════════════════════════════════════════════════════════╝

MODE SMS v22:
  Saat kirim SMS, script switch ke GSM-only (01) selama ~10
  detik. Modem akan auto-attach ke GSM 900 (B8) jika tersedia
  di area kamu. Setelah SMS terkirim, restore ke LTE state
  semula (band tidak berubah).

USAGE:
  ./login.sh                    → Menu interaktif
  ./login.sh <command> [args]   → CLI mode

════════════════════════════════════════════════════════════════
  📊 INFO
════════════════════════════════════════════════════════════════
  status       → Status lengkap
  signal       → Detail sinyal
  band         → Band LTE + NetworkMode + operator
  traffic      → Statistik trafik
  ip, wanip    → WAN IP

════════════════════════════════════════════════════════════════
  ⚡ AKSI
════════════════════════════════════════════════════════════════
  reboot           → Reboot modem (~60 detik)
  ganti-ip         → Ganti IP via band switch
  ganti-ip-data    → Ganti IP via data off/on (fallback)
  data on|off      → Kontrol data seluler
  cleardata        → Reset counter pemakaian

════════════════════════════════════════════════════════════════
  🔧 MODE SWITCH
════════════════════════════════════════════════════════════════
  mode lte    → 03 LTE only (untuk lock band & ganti IP)
  mode gsm    → 01 GSM only (untuk SMS, auto band 900)
  mode sms    → 0301 LTE+GSM (internet tetap jalan saat SMS)
  mode auto   → 00 Auto

════════════════════════════════════════════════════════════════
  📡 BAND
════════════════════════════════════════════════════════════════
  lock <band>              → Lock band (1|3|5|20|40|41|auto)
  lock-multi <b1> <b2>...  → Multi-band (contoh: 1 3 40)

════════════════════════════════════════════════════════════════
  📨 SMS
════════════════════════════════════════════════════════════════
  sms                      → Menu SMS interaktif
  sms inbox|outbox|draft   → Buka folder SMS
  sms count                → Jumlah SMS per folder
  sms send <no> <pesan>    → Kirim SMS langsung

  Setiap kirim SMS akan OTOMATIS:
  1. Simpan state LTE saat ini
  2. Switch ke GSM-only (01) → auto attach 900
  3. Kirim SMS via jalur CS 2G
  4. Restore state LTE semula (band tidak hilang)

════════════════════════════════════════════════════════════════
  ⌨  KEYBOARD DI MENU SMS
════════════════════════════════════════════════════════════════
  n/p/g   → Navigasi halaman
  r       → Refresh
  f       → Filter unread
  d       → Hapus pesan (1-10)
  D       → Hapus SEMUA
  b       → Balas pesan (1-10)
  s       → Kirim baru
  k       → Kirim Draft (khusus menu Draft)
  q       → Kembali

════════════════════════════════════════════════════════════════
  ⚠  CATATAN PENTING
════════════════════════════════════════════════════════════════
  • Mode SMS = GSM-only → auto pilih 900MHz (band 900 yang aktif
    di area kamu). Tidak ada parameter untuk lock GSM band secara
    eksplisit di API E5573.
  • Internet mati ~10 detik selama pengiriman SMS (normal, karena
    modem detach dari LTE dan attach ke GSM).
  • Folder "Konsep/Draft" = pesan GAGAL. Cek pulsa/SMSC.
  • Balas pesan TIDAK menghapus pesan asli di Inbox (Index=-1).

════════════════════════════════════════════════════════════════
  📞 TROUBLESHOOTING
════════════════════════════════════════════════════════════════
  Q: SMS masih masuk Konsep?
  A: Cek pulsa. Mode SMS=01 (GSM only) hanya bisa kirim jika
     area kamu ada GSM signal. Kalau tidak ada sinyal GSM
     sama sekali, gunakan mode 0301 (LTE+GSM).

  Q: Kirim SMS lambat?
  A: Normal ~10-15 detik per SMS (attach GSM + kirim + restore
     LTE). Untuk bulk SMS, bisa dibuat mode batch di masa depan.

  Q: Error 112003 saat lock band?
  A: Firmware kamu menolak mode 0301 untuk lock. Script sudah
     pakai 03 default untuk lock band.

════════════════════════════════════════════════════════════════
HELPEOF
        ;;
    "")            menu ;;
    *)             echo "❌ Tidak dikenal: $1"; echo "Coba: $0 help" ;;
esac