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

# ---------------------------------------------------------------------------
# The run log
#
# The screen shows a spinner and a tick per step; the log keeps everything
# behind them -- every line the screen shows, timestamped, plus the full
# output of each command ui_spin ran, its exit status and how long it took --
# so there is something to read, or send to support, when a step goes wrong.
#
# Off until a script calls ui_log_start, so the scripts that do not want one
# are unchanged. Answers to ui_ask are logged too: do not ask for a secret
# while a log is open.
UI_LOG=""

# ui_log_start FILE "Update": open (or, on a re-exec, reopen) the log. On exit
# it records how the run ended, and a run that failed or was interrupted
# says where the log is.
ui_log_start() {
    UI_LOG=$1
    mkdir -p "$(dirname "$UI_LOG")"
    if [ ! -s "$UI_LOG" ]; then
        ( umask 077; : > "$UI_LOG" )
        {
            echo "UNA.Email $2 log"
            echo "Started  $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "Host     $(hostname 2>/dev/null || echo unknown)"
            echo "Version  $(git describe --tags --always 2>/dev/null || echo unknown)"
            echo "Docker   $(docker --version 2>/dev/null || echo 'not found')"
            echo ""
        } >> "$UI_LOG"
    else
        { echo ""; echo "--- continued by a new copy of the script (pid $$) ---"; } >> "$UI_LOG"
    fi
    trap ui__log_end EXIT
    # Killed by a signal, bash runs the EXIT trap with $? still 0, so the log
    # would say the run finished. Exit with the signal's status instead.
    trap 'ui__on_signal 130' INT
    trap 'ui__on_signal 143' TERM
}

# Ctrl-C: also stop the command behind the spinner. It runs in the background,
# where a script's jobs ignore SIGINT, so it would otherwise carry on alone.
ui__on_signal() {
    if [ -n "$UI__SPIN_PID" ]; then kill "$UI__SPIN_PID" 2>/dev/null || true; fi
    exit "$1"
}
UI__SPIN_PID=""

ui__log_end() {
    local status=$?
    if [ -z "$UI_LOG" ]; then return "$status"; fi
    ui__clear_line
    ui__log ''
    if [ "$status" -eq 0 ]; then
        ui__log "Finished (exit 0)"
    elif [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then
        ui__log "Interrupted (exit $status)"
        printf '\n    %sFull details of this run:%s %s\n\n' "$UI_DIM" "$UI_RESET" "$UI_LOG"
    else
        ui__log "Stopped (exit $status)"
        printf '\n    %sFull details of this run:%s %s\n\n' "$UI_DIM" "$UI_RESET" "$UI_LOG"
    fi
    return "$status"
}

# Append a line to the log, timestamped and without colour codes.
ui__log() {
    if [ -z "$UI_LOG" ]; then return 0; fi
    if [ -z "$1" ]; then echo "" >> "$UI_LOG"; return 0; fi
    printf '%s %s\n' "$(date +%H:%M:%S)" "$1" | sed "s/${UI_ESC}\[[0-9;]*[A-Za-z]//g" >> "$UI_LOG"
}

# printf a line (format without the newline), and log it.
ui__put() {
    local line
    # shellcheck disable=SC2059  # the format is always one of ours
    printf -v line "$@"
    printf '%s\n' "$line"
    ui__log "$line"
}

# Run a check quietly: nothing on screen, but the command and whatever it
# printed go in the log. Returns the command's status. Not for a command with
# a secret in its arguments -- those are logged as written.
ui_logged() {
    if [ -z "$UI_LOG" ]; then "$@" > /dev/null 2>&1; return; fi
    ui__log "      \$ $*"
    "$@" >> "$UI_LOG" 2>&1
}

ui__rule() {
    local line="" i=0
    while [ "$i" -lt "$UI_WIDTH" ]; do line="$line$UI_RULE_CHAR"; i=$((i + 1)); done
    ui__put '  %s%s%s' "$UI_DIM" "$line" "$UI_RESET"
}

ui__clear_line() {
    if [ "$UI_TTY" = 1 ]; then printf '\r\033[K'; fi
}

# The header at the top of a run. $1 is what this script is ("Installer").
ui_banner() {
    local version line
    version=$(git describe --tags --always 2>/dev/null || true)
    ui__put ''
    printf -v line '  %sUNA.Email%s  %s%s%s' "$UI_BOLD" "$UI_RESET" "$UI_DIM" "$1" "$UI_RESET"
    if [ -n "$version" ]; then printf -v line '%s  %s%s%s' "$line" "$UI_DIM" "$version" "$UI_RESET"; fi
    ui__put '%s' "$line"
    ui__rule
}

# A numbered step: ui_step 2 8 "Domain"
ui_step() {
    ui__put ''
    ui__put '  %s[%s/%s]%s %s%s%s' "$UI_DIM" "$1" "$2" "$UI_RESET" "$UI_BOLD" "$3" "$UI_RESET"
}

# An unnumbered section, for the licence before step 1.
ui_section() {
    ui__put ''
    ui__put '  %s%s%s' "$UI_BOLD" "$1" "$UI_RESET"
}

ui_ok()   { ui__put '    %s%s%s %s' "$UI_GREEN"  "$UI_SYM_OK"   "$UI_RESET" "$*"; }
ui_fail() { ui__put '    %s%s%s %s%s%s' "$UI_RED" "$UI_SYM_FAIL" "$UI_RESET" "$UI_BOLD" "$*" "$UI_RESET"; }
ui_warn() { ui__put '    %s%s%s %s' "$UI_YELLOW" "$UI_SYM_WARN" "$UI_RESET" "$*"; }
ui_info() { ui__put '    %s%s%s %s' "$UI_DIM"    "$UI_SYM_INFO" "$UI_RESET" "$*"; }
ui_run()  { ui__put '    %s%s%s %s' "$UI_CYAN"   "$UI_SYM_RUN"  "$UI_RESET" "$*"; }

# Explanation under an ok/fail/warn line, lined up with its text.
ui_note() {
    if [ $# -eq 0 ] || [ -z "$1" ]; then ui__put ''; return 0; fi
    ui__put '      %s' "$*"
}

# A command for the reader to type, under a note.
ui_cmd() { ui__put '        %s%s%s' "$UI_CYAN" "$*" "$UI_RESET"; }

# Plain text at section level, for paragraphs like the licence.
ui_text() {
    if [ $# -eq 0 ] || [ -z "$1" ]; then ui__put ''; return 0; fi
    ui__put '  %s' "$*"
}

# A labelled value: ui_kv "Domain" "example.com"
ui_kv() { ui__put '    %s%-15s%s %s' "$UI_DIM" "$1" "$UI_RESET" "$2"; }

# One line of a check list: ui_status ok|warn|fail "Label" "detail"
ui_status() {
    local sym colour
    case "$1" in
        ok)   sym=$UI_SYM_OK   colour=$UI_GREEN ;;
        warn) sym=$UI_SYM_WARN colour=$UI_YELLOW ;;
        *)    sym=$UI_SYM_FAIL colour=$UI_RED ;;
    esac
    ui__put '    %s%s%s %-18s %s' "$colour" "$sym" "$UI_RESET" "$2" "$3"
}

