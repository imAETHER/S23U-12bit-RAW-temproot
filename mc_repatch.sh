#!/system/bin/sh

FRIDA_INJECT="${FRIDA_INJECT:-/data/local/tmp/frida-inject}"
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "$0")}"
PROVIDER="vendor.samsung.hardware.camera.provider-service_64"

CHI="com.qti.chi.override.so"
CAMX="camera.qcom.so"

NOP='\x1f\x20\x03\xd5'

# When the request is RAW (>= 3900x2900), it forces sensor mode 11 on the main camera (id 0) and mode 3 on the ultrawide (id 2).
# x1 = mode request: [x1] width, [x1+4] height, [x1+40] mode index
FORCE_MODE_HEAD='\x1f\x00\x00\x71\x61\x00\x00\x54\x69\x01\x80\x52\x04\x00\x00\x14\x1f\x08\x00\x71\x21\x01\x00\x54\x69\x00\x80\x52\x2a\x00\x40\xb9\x5f\xf1\x3c\x71\xa3\x00\x00\x54\x2a\x04\x40\xb9\x5f\x51\x2d\x71\x43\x00\x00\x54\x29\x28\x00\xb9\x3f\x23\x03\xd5'

# This is an empty region in chi, used as JUMP_TO_EMPTY after select_hook
JUMP_OFFSET=0x13fee0

HOOK_SIG=3f2303d5ec0f17fceb2b016d
HOOK_OFFSETS='0x481040 0x480970' # hook locations

first_pid() {
    set -- $(pidof "$1" 2>/dev/null)
    [ -n "$1" ] && echo "$1"
}

has_lib() {
    grep -qF "/$2" "/proc/$1/maps" 2>/dev/null
}

wait_for_exit() {
    while [ -d "/proc/$1" ]; do sleep "$2"; done
}

wait_for_libs() {
    pid="$1"; shift

    for lib in "$@"; do
        tries=0
        until has_lib "$pid" "$lib"; do
            [ -d "/proc/$pid" ] || return 1

            tries=$((tries + 1))

            [ "$tries" -gt 1000 ] && return 1

            sleep 0.005
        done
    done
}

# resolve PID LIB:OFFSET ... to the abs address.
# using awk because the shell is like 32bit and these addresses are 40bit, which messes it up
resolve() {
    pid="$1"; shift
    awk -v wanted="$*" '
        function hex(s, i, v) {
            v = 0
            s = tolower(s)

            sub(/^0x/, "", s)
            for (i = 1; i <= length(s); i++)
                v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1

            return v
        }
        BEGIN { n = split(wanted, req, " ") }
        {
            parts = split($NF, path, "/")
            lib = path[parts]
            if (!(lib in base)) {
                split($1, range, "-")

                base[lib] = hex(range[1]) - hex($3)
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                split(req[i], kv, ":")
                if (!(kv[1] in base)) exit 1

                printf "%.0f ", base[kv[1]] + hex(kv[2])
            }
        }
    ' "/proc/$pid/maps"
}

as_hex() {
    od -An -v -tx1 | tr -d ' \n'
}

read_mem() {
    dd if="/proc/$1/mem" bs="$3" count=1 iflag=skip_bytes skip="$2" status=none 2>/dev/null | as_hex
}

write_mem() {
    err="$(printf "$2" | dd of="/proc/$1/mem" bs=4096 oflag=seek_bytes seek="$3" conv=notrunc status=none 2>&1)" || {
        echo "write failed at $3: $err"
        return 1
    }
}

# dont patch if they dont match (the bytes)
expect() {
    pid="$1" addr="$2" stock="$3" patched="$4" what="$5"
    found="$(read_mem "$pid" "$addr" $((${#stock} / 2)))"

    [ "$found" = "$stock" ] || [ "$found" = "$patched" ] && return 0

    echo "$what: expected $stock, found $found. firmware change? not patching."
    return 1
}

