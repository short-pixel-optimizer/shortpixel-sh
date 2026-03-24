#!/usr/bin/env bash
# ==============================================================================
# shortpixel-optimize.sh v3.0  — zero-dependency edition
#
# Batch-optimizes images using the ShortPixel API.
# Requires: bash 4+, curl  (uses grep/sed/awk — standard on every Unix system)
#
# USAGE:
#   ./shortpixel-optimize.sh [OPTIONS] [input_dir]
#
# If input_dir is omitted, the current working directory is used (recursively).
#
# REQUIRED (CLI or .env):
#   -k, --key KEY          Your ShortPixel API key
#
# OUTPUT OPTIONS (mutually exclusive):
#   -o, --output-dir DIR   Save optimized images to DIR
#                          (default: <input_dir>/optimized/, mirroring subdirs)
#       --overwrite        Replace original files with optimized versions
#
# BACKUP OPTIONS:
#       --backup-dir DIR   Custom backup mirror directory
#                          (default: <script_dir>/backups)
#       --restore          Copy all backup files back to source; delete .splog files
#       --purge-backups [N] Delete backup files older than N days (default: 30)
#                          that also have a .splog entry
#
# PROCESSING OPTIONS:
#   -j, --concurrency N    Parallel workers (default: 4)
#   -w, --wait N           API wait seconds, 1-30 (default: 25)
#       --force            Ignore existing .splog entries; re-optimize
#
# COMPRESSION OPTIONS:
#   -l, --lossy N          0=lossless, 1=lossy (default), 2=glossy
#       --keep-exif        Preserve EXIF metadata
#       --no-cmyk2rgb      Disable CMYK to RGB conversion
#
# RESIZE OPTIONS:
#       --resize MODE      0=none (default), 1=outer box, 3=inner box, 4=smart crop
#       --resize-width N   Target width in pixels
#       --resize-height N  Target height in pixels
#
# FORMAT OPTIONS:
#       --convertto FMT    +webp | +avif | +webp+avif
#       --upscale N        Upscale factor: 2, 3, or 4
#
# OTHER OPTIONS:
#       --bg-remove        Remove image background (uses extra API credits)
#   -h, --help             Show this help message and exit
#
# EXIT CODES:
#   0   Success / normal operation
#   1   API / Network error (fatal)
#   2   Permissions error
#   3   Configuration / dependency error
#
# .env FILE (loaded from the script's directory):
#   API_KEY      Your ShortPixel API key
#   BACKUP_DIR   Path to backup mirror directory (default: <script_dir>/backups)
#   EMAIL        Email address for analytics reports after each run (optional)
#   MAIL_CMD     Mail command to use: "mail" or "sendmail" (auto-detected)
#   EXCLUDE_EXT  Comma-separated, case-sensitive extensions to skip
#                Example: EXCLUDE_EXT=JPG,PNG
#
# EXAMPLES:
#   ./shortpixel-optimize.sh -k MY_KEY
#   ./shortpixel-optimize.sh -k MY_KEY --overwrite -j 8 -l 2 ./images
#   ./shortpixel-optimize.sh --restore ./images
#   ./shortpixel-optimize.sh --purge-backups 14 ./images
#   ./shortpixel-optimize.sh -k MY_KEY --force --overwrite ./images
#
# DEPENDENCIES: curl (uses only standard POSIX tools: grep, sed, awk, md5sum)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# SECTION 1: CONFIGURATION DEFAULTS
# ==============================================================================

readonly API_ENDPOINT="https://api.shortpixel.com/v2/post-reducer.php"

API_KEY=""
EMAIL=""
MAIL_CMD=""
LOSSY=1
API_WAIT=25
RESIZE=0
RESIZE_WIDTH=""
RESIZE_HEIGHT=""
CONVERTTO=""
KEEP_EXIF=0
CMYK2RGB=1
BG_REMOVE=0
UPSCALE=""
CONCURRENCY=4
MAX_POLL_RETRIES=12
POLL_SLEEP_SECONDS=5

INPUT_DIR=""
OUTPUT_DIR=""
OVERWRITE=false
FORCE=false
DO_RESTORE=false
DO_PURGE=false
PURGE_DAYS=30

BACKUP_DIR="${SCRIPT_DIR}/backups"
EXCLUDE_EXT=""

# Runtime state
PROGRESS_DIR=""
SEMAPHORE=""
TOTAL_FILES=0
WORKER_TMP_FILE=""
DASHBOARD_ENABLED=false

declare -a SKIPPED_FOLDERS=()
declare -A DIR_CHECKED=()

# Non-interactive detection (CRON: bypass prompts)
IS_INTERACTIVE=true
[[ -t 0 ]] || IS_INTERACTIVE=false

# ==============================================================================
# SECTION 2: TERMINAL COLORS
# ==============================================================================

if [[ -t 2 ]]; then
    COLOR_RED=$(tput setaf 1)
    COLOR_GREEN=$(tput setaf 2)
    COLOR_YELLOW=$(tput setaf 3)
    COLOR_BLUE=$(tput setaf 4)
    COLOR_CYAN=$(tput setaf 6)
    COLOR_RESET=$(tput sgr0)
    COLOR_BOLD=$(tput bold)
else
    COLOR_RED="" COLOR_GREEN="" COLOR_YELLOW=""
    COLOR_BLUE="" COLOR_CYAN="" COLOR_RESET="" COLOR_BOLD=""
fi

# ==============================================================================
# SECTION 3: LOGGING HELPERS
# ==============================================================================

log_info()    { echo "${COLOR_BLUE}[INFO]${COLOR_RESET}  $*" >&2; }
log_success() { echo "${COLOR_GREEN}[OK]${COLOR_RESET}    $*" >&2; }
log_warn()    { echo "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*" >&2; }
log_error()   { echo "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }

# ==============================================================================
# SECTION 4: HELP
# ==============================================================================

show_help() {
    sed -n '/^# ===/{p; :loop; n; /^# ===/q; p; b loop}' "$0" | sed 's/^# \{0,1\}//'
}

# ==============================================================================
# SECTION 5: FILE UTILITIES
# ==============================================================================

get_file_size() {
    stat --format="%s" "$1" 2>/dev/null \
        || stat -f "%z" "$1" 2>/dev/null \
        || echo "0"
}

get_file_extension() {
    local f="${1##*/}"
    echo "${f##*.}"
}

get_file_extension_lower() {
    local ext
    ext=$(get_file_extension "$1")
    echo "${ext,,}"
}

get_md5() {
    if command -v md5sum &>/dev/null; then
        md5sum "$1" | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        md5 -q "$1"
    else
        echo "00000000000000000000000000000000"
    fi
}

format_bytes() {
    local bytes="${1:-0}"
    if (( bytes >= 1073741824 )); then
        LC_NUMERIC=C awk "BEGIN { printf \"%.2f GB\", $bytes / 1073741824 }"
    elif (( bytes >= 1048576 )); then
        LC_NUMERIC=C awk "BEGIN { printf \"%.2f MB\", $bytes / 1048576 }"
    elif (( bytes >= 1024 )); then
        LC_NUMERIC=C awk "BEGIN { printf \"%.2f KB\", $bytes / 1024 }"
    else
        printf "%d B" "$bytes"
    fi
}

sum_size_file() {
    [[ -f "$1" ]] || { echo 0; return; }
    awk '{s += $1} END {printf "%d", s+0}' "$1"
}

# ==============================================================================
# SECTION 6: JSON PARSING  (no jq required)
#
# All parsers expect a compact single-line JSON string.
# _json_first() normalises array-or-object input to a single-object string.
# ==============================================================================

# If JSON starts with '[', extract the first {...} object; otherwise return as-is.
# Also collapses newlines so callers don't have to worry about multi-line input.
_json_first() {
    local json
    json=$(printf '%s' "$1" | tr -d '\n\r')
    if [[ "${json:0:1}" != "[" ]]; then
        printf '%s' "$json"
        return
    fi
    printf '%s' "$json" | awk '
    BEGIN { depth=0; start=0; done=0 }
    {
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") { if (!depth) start=i; depth++ }
            if (c == "}" && depth > 0) {
                depth--
                if (!depth) { print substr($0, start, i-start+1); done=1; exit }
            }
        }
    }
    END { if (!done) print $0 }
    '
}