# Indent another command's output to sit under the current step (and log it).
ui_indent() {
    if [ -n "$UI_LOG" ]; then sed 's/^/      /' | tee -a "$UI_LOG"; else sed 's/^/      /'; fi
}

# Ask a question: ui_ask VAR "Question" [default]
#
# An empty answer takes the default. Returns read's own status, so at EOF
# (nothing on a terminal) a caller under `set -e` stops unless it adds
# `|| true` -- and VAR still holds the default when it does.
ui_ask() {
    local __var=$1 __prompt=$2 __default=${3:-} __answer="" __status=0 __line
    if [ -n "$__default" ]; then
        printf -v __line '    %s%s%s %s %s[%s]%s ' "$UI_CYAN" "$UI_SYM_ASK" "$UI_RESET" "$__prompt" "$UI_DIM" "$__default" "$UI_RESET"
    else
        printf -v __line '    %s%s%s %s ' "$UI_CYAN" "$UI_SYM_ASK" "$UI_RESET" "$__prompt"
    fi
    printf '%s' "$__line"
    IFS= read -r __answer || __status=$?
    # A piped answer is not echoed by the terminal, so echo it ourselves.
    if [ ! -t 0 ]; then printf '%s\n' "$__answer"; fi
    ui__log "$__line$__answer"
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
#
# With a run log open, that log is the command's log: its output goes straight
# into it, so even a run that is killed part way keeps what it had printed.
ui_spin() {
    local label=$1 done_label=$2 status=0 start
    shift 2
    start=$SECONDS
    if [ "$UI_TTY" != 1 ]; then
        ui_run "$label..."
        ui__log "      \$ $*"
        ( set -o pipefail; "$@" 2>&1 | ui_indent ) || status=$?
        ui__spin_end "$label" "$done_label" "$status" "$start"
        return "$status"
    fi

    local log offset=0 tick=0 last max
    if [ -n "$UI_LOG" ]; then
        log=$UI_LOG
        ui__log "    $UI_SYM_RUN $label..."
        ui__log "      \$ $*"
        offset=$(wc -c < "$log" | tr -d ' ')
    else
        log=$(mktemp)
    fi
    "$@" >> "$log" 2>&1 < /dev/null &
    local pid=$!
    UI__SPIN_PID=$pid
    max=$((UI_WIDTH - ${#label} - 14))
    while kill -0 "$pid" 2>/dev/null; do
        # The command's last line, minus colour codes and carriage-return
        # progress bars, cut to what fits after the label.
        last=$(tail -c +$((offset + 1)) "$log" 2>/dev/null | tail -c 400 | tr '\r' '\n' | sed "s/${UI_ESC}\[[0-9;]*[A-Za-z]//g" | grep -v '^[[:space:]]*$' | tail -n 1 | sed 's/^[[:space:]]*//' || true)
        if [ "$max" -gt 8 ] && [ "${#last}" -gt "$max" ]; then last="${last:0:$((max - 3))}$UI_ELLIPSIS"; fi
        if [ "$max" -le 8 ]; then last=""; fi
        printf '\r\033[K    %s%s%s %s  %s%s  %s%s' "$UI_CYAN" "$(ui__frame_at "$tick")" "$UI_RESET" \
            "$label" "$UI_DIM" "$(ui__elapsed $((SECONDS - start)))" "$last" "$UI_RESET"
        tick=$((tick + 1))
        sleep 0.1
    done
    wait "$pid" || status=$?
    UI__SPIN_PID=""
    ui__clear_line
    if [ "$status" -ne 0 ]; then
        # Read before ui_fail adds its own line to the log. On screen only:
        # with a run log open, this output is already in it.
        local output
        output=$(tail -c +$((offset + 1)) "$log")
        ui_fail "$label failed"
        if [ -n "$output" ]; then printf '%s\n' "$output" | sed 's/^/      /'; fi
    fi
    ui__spin_end "" "$done_label" "$status" "$start"
    if [ -z "$UI_LOG" ]; then rm -f "$log"; fi
    return "$status"
}

# How a ui_spin command ended: in the log always, on screen as a tick (or, off
# a terminal, a cross -- on one, ui_spin has already printed it). An empty
# $1 means the failure has been reported.
ui__spin_end() {
    local label=$1 done_label=$2 status=$3 took
    took=$(ui__elapsed $((SECONDS - $4)))
    # Output that did not end in a newline would swallow the line below.
    if [ -n "$UI_LOG" ] && [ -n "$(tail -c 1 "$UI_LOG")" ]; then echo "" >> "$UI_LOG"; fi
    ui__log "      (exit $status${took:+, $took})"
    if [ "$status" -ne 0 ]; then
        if [ -n "$label" ]; then ui_fail "$label failed"; fi
    elif [ -n "$done_label" ]; then
        ui_ok "$done_label"
    fi
}

# Poll until a command succeeds: ui_wait "Waiting for Postgres" "Postgres ready" TRIES SECONDS cmd args...
#
# Tries the command up to TRIES times, SECONDS apart. Prints the done label on
# success (nothing if it is empty); on giving up it prints nothing and returns
# 1, so the caller says what went wrong. The log gets the last try's output.
ui_wait() {
    local label=$1 done_label=$2 tries=$3 interval=$4
    shift 4
    local start=$SECONDS try=0 tick=0 ticks out
    out=$(mktemp)
    if [ "$UI_TTY" != 1 ]; then ui_run "$label..."; else ui__log "    $UI_SYM_RUN $label..."; fi
    ui__log "      \$ $*"
    while [ "$try" -lt "$tries" ]; do
        if [ "$UI_TTY" = 1 ]; then
            printf '\r\033[K    %s%s%s %s  %s%s%s' "$UI_CYAN" "$(ui__frame_at "$tick")" "$UI_RESET" \
                "$label" "$UI_DIM" "$(ui__elapsed $((SECONDS - start)))" "$UI_RESET"
        fi
        if "$@" > "$out" 2>&1; then
            ui__clear_line
            ui__log "      (ready on try $((try + 1)), $((SECONDS - start))s)"
            rm -f "$out"
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
    ui__log "      (gave up after $tries tries, $((SECONDS - start))s; the last one said:)"
    if [ -n "$UI_LOG" ]; then sed 's/^/      /' "$out" >> "$UI_LOG"; fi
    rm -f "$out"
    return 1
}

# The closing banner: ui_done "Installation complete"
ui_done() {
    ui__put ''
    ui__rule
    ui__put '  %s%s%s %s%s%s' "$UI_GREEN" "$UI_SYM_OK" "$UI_RESET" "$UI_BOLD" "$1" "$UI_RESET"
    ui__put ''
}
