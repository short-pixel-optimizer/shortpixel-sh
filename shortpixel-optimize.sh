#!/usr/bin/env bash
# ==============================================================================
# shortpixel-optimize.sh v2.0
#
# Batch-optimize images using the ShortPixel API with decentralized state
# tracking (.splog), mirrored backups, and structured restore/purge workflows.
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
#       --purge-backups [N] Delete backup files older than N days that have a
#                          .splog entry. Default: 30 days. Files with no .splog
#                          entry are kept regardless of age.
#
# PROCESSING OPTIONS:
#   -j, --concurrency N    Parallel workers (default: 4)
#   -w, --wait N           API wait seconds, 1-30 (default: 25)
#       --force            Ignore existing .splog entries; re-optimize and
#                          overwrite backup
#
# COMPRESSION OPTIONS:
#   -l, --lossy N          0=lossless, 1=lossy (default), 2=glossy
#       --keep-exif        Preserve EXIF metadata
#       --no-cmyk2rgb      Disable CMYK→RGB conversion
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
#   1   API / Network error (fatal: unreachable endpoint or auth failure)
#   2   Permissions error (cannot write output or backup dir)
#   3   Configuration error (missing key, bad arguments, missing dependency)
#
# .env FILE (loaded from the script's directory):
#   API_KEY      Your ShortPixel API key
#   BACKUP_DIR   Path to backup mirror directory (default: <script_dir>/backups)
#   EXCLUDE_EXT  Comma-separated, case-sensitive extensions to skip
#                Example: EXCLUDE_EXT=JPG,PNG   → skips file.JPG, file.PNG
#                         but NOT file.jpg or file.png
#
# EXAMPLES:
#   # Optimize current directory, save to ./optimized/
#   ./shortpixel-optimize.sh -k MY_KEY
#
#   # Overwrite originals, 8 workers, glossy compression
#   ./shortpixel-optimize.sh -k MY_KEY --overwrite -j 8 -l 2 ./images
#
#   # Restore all files from backup (undo optimizations)
#   ./shortpixel-optimize.sh --restore ./images
#
#   # Purge backups older than 14 days that have .splog entries
#   ./shortpixel-optimize.sh --purge-backups 14 ./images
#
#   # Re-optimize everything, ignoring .splog
#   ./shortpixel-optimize.sh -k MY_KEY --force --overwrite ./images
#
# DEPENDENCIES: curl, jq (auto-installed via apt if missing)
# ==============================================================================

set -euo pipefail

# Resolve the script's own directory (for .env and restore_audit.log)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# SECTION 1: LOAD .env AND SET CONFIGURATION DEFAULTS
# ==============================================================================

# Load .env from the script directory (set -a exports all variables)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
fi

readonly API_ENDPOINT="https://api.shortpixel.com/v2/post-reducer.php"

API_KEY="${API_KEY:-}"
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

BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
EXCLUDE_EXT="${EXCLUDE_EXT:-}"

# Runtime state (populated later)
PROGRESS_DIR=""
SEMAPHORE=""
TOTAL_FILES=0
WORKER_TMP_FILE=""
DASHBOARD_ENABLED=false

# Global analytics arrays — must be at global scope so show_dashboard() can read them
declare -a SKIPPED_FOLDERS=()
declare -A DIR_CHECKED=()

# Non-interactive detection (for CRON: bypass confirmation prompts)
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
# SECTION 3: LOGGING
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

# Returns the extension with its original case (for case-sensitive exclusion checks)
get_file_extension() {
    local f="${1##*/}"
    echo "${f##*.}"
}

# Returns the lowercase extension (for image type detection)
get_file_extension_lower() {
    local ext
    ext=$(get_file_extension "$1")
    echo "${ext,,}"
}

get_md5() {
    local file="$1"
    if command -v md5sum &>/dev/null; then
        md5sum "$file" | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        md5 -q "$file"
    else
        echo "00000000000000000000000000000000"
    fi
}

# Convert bytes to human-readable string (B / KB / MB / GB)
# LC_NUMERIC=C ensures "." as decimal separator regardless of system locale
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

# Sum a file of zero-padded 20-digit integers, one per line
sum_size_file() {
    local f="$1"
    [[ -f "$f" ]] || { echo 0; return; }
    awk '{s += $1} END {printf "%d", s+0}' "$f"
}

# ==============================================================================
# SECTION 6: EXCLUSION CHECK (case-sensitive extension match)
# ==============================================================================

is_excluded() {
    [[ -z "$EXCLUDE_EXT" ]] && return 1
    local actual_ext
    actual_ext=$(get_file_extension "$1")
    local e
    IFS=',' read -ra _excl_arr <<< "$EXCLUDE_EXT"
    for e in "${_excl_arr[@]}"; do
        e="${e// /}"   # trim spaces
        [[ "$actual_ext" == "$e" ]] && return 0
    done
    return 1
}