# Extract Status.Code from a (single-object) JSON string.
# Matches "Status":{"Code":"X",...} using grep's -o flag.
_json_status_code() {
    printf '%s' "$1" \
        | grep -o '"Status"[[:space:]]*:[[:space:]]*{[^}]*}' \
        | grep -o '"Code"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"Code"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/'
}

# Extract Status.Message
_json_status_message() {
    printf '%s' "$1" \
        | grep -o '"Status"[[:space:]]*:[[:space:]]*{[^}]*}' \
        | grep -o '"Message"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"Message"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/'
}

# Extract a top-level string field:  "Key":"Value"  ->  Value
_json_str() {
    local json="$1" key="$2"
    printf '%s' "$json" \
        | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed "s/^\"[^\"]*\"[[:space:]]*:[[:space:]]*\"//;s/\"$//"
}

# Extract a top-level numeric field:  "Key":12345  ->  12345
_json_num() {
    local json="$1" key="$2"
    printf '%s' "$json" \
        | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*-\?[0-9][0-9]*" \
        | head -1 \
        | sed 's/.*:[[:space:]]*//'
}

# ==============================================================================
# SECTION 7: EXCLUSION CHECK  (case-sensitive extension match)
# ==============================================================================

is_excluded() {
    [[ -z "$EXCLUDE_EXT" ]] && return 1
    local actual_ext e
    actual_ext=$(get_file_extension "$1")
    IFS=',' read -ra _excl_arr <<< "$EXCLUDE_EXT"
    for e in "${_excl_arr[@]}"; do
        e="${e// /}"
        [[ "$actual_ext" == "$e" ]] && return 0
    done
    return 1
}

# ==============================================================================
# SECTION 8: .splog MANAGEMENT
#
# One .splog file per directory, alongside the images it tracks.
# Format per line (pipe-delimited):
#   md5|filename|orig_size|opt_size|savings_pct|comp_type|epoch_timestamp
# ==============================================================================

splog_prune() {
    local dir="$1" splog tmp
    splog="${dir}/.splog"
    [[ -f "$splog" ]] || return 0
    tmp=$(mktemp)
    while IFS='|' read -r md5 filename rest; do
        [[ -z "$filename" ]] && continue
        [[ -f "${dir}/${filename}" ]] && printf '%s|%s|%s\n' "$md5" "$filename" "$rest"
    done < "$splog" > "$tmp"
    mv "$tmp" "$splog"
}

splog_has_entry() {
    local splog="${1}/.splog"
    [[ -f "$splog" ]] || return 1
    awk -F'|' -v f="$2" '$2==f {found=1; exit} END {exit !found}' "$splog"
}

splog_write_entry() {
    local dir="$1" md5="$2" filename="$3"
    local orig_size="$4" opt_size="$5" savings="$6" comp_type="$7"
    local timestamp splog lock_key lock_file
    timestamp=$(date +%s)
    splog="${dir}/.splog"
    lock_key=$(printf '%s' "$dir" | md5sum 2>/dev/null | cut -d' ' -f1 \
               || printf '%s' "$dir" | cksum | cut -d' ' -f1)
    lock_file="${PROGRESS_DIR}/splog_${lock_key}.lock"
    (
        flock -x 9
        local tmp
        tmp=$(mktemp)
        [[ -f "$splog" ]] && awk -F'|' -v f="$filename" '$2!=f {print}' "$splog" > "$tmp" 2>/dev/null || true
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$md5" "$filename" "$orig_size" "$opt_size" "$savings" "$comp_type" "$timestamp" >> "$tmp"
        mv "$tmp" "$splog"
    ) 9>"$lock_file"
}

# ==============================================================================
# SECTION 9: BACKUP MANAGEMENT
# ==============================================================================

get_backup_path() {
    echo "${BACKUP_DIR}/${1#${INPUT_DIR}/}"
}

backup_file() {
    local backup_path
    backup_path=$(get_backup_path "$1")
    mkdir -p "$(dirname "$backup_path")"
    cp "$1" "$backup_path" || { log_error "Backup failed: $1 → $backup_path"; return 1; }
}

verify_backup() {
    local sz
    [[ -f "$1" ]] || { log_error "Backup missing: $1";              return 1; }
    sz=$(get_file_size "$1")
    (( sz > 0 ))  || { log_error "Backup is empty (0 bytes): $1";   return 1; }
}

# ==============================================================================
# SECTION 10: PROGRESS TRACKING
# ==============================================================================

increment_counter() { printf '\n' >> "$1"; }

show_progress() {
    local total="$1" pd="$2" s=0 e=0 sk=0 ex=0 done rem
    [[ -f "$pd/success"  ]] && s=$( wc -l < "$pd/success")
    [[ -f "$pd/error"    ]] && e=$( wc -l < "$pd/error")
    [[ -f "$pd/skipped"  ]] && sk=$(wc -l < "$pd/skipped")
    [[ -f "$pd/excluded" ]] && ex=$(wc -l < "$pd/excluded")
    done=$(( s + e ))
    rem=$(( total - done - sk - ex ))
    (( rem < 0 )) && rem=0
    printf '\r%s[%d/%d]%s  OK:%s%d%s  Err:%s%d%s  Skip:%d  Excl:%d  Rem:%d   ' \
        "$COLOR_BOLD" "$done" "$total" "$COLOR_RESET" \
        "$COLOR_GREEN" "$s"   "$COLOR_RESET" \
        "$COLOR_RED"   "$e"   "$COLOR_RESET" \
        "$sk" "$ex" "$rem" >&2
}

