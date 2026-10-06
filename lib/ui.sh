# UNA.Email terminal output, shared by install.sh and update.sh.
#
# Sourced, not run. Everything here prints; nothing here changes the system.
#
# Colour only when stdout is a terminal, so a piped or logged run stays plain
# text, and never when NO_COLOR is set (https://no-color.org). Unicode symbols
# only when the locale is UTF-8: a bare POSIX locale -- some provider web
# consoles, a cron job -- would print them as mojibake, so those get ASCII.
# UNA_ASCII=1 forces ASCII anywhere.
#
# Written for bash 3.2 as well as 5.x, so the preview runs on a stock Mac.
# Under the callers' `set -e`, no bare (( )) and no `cmd && cmd` as a
# statement: either one returning 1 would end the script.

if [ -t 1 ]; then UI_TTY=1; else UI_TTY=0; fi
UI_ESC=$'\033'

if [ "$UI_TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_RED=$'\033[31m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_CYAN=$'\033[36m'
else
    UI_RESET="" UI_BOLD="" UI_DIM="" UI_RED="" UI_GREEN="" UI_YELLOW="" UI_CYAN=""
fi

case "$(locale charmap 2>/dev/null || true)" in
    UTF-8|utf-8|utf8) UI_UTF8=1 ;;
    *) UI_UTF8=0 ;;
esac
if [ "${UNA_ASCII:-}" = "1" ]; then UI_UTF8=0; fi

if [ "$UI_UTF8" = 1 ]; then
    UI_SYM_OK="✓" UI_SYM_FAIL="✗" UI_SYM_WARN="!" UI_SYM_INFO="•"
    UI_SYM_RUN="›" UI_SYM_ASK="?" UI_RULE_CHAR="─"
    UI_ELLIPSIS="…"
    UI_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
    UI_SYM_OK="+" UI_SYM_FAIL="x" UI_SYM_WARN="!" UI_SYM_INFO="-"
    UI_SYM_RUN=">" UI_SYM_ASK="?" UI_RULE_CHAR="-"
    UI_ELLIPSIS="..."
    UI_FRAMES=('|' '/' '-' '\')
fi

# Rule width: 60, or less on a narrow console so it never wraps.
UI_WIDTH=$(tput cols 2>/dev/null || echo 80)
case "$UI_WIDTH" in ''|*[!0-9]*) UI_WIDTH=80 ;; esac
UI_WIDTH=$((UI_WIDTH - 4))
if [ "$UI_WIDTH" -gt 60 ]; then UI_WIDTH=60; fi

ui__rule() {
    local line="" i=0
    while [ "$i" -lt "$UI_WIDTH" ]; do line="$line$UI_RULE_CHAR"; i=$((i + 1)); done
    printf '  %s%s%s\n' "$UI_DIM" "$line" "$UI_RESET"
}

ui__clear_line() {
    if [ "$UI_TTY" = 1 ]; then printf '\r\033[K'; fi
}

# The header at the top of a run. $1 is what this script is ("Installer").
ui_banner() {
    local version
    version=$(git describe --tags --always 2>/dev/null || true)
    echo ""
    printf '  %sUNA.Email%s  %s%s%s' "$UI_BOLD" "$UI_RESET" "$UI_DIM" "$1" "$UI_RESET"
    if [ -n "$version" ]; then printf '  %s%s%s' "$UI_DIM" "$version" "$UI_RESET"; fi
    echo ""
    ui__rule
}

# A numbered step: ui_step 2 8 "Domain"
ui_step() {
    echo ""
    printf '  %s[%s/%s]%s %s%s%s\n' "$UI_DIM" "$1" "$2" "$UI_RESET" "$UI_BOLD" "$3" "$UI_RESET"
}

# An unnumbered section, for the licence before step 1.
ui_section() {
    echo ""
    printf '  %s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"
}