# ==============================================================================
# SECTION 7: .splog MANAGEMENT
#
# One .splog file per directory, alongside the images it tracks.
# Format per line (pipe-delimited):
#   md5|filename|orig_size|opt_size|savings_pct|comp_type|epoch_timestamp
# ==============================================================================

# Remove .splog entries for files that no longer exist in the directory
splog_prune() {
    local dir="$1"
    local splog="${dir}/.splog"
    [[ -f "$splog" ]] || return 0

    local tmp
    tmp=$(mktemp)
    while IFS='|' read -r md5 filename orig opt savings comp ts; do
        [[ -z "$filename" ]] && continue
        if [[ -f "${dir}/${filename}" ]]; then
            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$md5" "$filename" "$orig" "$opt" "$savings" "$comp" "$ts"
        fi
    done < "$splog" > "$tmp"
    mv "$tmp" "$splog"
}

# Returns 0 if filename has an entry in the directory's .splog
splog_has_entry() {
    local dir="$1" filename="$2"
    local splog="${dir}/.splog"
    [[ -f "$splog" ]] || return 1
    awk -F'|' -v f="$filename" '$2==f {found=1; exit} END {exit !found}' "$splog"
}

# Write (or update) an entry in the directory's .splog; concurrent-safe via flock
splog_write_entry() {
    local dir="$1" md5="$2" filename="$3"
    local orig_size="$4" opt_size="$5" savings="$6" comp_type="$7"
    local timestamp
    timestamp=$(date +%s)
    local splog="${dir}/.splog"
    # Derive a per-directory lock path under PROGRESS_DIR
    local lock_key
    lock_key=$(printf '%s' "$dir" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$dir" | cksum | cut -d' ' -f1)
    local lock_file="${PROGRESS_DIR}/splog_${lock_key}.lock"

    (
        flock -x 9
        local tmp
        tmp=$(mktemp)
        if [[ -f "$splog" ]]; then
            awk -F'|' -v f="$filename" '$2!=f {print}' "$splog" > "$tmp" 2>/dev/null || true
        fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$md5" "$filename" "$orig_size" "$opt_size" "$savings" "$comp_type" "$timestamp" \
            >> "$tmp"
        mv "$tmp" "$splog"
    ) 9>"$lock_file"
}

# ==============================================================================
# SECTION 8: BACKUP MANAGEMENT
# ==============================================================================

# Derive the backup mirror path for a given source file
get_backup_path() {
    local source_file="$1"
    local rel_path="${source_file#${INPUT_DIR}/}"
    echo "${BACKUP_DIR}/${rel_path}"
}

# Copy a source file to its backup mirror location
backup_file() {
    local source_file="$1"
    local backup_path
    backup_path=$(get_backup_path "$source_file")
    mkdir -p "$(dirname "$backup_path")"
    if ! cp "$source_file" "$backup_path"; then
        log_error "Backup failed: $source_file → $backup_path"
        return 1
    fi
    return 0
}

# Verify a backup file exists and is non-empty
verify_backup() {
    local backup_path="$1"
    if [[ ! -f "$backup_path" ]]; then
        log_error "Backup missing: $backup_path"
        return 1
    fi
    local sz
    sz=$(get_file_size "$backup_path")
    if (( sz == 0 )); then
        log_error "Backup is empty (0 bytes): $backup_path"
        return 1
    fi
    return 0
}

# ==============================================================================
# SECTION 9: PROGRESS TRACKING
# ==============================================================================

# Atomically increment a file-based counter (POSIX O_APPEND guarantee)
increment_counter() {
    printf '\n' >> "$1"
}

show_progress() {
    local total="$1" progress_dir="$2"
    local s=0 e=0 sk=0 ex=0
    [[ -f "$progress_dir/success"  ]] && s=$(wc -l < "$progress_dir/success")
    [[ -f "$progress_dir/error"    ]] && e=$(wc -l < "$progress_dir/error")
    [[ -f "$progress_dir/skipped"  ]] && sk=$(wc -l < "$progress_dir/skipped")
    [[ -f "$progress_dir/excluded" ]] && ex=$(wc -l < "$progress_dir/excluded")
    local done=$(( s + e ))
    local rem=$(( total - done - sk - ex ))
    (( rem < 0 )) && rem=0
    printf '\r%s[%d/%d]%s  OK:%s%d%s  Err:%s%d%s  Skip:%d  Excl:%d  Rem:%d   ' \
        "$COLOR_BOLD" "$done" "$total" "$COLOR_RESET" \
        "$COLOR_GREEN" "$s" "$COLOR_RESET" \
        "$COLOR_RED"   "$e" "$COLOR_RESET" \
        "$sk" "$ex" "$rem" >&2
}

# ==============================================================================
# SECTION 10: API INTERACTION
# ==============================================================================

download_file() {
    local url="$1" dest_path="$2"
    mkdir -p "$(dirname "$dest_path")"
    curl --fail --silent --show-error --location --output "$dest_path" "$url"
}

parse_api_response() {
    local json="$1" query="$2"
    echo "$json" \
        | jq -r "if type == \"array\" then . else [.] end | ${query}" 2>/dev/null \
        || echo "parse_error"
}

optimize_single_file() {
    local input_file="$1"
    local filename file_dir
    filename="$(basename "$input_file")"
    file_dir="$(dirname "$input_file")"

    # Determine output path.
    # Default (no --output-dir): place optimized file in an "optimized/" subfolder
    # inside the same directory as the source file, e.g.:
    #   source:    /images/subdir/photo.jpg
    #   optimized: /images/subdir/optimized/photo.jpg
    # With --output-dir: place all files flat inside OUTPUT_DIR (no mirroring).
    local output_file
    if [[ "$OVERWRITE" == "true" ]]; then
        output_file="$input_file"
    elif [[ -n "$OUTPUT_DIR" ]]; then
        output_file="${OUTPUT_DIR}/${filename}"
    else
        output_file="${file_dir}/optimized/${filename}"
    fi

    local comp_type
    case "$LOSSY" in
        0) comp_type="lossless" ;;
        1) comp_type="lossy"    ;;
        2) comp_type="glossy"   ;;
        *) comp_type="unknown"  ;;
    esac

    local original_size
    original_size=$(get_file_size "$input_file")

    # ------------------------------------------------------------------
    # INTEGRITY: back up the original BEFORE any API call.
    # If backup fails or is empty, abort this file (leave original intact).
    # ------------------------------------------------------------------
    local backup_path
    backup_path=$(get_backup_path "$input_file")

    if ! backup_file "$input_file"; then
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    if ! verify_backup "$backup_path"; then
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # Compute MD5 of the original (from the backup, since overwrite replaces input_file)
    local md5
    md5=$(get_md5 "$backup_path")

    # ------------------------------------------------------------------
    # Create a temp file with a safe (space-free) path for curl upload
    # ------------------------------------------------------------------
    local extension
    extension=$(get_file_extension_lower "$filename")
    WORKER_TMP_FILE=$(mktemp --suffix=".${extension}")

    if ! cp "$input_file" "$WORKER_TMP_FILE"; then
        log_error "Cannot create temp upload file for: $filename"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # ------------------------------------------------------------------
    # Build the API request
    # ------------------------------------------------------------------
    # max-time: at least 60s to cover upload + API_WAIT + download latency
    local curl_max_time=$(( API_WAIT + 60 ))
    (( curl_max_time < 60 )) && curl_max_time=60
    local -a curl_args=(
        --silent --show-error
        --max-time "$curl_max_time"
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

    local api_response curl_exit
    api_response=$(curl "${curl_args[@]}" "$API_ENDPOINT" 2>&1)
    curl_exit=$?
    if (( curl_exit != 0 )); then
        if (( curl_exit == 28 )); then
            log_error "Upload timed out (no response from API) for: $filename"
            log_error "  Hint: key may be domain-restricted or account has no credits."
            log_error "  Check your API key settings at shortpixel.com"
        else
            log_error "Upload failed (curl exit $curl_exit) for: $filename — $api_response"
        fi
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # ------------------------------------------------------------------
    # Parse initial response
    # ------------------------------------------------------------------
    local status_code status_message original_url
    status_code=$(parse_api_response "$api_response" '.[0].Status.Code // "parse_error"')
    status_message=$(parse_api_response "$api_response" '.[0].Status.Message // "unknown"')
    original_url=$(parse_api_response "$api_response" '.[0].OriginalURL // ""')

    if [[ "$status_code" == "parse_error" ]]; then
        log_error "Could not parse API response for: $filename"
        log_error "Raw: ${api_response:0:300}"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # ------------------------------------------------------------------
    # Polling loop (status "1" = still processing)
    # ------------------------------------------------------------------
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
        poll_count=$(( poll_count + 1 ))

        if ! api_response=$(curl --silent --show-error \
                --max-time "$curl_max_time" \
                -F "key=${API_KEY}" \
                -F "wait=${API_WAIT}" \
                -F "file_urls[]=${original_url}" \
                "$API_ENDPOINT" 2>&1); then
            log_error "Poll request failed: $filename"
            increment_counter "$PROGRESS_DIR/error"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            return 1
        fi

        status_code=$(parse_api_response "$api_response" '.[0].Status.Code // "parse_error"')
        status_message=$(parse_api_response "$api_response" '.[0].Status.Message // "unknown"')
    done

    # ------------------------------------------------------------------
    # Handle API errors (any non-"2" status)
    # ------------------------------------------------------------------
    if [[ "$status_code" != "2" ]]; then
        log_error "API error '$filename': [Code $status_code] $status_message"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # ------------------------------------------------------------------
    # Extract download URL
    # ------------------------------------------------------------------
    local download_url optimized_size
    if [[ "$LOSSY" == "0" ]]; then
        download_url=$(parse_api_response "$api_response" '.[0].LosslessURL // ""')
        optimized_size=$(parse_api_response "$api_response" '.[0].LoselessSize // "0"')
    else
        download_url=$(parse_api_response "$api_response" '.[0].LossyURL // ""')
        optimized_size=$(parse_api_response "$api_response" '.[0].LossySize // "0"')
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        log_error "No download URL for: $filename"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # ------------------------------------------------------------------
    # Download to a temp file, then atomically move to destination
    # ------------------------------------------------------------------
    local tmp_dl
    tmp_dl=$(mktemp --suffix=".${extension}")

    if ! download_file "$download_url" "$tmp_dl"; then
        rm -f "$tmp_dl"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    mkdir -p "$(dirname "$output_file")"
    mv "$tmp_dl" "$output_file"

    # ------------------------------------------------------------------
    # Calculate savings percentage (integer math, 2 decimal places)
    # ------------------------------------------------------------------
    local savings_pct="0.00"
    if (( original_size > 0 && optimized_size > 0 )); then
        local si=$(( (original_size - optimized_size) * 10000 / original_size ))
        savings_pct=$(printf '%d.%02d' $(( si / 100 )) $(( si % 100 )))
    fi

    # ------------------------------------------------------------------
    # Write .splog entry and update counters
    # ------------------------------------------------------------------
    splog_write_entry "$file_dir" "$md5" "$filename" \
        "$original_size" "$optimized_size" "$savings_pct" "$comp_type"

    # Record sizes for the analytics dashboard
    printf '%020d\n' "$original_size"  >> "$PROGRESS_DIR/orig_bytes"
    printf '%020d\n' "$optimized_size" >> "$PROGRESS_DIR/opt_bytes"

    increment_counter "$PROGRESS_DIR/success"
    show_progress "$TOTAL_FILES" "$PROGRESS_DIR"

    log_success "$filename: $(format_bytes "$original_size") → $(format_bytes "$optimized_size") (${savings_pct}% saved)"
    return 0
}