# ==============================================================================
# SECTION 11: EMAIL REPORT
# ==============================================================================

_detect_mail_cmd() {
    if   command -v mail     &>/dev/null; then echo "mail"
    elif command -v sendmail &>/dev/null; then echo "sendmail"
    else echo ""
    fi
}

# send_email_report SUBJECT BODY
send_email_report() {
    [[ -z "${EMAIL:-}" ]] && return 0
    [[ -z "${MAIL_CMD:-}" ]] && MAIL_CMD=$(_detect_mail_cmd)
    if [[ -z "$MAIL_CMD" ]]; then
        log_warn "No mail command found; email report skipped."
        return 0
    fi
    local subject="$1" body="$2"
    case "$MAIL_CMD" in
        mail)
            printf '%s' "$body" | mail -s "$subject" "$EMAIL" 2>/dev/null \
                && log_success "Report emailed to $EMAIL" \
                || log_warn "Failed to send email report."
            ;;
        sendmail)
            { printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s' \
                "$EMAIL" "$subject" "$body"; } \
                | sendmail -t 2>/dev/null \
                && log_success "Report emailed to $EMAIL" \
                || log_warn "Failed to send email report."
            ;;
    esac
}

# ==============================================================================
# SECTION 12: API INTERACTION
# ==============================================================================

download_file() {
    mkdir -p "$(dirname "$2")"
    curl --fail --silent --show-error --location --output "$2" "$1"
}

optimize_single_file() {
    local input_file="$1"
    local filename file_dir output_file comp_type original_size backup_path md5
    local extension curl_max_time api_response curl_exit
    local first_obj status_code status_message original_url
    local download_url optimized_size opt_size_int savings_pct tmp_dl

    filename="$(basename  "$input_file")"
    file_dir="$(dirname   "$input_file")"

    if   [[ "$OVERWRITE" == "true" ]]; then output_file="$input_file"
    elif [[ -n "$OUTPUT_DIR"       ]]; then output_file="${OUTPUT_DIR}/${filename}"
    else                                    output_file="${file_dir}/optimized/${filename}"
    fi

    case "$LOSSY" in
        0) comp_type="lossless" ;;
        1) comp_type="lossy"    ;;
        2) comp_type="glossy"   ;;
        *) comp_type="unknown"  ;;
    esac

    original_size=$(get_file_size "$input_file")
    backup_path=$(get_backup_path "$input_file")

    if ! backup_file "$input_file" || ! verify_backup "$backup_path"; then
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    md5=$(get_md5 "$backup_path")

    # Temp file with safe (space-free) path for curl
    extension=$(get_file_extension_lower "$filename")
    WORKER_TMP_FILE=$(mktemp "/tmp/sp_upload_XXXXXX.${extension}")
    if ! cp "$input_file" "$WORKER_TMP_FILE"; then
        log_error "Cannot create temp upload file for: $filename"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    curl_max_time=$(( API_WAIT + 60 ))
    (( curl_max_time < 60 )) && curl_max_time=60

    local -a curl_args=(
        --silent --show-error --max-time "$curl_max_time"
        -F "key=${API_KEY}"
        -F "lossy=${LOSSY}"
        -F "wait=${API_WAIT}"
        -F "resize=${RESIZE}"
        -F "keep_exif=${KEEP_EXIF}"
        -F "cmyk2rgb=${CMYK2RGB}"
        -F "bg_remove=${BG_REMOVE}"
        -F "file_paths={\"file1\":\"${filename}\"}"
        -F "file1=@${WORKER_TMP_FILE}"
    )
    [[ -n "$RESIZE_WIDTH"  ]] && curl_args+=(-F "resize_width=${RESIZE_WIDTH}")
    [[ -n "$RESIZE_HEIGHT" ]] && curl_args+=(-F "resize_height=${RESIZE_HEIGHT}")
    [[ -n "$CONVERTTO"     ]] && curl_args+=(-F "convertto=${CONVERTTO}")
    [[ -n "$UPSCALE"       ]] && curl_args+=(-F "upscale=${UPSCALE}")

    log_info "Uploading: $filename"
    api_response=$(curl "${curl_args[@]}" "$API_ENDPOINT" 2>&1) || curl_exit=$?
    curl_exit="${curl_exit:-0}"

    if (( curl_exit != 0 )); then
        if (( curl_exit == 28 )); then
            log_error "Upload timed out for: $filename (key may be domain-restricted or no credits)"
        else
            log_error "Upload failed (curl exit $curl_exit) for: $filename"
        fi
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    first_obj=$(_json_first "$api_response")
    status_code=$(_json_status_code "$first_obj")
    status_message=$(_json_status_message "$first_obj")
    original_url=$(_json_str "$first_obj" "OriginalURL")

    if [[ -z "$status_code" ]]; then
        log_error "Could not parse API response for: $filename"
        log_error "Raw: ${api_response:0:300}"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # Polling loop  (status "1" = processing)
    local poll_count=0
    while [[ "$status_code" == "1" ]]; do
        if (( poll_count >= MAX_POLL_RETRIES )); then
            log_error "Polling timed out for: $filename"
            increment_counter "$PROGRESS_DIR/error"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            return 1
        fi
        log_info "  '$filename' pending (poll $((poll_count+1))/$MAX_POLL_RETRIES, ${POLL_SLEEP_SECONDS}s)..."
        sleep "$POLL_SLEEP_SECONDS"
        (( poll_count++ )) || true

        api_response=$(curl --silent --show-error \
            --max-time "$curl_max_time" \
            -F "key=${API_KEY}" \
            -F "wait=${API_WAIT}" \
            -F "file_urls[]=${original_url}" \
            "$API_ENDPOINT" 2>&1) || {
                log_error "Poll request failed: $filename"
                increment_counter "$PROGRESS_DIR/error"
                show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
                return 1
            }

        first_obj=$(_json_first "$api_response")
        status_code=$(_json_status_code "$first_obj")
        status_message=$(_json_status_message "$first_obj")
    done

    if [[ "$status_code" != "2" ]]; then
        log_error "API error for '$filename': [Code $status_code] $status_message"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    if [[ "$LOSSY" == "0" ]]; then
        download_url=$(_json_str "$first_obj" "LosslessURL")
        optimized_size=$(_json_num "$first_obj" "LoselessSize")
    else
        download_url=$(_json_str "$first_obj" "LossyURL")
        optimized_size=$(_json_num "$first_obj" "LossySize")
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        log_error "No download URL in API response for: $filename"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    tmp_dl=$(mktemp "/tmp/sp_dl_XXXXXX.${extension}")
    if ! download_file "$download_url" "$tmp_dl"; then
        rm -f "$tmp_dl"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    mkdir -p "$(dirname "$output_file")"
    mv "$tmp_dl" "$output_file"

    opt_size_int="${optimized_size:-0}"
    savings_pct="0.00"
    if (( original_size > 0 && opt_size_int > 0 )); then
        local si=$(( (original_size - opt_size_int) * 10000 / original_size ))
        savings_pct=$(printf '%d.%02d' $(( si / 100 )) $(( si % 100 )))
    fi

    splog_write_entry "$file_dir" "$md5" "$filename" \
        "$original_size" "$opt_size_int" "$savings_pct" "$comp_type"

    printf '%020d\n' "$original_size"  >> "$PROGRESS_DIR/orig_bytes"
    printf '%020d\n' "$opt_size_int"   >> "$PROGRESS_DIR/opt_bytes"

    increment_counter "$PROGRESS_DIR/success"
    show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
    log_success "$filename: $(format_bytes "$original_size") → $(format_bytes "$opt_size_int") (${savings_pct}% saved)"
    return 0
}