mode_sites_ok() {
    pid="$1"
    set -- $(resolve "$pid" "$CHI:$JUMP_OFFSET" "$CHI:$HOOK_OFFSET" "$CAMX:0x12753c8" "$CAMX:0x18a24b8")
    [ $# -eq 4 ] || { echo "failed to resolve address"; return 1; }

    expect "$pid" "$1" "$(printf '%0128d' 0)" "$(printf "$FORCE_MODE" | as_hex)" "empty space" &&
    expect "$pid" "$2" 3f2303d5 "$(printf "$JUMP_TO_EMPTY" | as_hex)" "hook site" &&
    expect "$pid" "$3" 24321b94 1f2003d5 "LogSystem call" &&
    expect "$pid" "$4" fa800294 1f2003d5 "abort call"
}

patch_mode() {
    pid="$1"
    set -- $(resolve "$pid" "$CHI:$JUMP_OFFSET" "$CHI:$HOOK_OFFSET" "$CAMX:0x12753c8" "$CAMX:0x18a24b8")
    [ $# -eq 4 ] || { echo "failed to resolve address"; return 1; }

    write_mem "$pid" "$FORCE_MODE" "$1" &&
    write_mem "$pid" "$JUMP_TO_EMPTY" "$2" &&

    # CamX logs an error and then asserts on the forced mode. so we just skip both calls
    write_mem "$pid" "$NOP" "$3" &&
    write_mem "$pid" "$NOP" "$4"
}

# jump encoded as little-endian escapes
make_jump() {
    origin=$1 dest=$2

    offset=$(( (dest - origin) / 4 ))
    
    # 0x14000000: b <dest>
    # 0x3ffffff: mask low 26 bits, with top two bits as 1 so its negative
    insn=$(( 0x14000000 | (offset & 0x3ffffff) ))

    printf '\\x%02x' $(( insn & 255 )) $(( insn >> 8 & 255 )) $(( insn >> 16 & 255 )) $(( insn >> 24 ))
}

# search for hook by sig -> get both branches from the offset
select_hook() {
    pid="$1"
    for hoff in $HOOK_OFFSETS; do
        set -- $(resolve "$pid" "$CHI:$hoff")
        [ $# -eq 1 ] || continue

        if [ "$(read_mem "$pid" "$1" $(( ${#HOOK_SIG} / 2 )))" = "$HOOK_SIG" ]; then
            HOOK_OFFSET=$hoff
            JUMP_TO_EMPTY=$(make_jump "$hoff" "$JUMP_OFFSET")
            FORCE_MODE="$FORCE_MODE_HEAD$(make_jump $(( JUMP_OFFSET + 60 )) $(( hoff + 4 )))"
            return 0
        fi
    done
    
    echo "unknown firmware? no provider matches found"
    return 1
}

watch_provider() {
    mode_checked=0
    while true; do
        pid="$(first_pid "$PROVIDER")" || { sleep 0.02; continue; }

        # race condition: patch has to apply before provider configures stream
        if wait_for_libs "$pid" "$CHI" "$CAMX"; then
            if [ "$mode_checked" = 0 ]; then
                select_hook "$pid" || exit 1
                mode_sites_ok "$pid" || exit 1
                mode_checked=1
            fi

            if patch_mode "$pid"; then
                echo "[provider $pid] 12bit patched!"
            else
                echo "[provider $pid] 12bit patch FAIL"
            fi
        fi

        wait_for_exit "$pid" 0.02
    done
}

watch_cameraserver() {
    while true; do
        pid="$(first_pid cameraserver)" || { sleep 0.5; continue; }

        tries=0
        until "$FRIDA_INJECT" -p "$pid" -s "$SCRIPT_DIR/cs_final.js" -e; do
            tries=$((tries + 1))
            [ "$tries" -ge 5 ] && { echo "[cameraserver $pid] injection FAIL, giving up (you can terminate and retry)"; break; }
            sleep 1
        done

        wait_for_exit "$pid" 0.5
    done
}

[ "$(id -u)" = 0 ] || { echo "needs root"; exit 1; }
[ -x "$FRIDA_INJECT" ] || { echo "frida-inject not found at $FRIDA_INJECT"; exit 1; }
[ -f "$SCRIPT_DIR/cs_final.js" ] || { echo "cs_final.js not found in $SCRIPT_DIR"; exit 1; }

watch_cameraserver &
cameraserver_watcher=$! # get PID of the cameraserver watcher,
# so we can kill it when we get the signal (and then ourselves)
trap 'kill "$cameraserver_watcher" 2>/dev/null' EXIT
trap 'exit 130' INT TERM

watch_provider