# Thin wrapper: guarantees semaphore token is returned and temp files cleaned up
process_file() {
    local input_file="$1"
    trap '[[ -n "${WORKER_TMP_FILE:-}" ]] && rm -f "$WORKER_TMP_FILE"; echo >&3' EXIT
    optimize_single_file "$input_file" || true
}

# ==============================================================================
# SECTION 11: ANALYTICS DASHBOARD
# ==============================================================================

show_dashboard() {
    [[ "$DASHBOARD_ENABLED" == "true" ]] || return 0

    local s=0 e=0 sk=0 ex=0
    [[ -f "$PROGRESS_DIR/success"  ]] && s=$(wc -l  < "$PROGRESS_DIR/success"  | tr -d ' ')
    [[ -f "$PROGRESS_DIR/error"    ]] && e=$(wc -l  < "$PROGRESS_DIR/error"    | tr -d ' ')
    [[ -f "$PROGRESS_DIR/skipped"  ]] && sk=$(wc -l < "$PROGRESS_DIR/skipped"  | tr -d ' ')
    [[ -f "$PROGRESS_DIR/excluded" ]] && ex=$(wc -l < "$PROGRESS_DIR/excluded" | tr -d ' ')

    # Byte sums — all kept as integers
    local sum_orig_success sum_opt_success sum_all_dispatched sum_excl sum_skip
    sum_orig_success=$(sum_size_file "$PROGRESS_DIR/orig_bytes")
    sum_opt_success=$(sum_size_file  "$PROGRESS_DIR/opt_bytes")
    sum_all_dispatched=$(sum_size_file "$PROGRESS_DIR/all_orig_bytes")
    sum_excl=$(sum_size_file "$PROGRESS_DIR/excl_sizes")
    sum_skip=$(sum_size_file "$PROGRESS_DIR/skip_sizes")

    # total_orig_all  = all source files (dispatched + excluded + skipped)
    local total_orig_all=$(( sum_all_dispatched + sum_excl + sum_skip ))

    # current_source = optimized sizes for successes + original sizes for everything else
    # savings        = what the successes actually saved
    local current_source=$(( sum_opt_success + total_orig_all - sum_orig_success ))
    local savings=$(( sum_orig_success - sum_opt_success ))
    (( savings < 0 )) && savings=0

    local savings_pct="0.00"
    if (( total_orig_all > 0 )); then
        local sp_int=$(( savings * 10000 / total_orig_all ))
        savings_pct=$(printf '%d.%02d' $(( sp_int / 100 )) $(( sp_int % 100 )))
    fi

    # Backup folder size (excluding .splog files)
    local backup_size=0
    if [[ -d "$BACKUP_DIR" ]]; then
        while IFS= read -r -d '' f; do
            local fsz
            fsz=$(get_file_size "$f")
            (( backup_size += fsz )) || true
        done < <(find "$BACKUP_DIR" -type f ! -name ".splog" -print0 2>/dev/null)
    fi
    local total_footprint=$(( current_source + backup_size ))

    local W=54  # inner width of dashboard box
    local sep
    sep=$(printf '═%.0s' $(seq 1 $W))

    _drow() {
        # Print a line inside the box, padded to inner width W
        printf "${COLOR_BOLD}${COLOR_CYAN}║${COLOR_RESET} %-${W}s ${COLOR_BOLD}${COLOR_CYAN}║${COLOR_RESET}\n" "$1" >&2
    }
    _dhdr() {
        printf "${COLOR_BOLD}${COLOR_CYAN}╠%s╣${COLOR_RESET}\n" "$sep" >&2
    }

    echo >&2
    printf "${COLOR_BOLD}${COLOR_CYAN}╔%s╗${COLOR_RESET}\n" "$sep" >&2
    # Header: plain text centred (no ANSI codes inside _drow's padding calc)
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
            # Truncate long paths to fit
            (( ${#short} > W - 4 )) && short="...${folder: -(($W - 7))}"
            _drow "  ${COLOR_YELLOW}${short}${COLOR_RESET}"
        done
    fi

    _dhdr
    _drow "  ${COLOR_BOLD}SOURCE SAVINGS${COLOR_RESET}"
    _drow "$(printf '    %-22s %s' 'Original total:'  "$(format_bytes "$total_orig_all")"  )"
    _drow "$(printf '    %-22s %s' 'Current total:'   "$(format_bytes "$current_source")"  )"
    _drow "$(printf '    %-22s %s%s (%s%%)%s' 'Saved:' \
        "$COLOR_GREEN" "$(format_bytes "$savings")" "$savings_pct" "$COLOR_RESET")"

    _dhdr
    _drow "  ${COLOR_BOLD}TOTAL SYSTEM FOOTPRINT${COLOR_RESET}"
    _drow "$(printf '    %-22s %s' 'Current source:'  "$(format_bytes "$current_source")"  )"
    _drow "$(printf '    %-22s %s' 'Backup folder:'   "$(format_bytes "$backup_size")"     )"
    _drow "$(printf '    %-22s %s' 'Total:'           "$(format_bytes "$total_footprint")" )"

    printf "${COLOR_BOLD}${COLOR_CYAN}╚%s╝${COLOR_RESET}\n" "$sep" >&2
    echo >&2
}

# ==============================================================================
# SECTION 12: RESTORE
# ==============================================================================

do_restore() {
    log_info "Restoring from backup: $BACKUP_DIR → $INPUT_DIR"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 2
    fi

    local audit_log="${SCRIPT_DIR}/restore_audit.log"
    : > "$audit_log"   # Overwrite (create empty)

    local restored=0 failed=0

    while IFS= read -r -d '' backup_file; do
        local rel_path="${backup_file#${BACKUP_DIR}/}"
        local source_file="${INPUT_DIR}/${rel_path}"

        mkdir -p "$(dirname "$source_file")"

        if cp "$backup_file" "$source_file"; then
            echo "$source_file" >> "$audit_log"
            log_success "Restored: $rel_path"
            restored=$(( restored + 1 ))
        else
            log_error "Failed to restore: $rel_path"
            echo "FAILED: $source_file" >> "$audit_log"
            failed=$(( failed + 1 ))
        fi
    done < <(find "$BACKUP_DIR" -type f ! -name ".splog" -print0 2>/dev/null)

    # Delete all .splog files after successful restore
    log_info "Removing .splog files from source tree..."
    find "$INPUT_DIR" -name ".splog" -delete 2>/dev/null || true

    log_success "Restore complete: ${restored} restored, ${failed} failed"
    log_info "Audit log: $audit_log"
}

# ==============================================================================
# SECTION 13: PURGE BACKUPS
# ==============================================================================

do_purge_backups() {
    local days="$1"
    log_info "Purging backup files older than ${days} days (only if in .splog)..."

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "Backup directory not found: $BACKUP_DIR"
        return 0
    fi

    local purged=0 kept=0

    while IFS= read -r -d '' backup_file; do
        local rel_path="${backup_file#${BACKUP_DIR}/}"
        local filename
        filename=$(basename "$rel_path")
        local rel_dir
        rel_dir=$(dirname "$rel_path")

        local source_dir
        if [[ "$rel_dir" == "." ]]; then
            source_dir="$INPUT_DIR"
        else
            source_dir="${INPUT_DIR}/${rel_dir}"
        fi

        if splog_has_entry "$source_dir" "$filename"; then
            log_info "Purging: $rel_path"
            rm -f "$backup_file"
            purged=$(( purged + 1 ))
        else
            log_info "Keeping (no .splog entry): $rel_path"
            kept=$(( kept + 1 ))
        fi
    done < <(find "$BACKUP_DIR" -type f ! -name ".splog" -mtime +"${days}" -print0 2>/dev/null)

    # Remove empty backup directories
    find "$BACKUP_DIR" -type d -empty -delete 2>/dev/null || true

    log_success "Purge complete: ${purged} deleted, ${kept} kept"
}

# ==============================================================================
# SECTION 14: ARGUMENT PARSING
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help; exit 0 ;;

        -k|--key)       API_KEY="$2";       shift 2 ;;
        --key=*)        API_KEY="${1#*=}";   shift   ;;

        -o|--output-dir) OUTPUT_DIR="$2";   shift 2 ;;
        --output-dir=*)  OUTPUT_DIR="${1#*=}"; shift ;;

        --overwrite)    OVERWRITE=true;      shift   ;;
        --force)        FORCE=true;          shift   ;;

        --restore)      DO_RESTORE=true;     shift   ;;

        --purge-backups)
            DO_PURGE=true
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                PURGE_DAYS="$2"; shift 2
            else
                shift
            fi ;;
        --purge-backups=*)
            DO_PURGE=true; PURGE_DAYS="${1#*=}"; shift ;;

        --backup-dir)   BACKUP_DIR="$2";     shift 2 ;;
        --backup-dir=*) BACKUP_DIR="${1#*=}"; shift  ;;

        -j|--concurrency)   CONCURRENCY="$2";       shift 2 ;;
        --concurrency=*)    CONCURRENCY="${1#*=}";   shift   ;;
        -w|--wait)          API_WAIT="$2";           shift 2 ;;
        --wait=*)           API_WAIT="${1#*=}";      shift   ;;

        -l|--lossy)     LOSSY="$2";          shift 2 ;;
        --lossy=*)      LOSSY="${1#*=}";     shift   ;;
        --keep-exif)    KEEP_EXIF=1;         shift   ;;
        --no-cmyk2rgb)  CMYK2RGB=0;          shift   ;;

        --resize)       RESIZE="$2";         shift 2 ;;
        --resize=*)     RESIZE="${1#*=}";    shift   ;;
        --resize-width) RESIZE_WIDTH="$2";   shift 2 ;;
        --resize-width=*) RESIZE_WIDTH="${1#*=}"; shift ;;
        --resize-height) RESIZE_HEIGHT="$2"; shift 2 ;;
        --resize-height=*) RESIZE_HEIGHT="${1#*=}"; shift ;;

        --convertto)    CONVERTTO="$2";      shift 2 ;;
        --convertto=*)  CONVERTTO="${1#*=}"; shift   ;;
        --upscale)      UPSCALE="$2";        shift 2 ;;
        --upscale=*)    UPSCALE="${1#*=}";   shift   ;;

        --bg-remove)    BG_REMOVE=1;         shift   ;;

        --)             shift; break ;;
        -*)
            log_error "Unknown option: $1"
            echo "Run with --help for usage." >&2
            exit 3 ;;
        *)
            if [[ -z "$INPUT_DIR" ]]; then
                INPUT_DIR="$1"
            else
                log_error "Unexpected argument: $1"
                exit 3
            fi
            shift ;;
    esac