ui_ok()   { printf '    %s%s%s %s\n' "$UI_GREEN"  "$UI_SYM_OK"   "$UI_RESET" "$*"; }
ui_fail() { printf '    %s%s%s %s%s%s\n' "$UI_RED" "$UI_SYM_FAIL" "$UI_RESET" "$UI_BOLD" "$*" "$UI_RESET"; }
ui_warn() { printf '    %s%s%s %s\n' "$UI_YELLOW" "$UI_SYM_WARN" "$UI_RESET" "$*"; }
ui_info() { printf '    %s%s%s %s\n' "$UI_DIM"    "$UI_SYM_INFO" "$UI_RESET" "$*"; }
ui_run()  { printf '    %s%s%s %s\n' "$UI_CYAN"   "$UI_SYM_RUN"  "$UI_RESET" "$*"; }

# Explanation under an ok/fail/warn line, lined up with its text.
ui_note() {
    if [ $# -eq 0 ] || [ -z "$1" ]; then echo ""; return 0; fi
    printf '      %s\n' "$*"
}

# A command for the reader to type, under a note.
ui_cmd() { printf '        %s%s%s\n' "$UI_CYAN" "$*" "$UI_RESET"; }

# Plain text at section level, for paragraphs like the licence.
ui_text() {
    if [ $# -eq 0 ] || [ -z "$1" ]; then echo ""; return 0; fi
    printf '  %s\n' "$*"
}

# A labelled value: ui_kv "Domain" "example.com"
ui_kv() { printf '    %s%-15s%s %s\n' "$UI_DIM" "$1" "$UI_RESET" "$2"; }

# One line of a check list: ui_status ok|warn|fail "Label" "detail"
ui_status() {
    local sym colour
    case "$1" in
        ok)   sym=$UI_SYM_OK   colour=$UI_GREEN ;;
        warn) sym=$UI_SYM_WARN colour=$UI_YELLOW ;;
        *)    sym=$UI_SYM_FAIL colour=$UI_RED ;;
    esac
    printf '    %s%s%s %-18s %s\n' "$colour" "$sym" "$UI_RESET" "$2" "$3"
}

# Indent another command's output to sit under the current step.
ui_indent() { sed 's/^/      /'; }

# Ask a question: ui_ask VAR "Question" [default]
#
# An empty answer takes the default. Returns read's own status, so at EOF
# (nothing on a terminal) a caller under `set -e` stops unless it adds
# `|| true` -- and VAR still holds the default when it does.
ui_ask() {
    local __var=$1 __prompt=$2 __default=${3:-} __answer="" __status=0
    if [ -n "$__default" ]; then
        printf '    %s%s%s %s %s[%s]%s ' "$UI_CYAN" "$UI_SYM_ASK" "$UI_RESET" "$__prompt" "$UI_DIM" "$__default" "$UI_RESET"
    else
        printf '    %s%s%s %s ' "$UI_CYAN" "$UI_SYM_ASK" "$UI_RESET" "$__prompt"
    fi
    IFS= read -r __answer || __status=$?
    # A piped answer is not echoed by the terminal, so echo it ourselves.
    if [ ! -t 0 ]; then printf '%s\n' "$__answer"; fi
    if [ -z "$__answer" ]; then __answer=$__default; fi
    printf -v "$__var" '%s' "$__answer"
    return "$__status"
}

# Spinner frame number $1.
ui__frame_at() {
    printf '%s' "${UI_FRAMES[$(($1 % ${#UI_FRAMES[@]}))]}"
}

ui__elapsed() {
    local s=$1
    if [ "$s" -lt 2 ]; then return 0; fi
    if [ "$s" -lt 60 ]; then printf '%ss' "$s"; else printf '%sm%02ds' $((s / 60)) $((s % 60)); fi
}