process_file() {
    local input_file="$1"
    trap '[[ -n "${WORKER_TMP_FILE:-}" ]] && rm -f "$WORKER_TMP_FILE"; echo >&3' EXIT
    optimize_single_file "$input_file" || true
}

# ==============================================================================
# SECTION 13: ANALYTICS DASHBOARD
# ==============================================================================

show_dashboard() {
    [[ "$DASHBOARD_ENABLED" == "true" ]] || return 0

    local s=0 e=0 sk=0 ex=0
    [[ -f "$PROGRESS_DIR/success"  ]] && s=$( wc -l < "$PROGRESS_DIR/success"  | tr -d ' ')
    [[ -f "$PROGRESS_DIR/error"    ]] && e=$( wc -l < "$PROGRESS_DIR/error"    | tr -d ' ')
    [[ -f "$PROGRESS_DIR/skipped"  ]] && sk=$(wc -l < "$PROGRESS_DIR/skipped"  | tr -d ' ')
    [[ -f "$PROGRESS_DIR/excluded" ]] && ex=$(wc -l < "$PROGRESS_DIR/excluded" | tr -d ' ')

    local sum_orig sum_opt sum_disp sum_excl sum_skip
    sum_orig=$(sum_size_file "$PROGRESS_DIR/orig_bytes")
    sum_opt=$( sum_size_file "$PROGRESS_DIR/opt_bytes")
    sum_disp=$(sum_size_file "$PROGRESS_DIR/all_orig_bytes")
    sum_excl=$(sum_size_file "$PROGRESS_DIR/excl_sizes")
    sum_skip=$(sum_size_file "$PROGRESS_DIR/skip_sizes")

    local total_orig=$(( sum_disp + sum_excl + sum_skip ))
    local current_source=$(( sum_opt + total_orig - sum_orig ))
    local savings=$(( sum_orig - sum_opt ))
    (( savings < 0 )) && savings=0

    local savings_pct="0.00"
    if (( total_orig > 0 )); then
        local sp_int=$(( savings * 10000 / total_orig ))
        savings_pct=$(printf '%d.%02d' $(( sp_int / 100 )) $(( sp_int % 100 )))
    fi

    local backup_size=0
    if [[ -d "$BACKUP_DIR" ]]; then
        while IFS= read -r -d '' f; do
            local fsz; fsz=$(get_file_size "$f")
            (( backup_size += fsz )) || true
        done < <(find "$BACKUP_DIR" -type f ! -name ".splog" -print0 2>/dev/null)
    fi
    local total_footprint=$(( current_source + backup_size ))

    # ── Terminal (box-drawing) version ─────────────────────────────────────
    local W=54
    local sep; sep=$(printf '═%.0s' $(seq 1 $W))

    _drow() { printf "${COLOR_BOLD}${COLOR_CYAN}║${COLOR_RESET} %-${W}s ${COLOR_BOLD}${COLOR_CYAN}║${COLOR_RESET}\n" "$1" >&2; }
    _dhdr() { printf "${COLOR_BOLD}${COLOR_CYAN}╠%s╣${COLOR_RESET}\n" "$sep" >&2; }

    echo >&2
    printf "${COLOR_BOLD}${COLOR_CYAN}╔%s╗${COLOR_RESET}\n" "$sep" >&2
    local _title="  SHORTPIXEL ANALYTICS DASHBOARD  "
    local _pad=$(( (W - ${#_title}) / 2 ))
    printf "${COLOR_BOLD}${COLOR_CYAN}║${COLOR_RESET}%*s${COLOR_BOLD}%s${COLOR_RESET}%*s${COLOR_BOLD}${COLOR_CYAN}║${COLOR_RESET}\n" \
        "$(( _pad + 1 ))" "" "$_title" "$(( W - _pad - ${#_title} + 1 ))" "" >&2
    _dhdr

    _drow "  ${COLOR_BOLD}FILE SUMMARY${COLOR_RESET}"
    _drow "$(printf '    %-22s %s%d%s' 'Processed (success):' "$COLOR_GREEN" "$s"  "$COLOR_RESET")"
    _drow "$(printf '    %-22s %s%d%s' 'Failed/Error:'        "$COLOR_RED"   "$e"  "$COLOR_RESET")"
    _drow "$(printf '    %-22s %d'     'Skipped (.splog):'                   "$sk"               )"
    _drow "$(printf '    %-22s %d'     'Excluded (ext):'                     "$ex"               )"

    if [[ ${#SKIPPED_FOLDERS[@]} -gt 0 ]]; then
        _dhdr
        _drow "  ${COLOR_BOLD}${COLOR_YELLOW}SKIPPED FOLDERS (no write permission)${COLOR_RESET}"
        local folder
        for folder in "${SKIPPED_FOLDERS[@]}"; do
            local short="$folder"
            (( ${#short} > W - 4 )) && short="...${folder: -(($W - 7))}"
            _drow "  ${COLOR_YELLOW}${short}${COLOR_RESET}"
        done
    fi

    _dhdr
    _drow "  ${COLOR_BOLD}SOURCE SAVINGS${COLOR_RESET}"
    _drow "$(printf '    %-22s %s' 'Original total:'  "$(format_bytes "$total_orig")"     )"
    _drow "$(printf '    %-22s %s' 'Current total:'   "$(format_bytes "$current_source")" )"
    _drow "$(printf '    %-22s %s%s (%s%%)%s' 'Saved:' \
        "$COLOR_GREEN" "$(format_bytes "$savings")" "$savings_pct" "$COLOR_RESET")"

    _dhdr
    _drow "  ${COLOR_BOLD}TOTAL SYSTEM FOOTPRINT${COLOR_RESET}"
    _drow "$(printf '    %-22s %s' 'Current source:'  "$(format_bytes "$current_source")"  )"
    _drow "$(printf '    %-22s %s' 'Backup folder:'   "$(format_bytes "$backup_size")"     )"
    _drow "$(printf '    %-22s %s' 'Total:'           "$(format_bytes "$total_footprint")" )"

    printf "${COLOR_BOLD}${COLOR_CYAN}╚%s╝${COLOR_RESET}\n" "$sep" >&2
    echo >&2

    # ── Email report (plain text) ───────────────────────────────────────────
    if [[ -n "${EMAIL:-}" ]]; then
        local plain_report
        plain_report=$(cat <<EOFREPORT
SHORTPIXEL ANALYTICS DASHBOARD
Run date : $(date '+%Y-%m-%d %H:%M:%S')
Directory: ${INPUT_DIR:-N/A}
=======================================================

FILE SUMMARY
  Processed (success): ${s}
  Failed/Error:        ${e}
  Skipped (.splog):    ${sk}
  Excluded (ext):      ${ex}

SOURCE SAVINGS
  Original total : $(format_bytes "$total_orig")
  Current total  : $(format_bytes "$current_source")
  Saved          : $(format_bytes "$savings") (${savings_pct}%)

TOTAL SYSTEM FOOTPRINT
  Current source : $(format_bytes "$current_source")
  Backup folder  : $(format_bytes "$backup_size")
  Total          : $(format_bytes "$total_footprint")
EOFREPORT
)
        send_email_report "ShortPixel Run Report — $(date '+%Y-%m-%d %H:%M')" "$plain_report"
    fi
}

# ==============================================================================
# SECTION 14: RESTORE
# ==============================================================================

do_restore() {
    log_info "Restoring: $BACKUP_DIR → $INPUT_DIR"
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 2
    fi

    local audit_log="${SCRIPT_DIR}/restore_audit.log"
    : > "$audit_log"
    local restored=0 failed=0

    while IFS= read -r -d '' bfile; do
        local rel="${bfile#${BACKUP_DIR}/}"
        local src="${INPUT_DIR}/${rel}"
        mkdir -p "$(dirname "$src")"
        if cp "$bfile" "$src"; then
            echo "$src"          >> "$audit_log"
            log_success "Restored: $rel"
            (( restored++ )) || true
        else
            echo "FAILED: $src"  >> "$audit_log"
            log_error "Failed to restore: $rel"
            (( failed++ )) || true
        fi
    done < <(find "$BACKUP_DIR" -type f ! -name ".splog" -print0 2>/dev/null)

    log_info "Removing .splog files from source tree..."
    find "$INPUT_DIR" -name ".splog" -delete 2>/dev/null || true

    log_success "Restore complete: ${restored} restored, ${failed} failed"
    log_info "Audit log: $audit_log"
}

# ==============================================================================
# SECTION 15: PURGE BACKUPS
# ==============================================================================

do_purge_backups() {
    local days="$1"
    log_info "Purging backup files older than ${days} days (only if in .splog)..."
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "Backup directory not found: $BACKUP_DIR"
        return 0
    fi

    local purged=0 kept=0
    while IFS= read -r -d '' bfile; do
        local rel="${bfile#${BACKUP_DIR}/}"
        local fname; fname=$(basename "$rel")
        local rdir;  rdir=$(dirname  "$rel")
        local sdir
        [[ "$rdir" == "." ]] && sdir="$INPUT_DIR" || sdir="${INPUT_DIR}/${rdir}"

        if splog_has_entry "$sdir" "$fname"; then
            log_info "Purging: $rel"
            rm -f "$bfile"
            (( purged++ )) || true
        else
            log_info "Keeping (no .splog entry): $rel"
            (( kept++ )) || true
        fi
    done < <(find "$BACKUP_DIR" -type f ! -name ".splog" -mtime +"${days}" -print0 2>/dev/null)

    find "$BACKUP_DIR" -type d -empty -delete 2>/dev/null || true
    log_success "Purge complete: ${purged} deleted, ${kept} kept"
}

# ==============================================================================
# SECTION 16: ONBOARDING WIZARD
# (runs only when .env is missing AND a TTY is attached)
# ==============================================================================

run_wizard() {
    # Helper: prompt with a default value; returns user input or the default
    # Usage: _ask "Prompt text" "default_value" -> sets _wiz_ans
    _ask() {
        local prompt="$1" default="$2"
        if [[ -n "$default" ]]; then
            printf "${COLOR_BOLD}%s${COLOR_RESET} [%s]: " "$prompt" "$default" >&2
        else
            printf "${COLOR_BOLD}%s${COLOR_RESET}: " "$prompt" >&2
        fi
        read -r _wiz_ans || { echo >&2; exit 1; }
        _wiz_ans="${_wiz_ans# }"; _wiz_ans="${_wiz_ans% }"
        if [[ -z "$_wiz_ans" ]]; then _wiz_ans="$default"; fi
    }
    # Helper: yes/no prompt; returns 0 for yes, 1 for no
    # Usage: _ask_yn "Prompt" "Y"  (second arg is the default: Y or N)
    _ask_yn() {
        local prompt="$1" default="${2:-Y}" hint
        if [[ "$default" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
        printf "${COLOR_BOLD}%s${COLOR_RESET} [%s]: " "$prompt" "$hint" >&2
        read -r _wiz_yn || { echo >&2; exit 1; }
        _wiz_yn="${_wiz_yn# }"; _wiz_yn="${_wiz_yn% }"
        if [[ -z "$_wiz_yn" ]]; then _wiz_yn="$default"; fi
        [[ "${_wiz_yn,,}" == "y" ]]
    }

    echo >&2
    printf "${COLOR_BOLD}${COLOR_CYAN}╔══════════════════════════════════════════════╗${COLOR_RESET}\n" >&2
    printf "${COLOR_BOLD}${COLOR_CYAN}║   ShortPixel Optimizer — First-Run Setup     ║${COLOR_RESET}\n" >&2
    printf "${COLOR_BOLD}${COLOR_CYAN}╚══════════════════════════════════════════════╝${COLOR_RESET}\n" >&2
    echo >&2
    log_info "No .env found. Let's create one in: ${SCRIPT_DIR}/"
    log_info "Press Enter to accept the default shown in [brackets]. Ctrl+C to abort."
    echo >&2

    # ── API Key (required) ──────────────────────────────────────────────────
    printf "${COLOR_BOLD}${COLOR_YELLOW}── REQUIRED ──────────────────────────────────${COLOR_RESET}\n" >&2
    local wiz_key=""
    while [[ -z "$wiz_key" ]]; do
        _ask "ShortPixel API key  (get one at shortpixel.com/api-key)" ""
        wiz_key="$_wiz_ans"
        if [[ -z "$wiz_key" ]]; then log_warn "API key cannot be empty."; fi
    done
    echo >&2

    # ── Compression ─────────────────────────────────────────────────────────
    printf "${COLOR_BOLD}${COLOR_CYAN}── COMPRESSION ───────────────────────────────${COLOR_RESET}\n" >&2
    log_info "Lossy mode: 0=lossless, 1=lossy, 2=glossy"
    _ask "Default compression mode" "1"; local wiz_lossy="$_wiz_ans"
    [[ "$wiz_lossy" =~ ^[012]$ ]] || { log_warn "Invalid value; using 1 (lossy)."; wiz_lossy=1; }

    _ask_yn "Keep EXIF metadata" "N" && local wiz_keep_exif=1 || local wiz_keep_exif=0
    echo >&2

    # ── Processing ──────────────────────────────────────────────────────────
    printf "${COLOR_BOLD}${COLOR_CYAN}── PROCESSING ────────────────────────────────${COLOR_RESET}\n" >&2
    _ask "Parallel workers" "4";           local wiz_concurrency="$_wiz_ans"
    [[ "$wiz_concurrency" =~ ^[1-9][0-9]*$ ]] || { log_warn "Invalid; using 4."; wiz_concurrency=4; }

    _ask "API wait seconds (1-30)" "25";   local wiz_wait="$_wiz_ans"
    [[ "$wiz_wait" =~ ^[0-9]+$ ]] && (( wiz_wait >= 1 && wiz_wait <= 30 )) \
        || { log_warn "Invalid; using 25."; wiz_wait=25; }
    echo >&2

    # ── Output ──────────────────────────────────────────────────────────────
    printf "${COLOR_BOLD}${COLOR_CYAN}── OUTPUT ────────────────────────────────────${COLOR_RESET}\n" >&2
    local wiz_overwrite=false wiz_output_dir=""
    if _ask_yn "Overwrite original files with optimized versions" "N"; then
        wiz_overwrite=true
        log_info "Originals will be replaced in-place (backup is still taken first)."
    else
        _ask "Save optimized files to a custom directory (Enter to use <source>/optimized/)" ""
        wiz_output_dir="$_wiz_ans"
        if [[ -n "$wiz_output_dir" ]]; then
            log_info "Optimized files will go to: $wiz_output_dir"
        else
            log_info "Optimized files will go to <source_dir>/optimized/ (default)."
        fi
    fi

    _ask "Extensions to exclude, comma-separated, case-sensitive (e.g. JPG,PNG)" ""
    local wiz_exclude="$_wiz_ans"
    echo >&2

    # ── Backup ──────────────────────────────────────────────────────────────
    printf "${COLOR_BOLD}${COLOR_CYAN}── BACKUP ────────────────────────────────────${COLOR_RESET}\n" >&2
    local wiz_backup="" wiz_backup_enabled=false
    if _ask_yn "Enable backups (originals mirrored before any change)" "Y"; then
        wiz_backup_enabled=true
        _ask "Backup directory" "${SCRIPT_DIR}/backups"
        wiz_backup="$_wiz_ans"
    else
        log_info "Backups disabled. Originals will not be mirrored."
    fi
    echo >&2

    # ── Email ───────────────────────────────────────────────────────────────
    printf "${COLOR_BOLD}${COLOR_CYAN}── EMAIL REPORTS ─────────────────────────────${COLOR_RESET}\n" >&2
    _ask "Email address for run reports (Enter to skip)" ""; local wiz_email="$_wiz_ans"

    local wiz_mail_cmd=""
    if [[ -n "$wiz_email" ]]; then
        wiz_mail_cmd=$(_detect_mail_cmd)
        if [[ -n "$wiz_mail_cmd" ]]; then
            log_success "Mail command detected: ${wiz_mail_cmd}"
            if _ask_yn "Send a test email to ${wiz_email} now" "N"; then
                local test_body="ShortPixel Optimizer — test email. Setup is working!"
                if [[ "$wiz_mail_cmd" == "mail" ]]; then
                    printf '%s' "$test_body" | mail -s "ShortPixel Test" "$wiz_email" 2>/dev/null \
                        && log_success "Test email sent to $wiz_email." \
                        || log_warn "Test email may have failed — check mail logs."
                else
                    { printf 'To: %s\nSubject: ShortPixel Test\n\n%s' "$wiz_email" "$test_body"; } \
                        | sendmail -t 2>/dev/null \
                        && log_success "Test email sent to $wiz_email." \
                        || log_warn "Test email may have failed — check mail logs."
                fi
            fi
        else
            log_warn "No mail/sendmail found. Email reports will be disabled."
            log_warn "Install mailutils (Debian/Ubuntu) or mailx (RHEL/macOS) to enable."
            wiz_email=""
        fi
    fi
    echo >&2

    # ── Write .env ──────────────────────────────────────────────────────────
    local env_file="${SCRIPT_DIR}/.env"
    {
        cat <<EOF
# ShortPixel Optimizer — Configuration
# Generated by setup wizard on $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file at any time; CLI flags always take precedence.
#
# Get your API key at: https://shortpixel.com/api-key

# ── Required ───────────────────────────────────────────────────────────────

# Your ShortPixel API key
API_KEY=${wiz_key}

# ── Compression ────────────────────────────────────────────────────────────

# Lossy mode: 0=lossless, 1=lossy, 2=glossy
LOSSY=${wiz_lossy}

# Keep EXIF metadata: 0=strip (default), 1=keep
KEEP_EXIF=${wiz_keep_exif}

# ── Processing ─────────────────────────────────────────────────────────────

# Parallel workers
CONCURRENCY=${wiz_concurrency}

# API wait seconds (1-30)
API_WAIT=${wiz_wait}

# ── Output ─────────────────────────────────────────────────────────────────

# Overwrite originals in-place (true/false). Backup is always taken first.
OVERWRITE=${wiz_overwrite}

# Save optimized files to a fixed directory (leave empty for <source>/optimized/)
# Ignored when OVERWRITE=true
EOF
        if [[ -n "$wiz_output_dir" ]]; then
            echo "OUTPUT_DIR=${wiz_output_dir}"
        else
            echo "# OUTPUT_DIR="
        fi
        cat <<EOF

# Comma-separated extensions to exclude (case-sensitive). Example: JPG,PNG
EOF
        if [[ -n "$wiz_exclude" ]]; then
            echo "EXCLUDE_EXT=${wiz_exclude}"
        else
            echo "# EXCLUDE_EXT="
        fi
        cat <<EOF

# ── Backup ─────────────────────────────────────────────────────────────────

# Set to the backup mirror directory, or leave empty to disable backups
EOF
        if [[ "$wiz_backup_enabled" == "true" ]]; then
            echo "BACKUP_DIR=${wiz_backup}"
        else
            echo "# BACKUP_DIR="
        fi
        cat <<EOF

# ── Email Reports ──────────────────────────────────────────────────────────

# Email address for analytics reports after each run (leave empty to disable)
EMAIL=${wiz_email}

# Mail command: "mail" or "sendmail" (leave empty to auto-detect)
MAIL_CMD=${wiz_mail_cmd}
EOF
    } > "$env_file"

    echo >&2
    log_success ".env created: $env_file"
    log_info "You can re-run the wizard at any time by deleting .env."
    echo >&2
}

# ==============================================================================
# SECTION 17: LOAD .env  +  ARGUMENT PARSING
# (configuration hierarchy: defaults → .env → CLI flags)
# ==============================================================================

# Run wizard if .env is absent
if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
    if [[ "$IS_INTERACTIVE" == "true" ]]; then
        run_wizard
    else
        log_warn "No .env file found and running non-interactively. Use -k/--key to supply API_KEY."
    fi
fi

# Load .env (overrides defaults set in Section 1)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Preserve .env values with fallback to defaults
API_KEY="${API_KEY:-}"
EMAIL="${EMAIL:-}"
MAIL_CMD="${MAIL_CMD:-}"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
EXCLUDE_EXT="${EXCLUDE_EXT:-}"

# CLI argument parsing  (overrides .env values)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)           show_help; exit 0 ;;

        -k|--key)            API_KEY="$2";          shift 2 ;;
        --key=*)             API_KEY="${1#*=}";      shift   ;;

        -o|--output-dir)     OUTPUT_DIR="$2";        shift 2 ;;
        --output-dir=*)      OUTPUT_DIR="${1#*=}";   shift   ;;

        --overwrite)         OVERWRITE=true;         shift   ;;
        --force)             FORCE=true;             shift   ;;
        --restore)           DO_RESTORE=true;        shift   ;;

        --purge-backups)
            DO_PURGE=true
            [[ "${2:-}" =~ ^[0-9]+$ ]] && { PURGE_DAYS="$2"; shift 2; } || shift ;;
        --purge-backups=*)   DO_PURGE=true; PURGE_DAYS="${1#*=}"; shift ;;

        --backup-dir)        BACKUP_DIR="$2";        shift 2 ;;
        --backup-dir=*)      BACKUP_DIR="${1#*=}";   shift   ;;

        -j|--concurrency)    CONCURRENCY="$2";       shift 2 ;;
        --concurrency=*)     CONCURRENCY="${1#*=}";  shift   ;;

        -w|--wait)           API_WAIT="$2";          shift 2 ;;
        --wait=*)            API_WAIT="${1#*=}";     shift   ;;

        -l|--lossy)          LOSSY="$2";             shift 2 ;;
        --lossy=*)           LOSSY="${1#*=}";        shift   ;;
        --keep-exif)         KEEP_EXIF=1;            shift   ;;
        --no-cmyk2rgb)       CMYK2RGB=0;             shift   ;;

        --resize)            RESIZE="$2";            shift 2 ;;
        --resize=*)          RESIZE="${1#*=}";       shift   ;;
        --resize-width)      RESIZE_WIDTH="$2";      shift 2 ;;
        --resize-width=*)    RESIZE_WIDTH="${1#*=}"; shift   ;;
        --resize-height)     RESIZE_HEIGHT="$2";     shift 2 ;;
        --resize-height=*)   RESIZE_HEIGHT="${1#*=}";shift   ;;

        --convertto)         CONVERTTO="$2";         shift 2 ;;
        --convertto=*)       CONVERTTO="${1#*=}";    shift   ;;
        --upscale)           UPSCALE="$2";           shift 2 ;;
        --upscale=*)         UPSCALE="${1#*=}";      shift   ;;

        --bg-remove)         BG_REMOVE=1;            shift   ;;

        --)                  shift; break ;;
        -*)
            log_error "Unknown option: $1"
            echo "Run with --help for usage." >&2
            exit 3 ;;
        *)
            if [[ -z "$INPUT_DIR" ]]; then INPUT_DIR="$1"
            else log_error "Unexpected argument: $1"; exit 3
            fi
            shift ;;
    esac