done

# Default input directory: current working directory
if [[ -z "$INPUT_DIR" ]]; then
    INPUT_DIR="$PWD"
fi
INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"   # Resolve to absolute path
BACKUP_DIR="$(mkdir -p "$BACKUP_DIR" 2>/dev/null; cd "$BACKUP_DIR" && pwd)" || true

# ==============================================================================
# SECTION 15: DEPENDENCY CHECKS
# ==============================================================================

if ! command -v curl &>/dev/null; then
    log_error "curl is required but not installed."
    exit 3
fi

if ! command -v jq &>/dev/null; then
    log_warn "jq not found. Attempting auto-install via apt..."
    if command -v apt-get &>/dev/null && sudo apt-get install -y jq &>/dev/null; then
        log_success "jq installed successfully."
    else
        log_error "Could not install jq. Please install it manually."
        log_error "  Ubuntu/Debian: sudo apt install jq"
        log_error "  macOS:         brew install jq"
        exit 3
    fi
fi

# ==============================================================================
# SECTION 16: RESTORE / PURGE MODES (bypass normal optimization flow)
# ==============================================================================

if [[ "$DO_RESTORE" == "true" ]]; then
    if [[ "$IS_INTERACTIVE" == "true" ]]; then
        printf '%s' "Restore all backups from '$BACKUP_DIR' to '$INPUT_DIR'? This overwrites current files. [y/N] " >&2
        read -r _ans
        if [[ ! "$_ans" =~ ^[Yy]$ ]]; then
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
# SECTION 17: VALIDATION (optimization mode)
# ==============================================================================