# Run a command behind a spinner: ui_spin "Pulling images" "Images pulled" cmd args...
#
# On a terminal the command's output goes to a log, the spinner line shows the
# elapsed time and the log's latest line, and the whole log is printed if the
# command fails. Off a terminal it runs in the open, so logs keep everything.
# Returns the command's status. Shell functions work as the command. An empty
# done label means no line on success, for a caller that prints its own.
ui_spin() {
    local label=$1 done_label=$2 status=0
    shift 2
    if [ "$UI_TTY" != 1 ]; then
        ui_run "$label..."
        ( set -o pipefail; "$@" 2>&1 | ui_indent ) || status=$?
        if [ "$status" -ne 0 ]; then
            ui_fail "$label failed"
        elif [ -n "$done_label" ]; then
            ui_ok "$done_label"
        fi
        return "$status"
    fi

    local log start tick=0 last max
    log=$(mktemp)
    start=$SECONDS
    "$@" > "$log" 2>&1 < /dev/null &
    local pid=$!
    max=$((UI_WIDTH - ${#label} - 14))
    while kill -0 "$pid" 2>/dev/null; do
        # The log's last line, minus colour codes and carriage-return
        # progress bars, cut to what fits after the label.
        last=$(tail -c 400 "$log" 2>/dev/null | tr '\r' '\n' | sed "s/${UI_ESC}\[[0-9;]*[A-Za-z]//g" | grep -v '^[[:space:]]*$' | tail -n 1 | sed 's/^[[:space:]]*//' || true)
        if [ "$max" -gt 8 ] && [ "${#last}" -gt "$max" ]; then last="${last:0:$((max - 3))}$UI_ELLIPSIS"; fi
        if [ "$max" -le 8 ]; then last=""; fi
        printf '\r\033[K    %s%s%s %s  %s%s  %s%s' "$UI_CYAN" "$(ui__frame_at "$tick")" "$UI_RESET" \
            "$label" "$UI_DIM" "$(ui__elapsed $((SECONDS - start)))" "$last" "$UI_RESET"
        tick=$((tick + 1))
        sleep 0.1
    done
    wait "$pid" || status=$?
    ui__clear_line
    if [ "$status" -eq 0 ]; then
        if [ -n "$done_label" ]; then ui_ok "$done_label"; fi
    else
        ui_fail "$label failed"
        ui_indent < "$log"
    fi
    rm -f "$log"
    return "$status"
}

# Poll until a command succeeds: ui_wait "Waiting for Postgres" "Postgres ready" TRIES SECONDS cmd args...
#
# Tries the command up to TRIES times, SECONDS apart. Prints the done label on
# success (nothing if it is empty); on giving up it prints nothing and returns
# 1, so the caller says what went wrong.
ui_wait() {
    local label=$1 done_label=$2 tries=$3 interval=$4
    shift 4
    local start=$SECONDS try=0 tick=0 ticks
    if [ "$UI_TTY" != 1 ]; then ui_run "$label..."; fi
    while [ "$try" -lt "$tries" ]; do
        if [ "$UI_TTY" = 1 ]; then
            printf '\r\033[K    %s%s%s %s  %s%s%s' "$UI_CYAN" "$(ui__frame_at "$tick")" "$UI_RESET" \
                "$label" "$UI_DIM" "$(ui__elapsed $((SECONDS - start)))" "$UI_RESET"
        fi
        if "$@" > /dev/null 2>&1; then
            ui__clear_line
            if [ -n "$done_label" ]; then ui_ok "$done_label"; fi
            return 0
        fi
        ticks=$((interval * 10))
        while [ "$ticks" -gt 0 ]; do
            if [ "$UI_TTY" = 1 ]; then
                printf '\r\033[K    %s%s%s %s  %s%s%s' "$UI_CYAN" "$(ui__frame_at "$tick")" "$UI_RESET" \
                    "$label" "$UI_DIM" "$(ui__elapsed $((SECONDS - start)))" "$UI_RESET"
            fi
            tick=$((tick + 1))
            ticks=$((ticks - 1))
            sleep 0.1
        done
        try=$((try + 1))
    done
    ui__clear_line
    return 1
}

# The closing banner: ui_done "Installation complete"
ui_done() {
    echo ""
    ui__rule
    printf '  %s%s%s %s%s%s\n' "$UI_GREEN" "$UI_SYM_OK" "$UI_RESET" "$UI_BOLD" "$1" "$UI_RESET"
    echo ""
}