done

[[ -z "$INPUT_DIR" ]] && INPUT_DIR="$PWD"
INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"
BACKUP_DIR="$(mkdir -p "$BACKUP_DIR" 2>/dev/null; cd "$BACKUP_DIR" && pwd)" || true

# ==============================================================================
# SECTION 18: DEPENDENCY CHECK  (curl only)
# ==============================================================================

if ! command -v curl &>/dev/null; then
    log_error "curl is required but not found. Please install curl."
    exit 3
fi

# ==============================================================================
# SECTION 19: RESTORE / PURGE DISPATCH
# ==============================================================================

if [[ "$DO_RESTORE" == "true" ]]; then
    if [[ "$IS_INTERACTIVE" == "true" ]]; then
        printf "Restore all backups from '%s' to '%s'? This overwrites current files. [y/N] " \
            "$BACKUP_DIR" "$INPUT_DIR" >&2
        read -r _ans || true
        if [[ ! "${_ans:-}" =~ ^[Yy]$ ]]; then
            log_info "Restore cancelled."
            exit 0
        fi
    fi
    do_restore
    exit 0
fi

if [[ "$DO_PURGE" == "true" ]]; then
    do_purge_backups "$PURGE_DAYS"
    exit 0
fi

# ==============================================================================
# SECTION 20: VALIDATION
# ==============================================================================