if [[ -z "$API_KEY" ]]; then
    log_error "API key is required. Use --key or set API_KEY in .env"
    exit 3
fi

if [[ ! -d "$INPUT_DIR" ]]; then
    log_error "Input directory does not exist: $INPUT_DIR"
    exit 3
fi

if [[ ! -r "$INPUT_DIR" ]]; then
    log_error "Input directory is not readable: $INPUT_DIR"
    exit 2
fi

if ! [[ "$LOSSY" =~ ^[012]$ ]]; then
    log_error "--lossy must be 0, 1, or 2. Got: $LOSSY"
    exit 3
fi

if ! [[ "$API_WAIT" =~ ^[0-9]+$ ]] || (( API_WAIT < 1 || API_WAIT > 30 )); then
    log_error "--wait must be 1-30. Got: $API_WAIT"
    exit 3
fi

if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 )); then
    log_error "--concurrency must be a positive integer. Got: $CONCURRENCY"
    exit 3
fi

if ! [[ "$RESIZE" =~ ^(0|1|3|4)$ ]]; then
    log_error "--resize must be 0, 1, 3, or 4. Got: $RESIZE"
    exit 3
fi

if [[ -n "$RESIZE_WIDTH"  ]] && ! [[ "$RESIZE_WIDTH"  =~ ^[0-9]+$ && "$RESIZE_WIDTH"  -gt 0 ]]; then
    log_error "--resize-width must be a positive integer."
    exit 3
fi

if [[ -n "$RESIZE_HEIGHT" ]] && ! [[ "$RESIZE_HEIGHT" =~ ^[0-9]+$ && "$RESIZE_HEIGHT" -gt 0 ]]; then
    log_error "--resize-height must be a positive integer."
    exit 3
fi

if [[ -n "$CONVERTTO" ]] && ! [[ "$CONVERTTO" =~ ^\+(webp|avif|webp\+avif)$ ]]; then
    log_error "--convertto must be +webp, +avif, or +webp+avif. Got: $CONVERTTO"
    exit 3
fi

if [[ -n "$UPSCALE" ]] && ! [[ "$UPSCALE" =~ ^[234]$ ]]; then
    log_error "--upscale must be 2, 3, or 4. Got: $UPSCALE"
    exit 3
fi

if [[ "$OVERWRITE" == "true" && -n "$OUTPUT_DIR" ]]; then
    log_error "--overwrite and --output-dir cannot be used together."
    exit 3
fi

# Resolve output directory (only needed when --output-dir is explicitly set)
if [[ "$OVERWRITE" != "true" && -n "$OUTPUT_DIR" ]]; then
    if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
        log_error "Cannot create output directory: $OUTPUT_DIR"
        exit 2
    fi
    if [[ ! -w "$OUTPUT_DIR" ]]; then
        log_error "Output directory is not writable: $OUTPUT_DIR"
        exit 2
    fi