[[ -z "$API_KEY" ]] && { log_error "API key is required. Use -k/--key or set API_KEY in .env"; exit 3; }
[[ -d "$INPUT_DIR" ]] || { log_error "Input directory does not exist: $INPUT_DIR"; exit 3; }
[[ -r "$INPUT_DIR" ]] || { log_error "Input directory is not readable: $INPUT_DIR"; exit 2; }

[[ "$LOSSY"       =~ ^[012]$          ]] || { log_error "--lossy must be 0, 1, or 2 (got: $LOSSY)";           exit 3; }
[[ "$RESIZE"      =~ ^(0|1|3|4)$      ]] || { log_error "--resize must be 0, 1, 3, or 4 (got: $RESIZE)";     exit 3; }
[[ "$CONCURRENCY" =~ ^[1-9][0-9]*$    ]] || { log_error "--concurrency must be a positive integer";           exit 3; }
[[ "$API_WAIT"    =~ ^[0-9]+$         ]] && (( API_WAIT >= 1 && API_WAIT <= 30 )) \
                                         || { log_error "--wait must be 1-30 (got: $API_WAIT)";               exit 3; }

[[ -n "$RESIZE_WIDTH"  ]] && { [[ "$RESIZE_WIDTH"  =~ ^[1-9][0-9]*$ ]] || { log_error "--resize-width must be a positive integer";  exit 3; }; }
[[ -n "$RESIZE_HEIGHT" ]] && { [[ "$RESIZE_HEIGHT" =~ ^[1-9][0-9]*$ ]] || { log_error "--resize-height must be a positive integer"; exit 3; }; }
[[ -n "$CONVERTTO"     ]] && { [[ "$CONVERTTO"     =~ ^\+(webp|avif|webp\+avif)$ ]] || { log_error "--convertto must be +webp, +avif, or +webp+avif"; exit 3; }; }
[[ -n "$UPSCALE"       ]] && { [[ "$UPSCALE"       =~ ^[234]$        ]] || { log_error "--upscale must be 2, 3, or 4";              exit 3; }; }