fi

if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    log_error "Cannot create backup directory: $BACKUP_DIR"
    exit 2
fi

if [[ ! -w "$BACKUP_DIR" ]]; then
    log_error "Backup directory is not writable: $BACKUP_DIR"
    exit 2
fi

# ==============================================================================
# SECTION 18: MAIN — orchestrates discovery and parallel processing
# ==============================================================================

main() {
    # --------------------------------------------------------------------------
    # Global exit handler: always show dashboard, always clean up temp files
    # --------------------------------------------------------------------------
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

    # --------------------------------------------------------------------------
    # Initialise temp directory for counters and lock files
    # --------------------------------------------------------------------------
    PROGRESS_DIR=$(mktemp -d)
    touch "$PROGRESS_DIR/success" \
          "$PROGRESS_DIR/error" \
          "$PROGRESS_DIR/skipped" \
          "$PROGRESS_DIR/excluded" \
          "$PROGRESS_DIR/orig_bytes" \
          "$PROGRESS_DIR/opt_bytes" \
          "$PROGRESS_DIR/all_orig_bytes" \
          "$PROGRESS_DIR/excl_sizes" \
          "$PROGRESS_DIR/skip_sizes"

    DASHBOARD_ENABLED=true

    # Export everything workers (background subshells) need
    export API_ENDPOINT API_KEY LOSSY API_WAIT RESIZE RESIZE_WIDTH RESIZE_HEIGHT
    export CONVERTTO KEEP_EXIF CMYK2RGB BG_REMOVE UPSCALE
    export CONCURRENCY MAX_POLL_RETRIES POLL_SLEEP_SECONDS
    export INPUT_DIR OUTPUT_DIR OVERWRITE BACKUP_DIR FORCE
    export TOTAL_FILES PROGRESS_DIR DASHBOARD_ENABLED
    export COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_CYAN COLOR_RESET COLOR_BOLD

    # --------------------------------------------------------------------------
    # File discovery (recursive).
    # Exclude: backup dir (if nested under INPUT_DIR), explicit OUTPUT_DIR (if set),
    # and any "optimized/" subdirectories (the per-folder default output location).
    # --------------------------------------------------------------------------
    local -a find_prune=()
    if [[ "$BACKUP_DIR" == "${INPUT_DIR}"/* || "$BACKUP_DIR" == "$INPUT_DIR" ]]; then
        find_prune+=(-path "$BACKUP_DIR" -prune -o)
    fi
    if [[ -n "${OUTPUT_DIR:-}" && ( "$OUTPUT_DIR" == "${INPUT_DIR}"/* || "$OUTPUT_DIR" == "$INPUT_DIR" ) ]]; then
        find_prune+=(-path "$OUTPUT_DIR" -prune -o)
    fi
    # Always exclude "optimized/" subdirs (per-folder default output)
    find_prune+=(-name "optimized" -type d -prune -o)

    local -a FILES=()
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(find "$INPUT_DIR" \
        "${find_prune[@]}" \
        -type f \( \
            -iname "*.jpg"  -o \
            -iname "*.jpeg" -o \
            -iname "*.png"  -o \
            -iname "*.gif"  -o \
            -iname "*.webp" \
        \) -print0 | sort -z)

    TOTAL_FILES=${#FILES[@]}
    export TOTAL_FILES

    if (( TOTAL_FILES == 0 )); then
        log_warn "No supported image files found in: $INPUT_DIR"
        log_warn "Supported: JPG, JPEG, PNG, GIF, WEBP"
        return 0
    fi

    # --------------------------------------------------------------------------
    # Print run summary
    # --------------------------------------------------------------------------
    local comp_label
    case "$LOSSY" in
        0) comp_label="lossless" ;;
        1) comp_label="lossy"    ;;
        2) comp_label="glossy"   ;;
    esac

    echo >&2
    log_info "ShortPixel Batch Optimizer v2.0"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Input folder    : $INPUT_DIR"
    if [[ "$OVERWRITE" == "true" ]]; then
        log_info "Output mode     : Overwrite originals"
    elif [[ -n "$OUTPUT_DIR" ]]; then
        log_info "Output folder   : $OUTPUT_DIR"
    else
        log_info "Output mode     : <source_dir>/optimized/ (per folder)"
    fi
    log_info "Backup dir      : $BACKUP_DIR"
    log_info "Images found    : $TOTAL_FILES (recursive)"
    log_info "Compression     : $comp_label (mode=$LOSSY)"
    log_info "Workers         : $CONCURRENCY parallel"
    [[ -n "$EXCLUDE_EXT"    ]] && log_info "Excluded exts   : $EXCLUDE_EXT (case-sensitive)"
    [[ "$FORCE" == "true"   ]] && log_warn "Force mode      : ON (ignoring .splog entries)"
    [[ "$IS_INTERACTIVE" == "false" ]] && log_info "Mode            : non-interactive (CRON)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo >&2

    # --------------------------------------------------------------------------
    # FIFO semaphore — N tokens for N concurrent workers
    # --------------------------------------------------------------------------
    SEMAPHORE=$(mktemp -u)
    mkfifo "$SEMAPHORE"
    exec 3<>"$SEMAPHORE"
    local i
    for i in $(seq 1 "$CONCURRENCY"); do echo >&3; done

    # --------------------------------------------------------------------------
    # Main processing loop
    # --------------------------------------------------------------------------
    local current_dir=""
    for input_file in "${FILES[@]}"; do
        local file_dir filename fsize
        file_dir="$(dirname "$input_file")"
        filename="$(basename "$input_file")"

        # --- Per-directory one-time setup ---
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

        # --- Skip files in non-writable directories ---
        if [[ "${DIR_CHECKED[$file_dir]}" == "0" ]]; then
            fsize=$(get_file_size "$input_file")
            printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/skip_sizes"
            increment_counter "$PROGRESS_DIR/skipped"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            continue
        fi

        # --- Skip excluded extensions ---
        if is_excluded "$input_file"; then
            log_info "Excluded: $filename"
            fsize=$(get_file_size "$input_file")
            printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/excl_sizes"
            increment_counter "$PROGRESS_DIR/excluded"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            continue
        fi

        # --- Skip already-processed files unless --force ---
        if [[ "$FORCE" != "true" ]] && splog_has_entry "$file_dir" "$filename"; then
            log_info "Already optimized (skip): $filename"
            fsize=$(get_file_size "$input_file")
            printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/skip_sizes"
            increment_counter "$PROGRESS_DIR/skipped"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            continue
        fi

        # --- Record original size for analytics (before dispatching to worker) ---
        fsize=$(get_file_size "$input_file")
        printf '%020d\n' "$fsize" >> "$PROGRESS_DIR/all_orig_bytes"

        # --- Block until a worker slot is available, then launch ---
        read -u 3
        process_file "$input_file" &
    done

    # Wait for all background workers to finish
    wait
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
main