if [[ "$OVERWRITE" == "true" && -n "$OUTPUT_DIR" ]]; then
    log_error "--overwrite and --output-dir are mutually exclusive."
    exit 3
fi

if [[ "$OVERWRITE" != "true" && -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR" 2>/dev/null || { log_error "Cannot create output dir: $OUTPUT_DIR"; exit 2; }
    [[ -w "$OUTPUT_DIR" ]] || { log_error "Output dir is not writable: $OUTPUT_DIR"; exit 2; }
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || { log_error "Cannot create backup dir: $BACKUP_DIR"; exit 2; }
[[ -w "$BACKUP_DIR" ]]             || { log_error "Backup dir is not writable: $BACKUP_DIR"; exit 2; }

# ==============================================================================
# SECTION 21: MAIN — orchestrates discovery and parallel processing
# ==============================================================================

main() {
    _cleanup() {
        local _ec=$?
        show_dashboard
        [[ -n "${SEMAPHORE:-}"    && -p "$SEMAPHORE"    ]] && rm -f  "$SEMAPHORE"
        [[ -n "${PROGRESS_DIR:-}" && -d "$PROGRESS_DIR" ]] && rm -rf "$PROGRESS_DIR"
        echo >&2
        exit $_ec
    }
    trap '_cleanup' EXIT
    trap 'log_warn "Interrupted. Waiting for active workers..."; wait; exit 130' INT TERM

    PROGRESS_DIR=$(mktemp -d)
    touch "$PROGRESS_DIR/success" "$PROGRESS_DIR/error" "$PROGRESS_DIR/skipped" \
          "$PROGRESS_DIR/excluded" "$PROGRESS_DIR/orig_bytes" "$PROGRESS_DIR/opt_bytes" \
          "$PROGRESS_DIR/all_orig_bytes" "$PROGRESS_DIR/excl_sizes" "$PROGRESS_DIR/skip_sizes"

    DASHBOARD_ENABLED=true

    export API_ENDPOINT API_KEY LOSSY API_WAIT RESIZE RESIZE_WIDTH RESIZE_HEIGHT
    export CONVERTTO KEEP_EXIF CMYK2RGB BG_REMOVE UPSCALE
    export CONCURRENCY MAX_POLL_RETRIES POLL_SLEEP_SECONDS
    export INPUT_DIR OUTPUT_DIR OVERWRITE BACKUP_DIR FORCE EMAIL MAIL_CMD
    export TOTAL_FILES PROGRESS_DIR DASHBOARD_ENABLED
    export COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_CYAN COLOR_RESET COLOR_BOLD

    # ── File discovery ──────────────────────────────────────────────────────
    local -a find_prune=()
    [[ "$BACKUP_DIR" == "${INPUT_DIR}"/* || "$BACKUP_DIR" == "$INPUT_DIR" ]] \
        && find_prune+=(-path "$BACKUP_DIR" -prune -o)
    [[ -n "${OUTPUT_DIR:-}" ]] && \
        [[ "$OUTPUT_DIR" == "${INPUT_DIR}"/* || "$OUTPUT_DIR" == "$INPUT_DIR" ]] \
        && find_prune+=(-path "$OUTPUT_DIR" -prune -o)
    find_prune+=(-name "optimized" -type d -prune -o)

    local -a FILES=()
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(find "$INPUT_DIR" \
        "${find_prune[@]}" \
        -type f \( \
            -iname "*.jpg"  -o -iname "*.jpeg" -o \
            -iname "*.png"  -o -iname "*.gif"  -o \
            -iname "*.webp" \
        \) -print0 | sort -z)

    TOTAL_FILES=${#FILES[@]}
    export TOTAL_FILES

    if (( TOTAL_FILES == 0 )); then
        log_warn "No supported image files found in: $INPUT_DIR"
        log_warn "Supported: JPG, JPEG, PNG, GIF, WEBP"
        return 0
    fi

    # ── Run summary ─────────────────────────────────────────────────────────
    local comp_label
    case "$LOSSY" in 0) comp_label="lossless";; 1) comp_label="lossy";; 2) comp_label="glossy";; esac

    echo >&2
    log_info "ShortPixel Batch Optimizer v3.0 (zero-dependency)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Input folder    : $INPUT_DIR"
    if   [[ "$OVERWRITE" == "true" ]]; then log_info "Output mode     : Overwrite originals"
    elif [[ -n "$OUTPUT_DIR"       ]]; then log_info "Output folder   : $OUTPUT_DIR"
    else                                    log_info "Output mode     : <source_dir>/optimized/ (per folder)"
    fi
    log_info "Backup dir      : $BACKUP_DIR"
    log_info "Images found    : $TOTAL_FILES (recursive)"
    log_info "Compression     : $comp_label (mode=$LOSSY)"
    log_info "Workers         : $CONCURRENCY parallel"
    [[ -n "$EXCLUDE_EXT" ]] && log_info "Excluded exts   : $EXCLUDE_EXT (case-sensitive)"
    [[ -n "$EMAIL"        ]] && log_info "Report email    : $EMAIL"
    [[ "$FORCE" == "true" ]] && log_warn "Force mode      : ON (ignoring .splog entries)"
    [[ "$IS_INTERACTIVE" == "false" ]] && log_info "Mode            : non-interactive (CRON)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo >&2

    # ── FIFO semaphore ───────────────────────────────────────────────────────
    SEMAPHORE=$(mktemp -u)
    mkfifo "$SEMAPHORE"
    exec 3<>"$SEMAPHORE"
    local i; for i in $(seq 1 "$CONCURRENCY"); do echo >&3; done

    # ── Main processing loop ─────────────────────────────────────────────────
    local current_dir=""
    for input_file in "${FILES[@]}"; do
        local file_dir filename fsize
        file_dir="$(dirname  "$input_file")"
        filename="$(basename "$input_file")"

        if [[ "$file_dir" != "$current_dir" ]]; then
            current_dir="$file_dir"
            if [[ -z "${DIR_CHECKED[$file_dir]+x}" ]]; then
                if [[ -w "$file_dir" ]]; then
                    DIR_CHECKED[$file_dir]=1
                    splog_prune "$file_dir"
                else
                    DIR_CHECKED[$file_dir]=0
                    SKIPPED_FOLDERS+=("$file_dir")
                    log_warn "Skipping read-only folder: $file_dir"
                fi
            fi
        fi

        if [[ "${DIR_CHECKED[$file_dir]}" == "0" ]]; then
            fsize=$(get_file_size "$input_file")
            printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/skip_sizes"
            increment_counter "$PROGRESS_DIR/skipped"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            continue
        fi

        if is_excluded "$input_file"; then
            log_info "Excluded: $filename"
            fsize=$(get_file_size "$input_file")
            printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/excl_sizes"
            increment_counter "$PROGRESS_DIR/excluded"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            continue
        fi

        if [[ "$FORCE" != "true" ]] && splog_has_entry "$file_dir" "$filename"; then
            log_info "Already optimized (skip): $filename"
            fsize=$(get_file_size "$input_file")
            printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/skip_sizes"
            increment_counter "$PROGRESS_DIR/skipped"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            continue
        fi

        fsize=$(get_file_size "$input_file")
        printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/all_orig_bytes"

        read -u 3
        process_file "$input_file" &
    done

    wait
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
main
