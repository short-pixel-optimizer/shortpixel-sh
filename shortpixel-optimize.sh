#!/usr/bin/env bash
# ==============================================================================
# shortpixel-optimize.sh
#
# Batch-optimize images in a local folder using the ShortPixel API.
# Uploads files, polls for results, downloads optimized versions, and
# saves a CSV report of every processed file.
#
# USAGE:
#   ./shortpixel-optimize.sh [OPTIONS] <input_dir>
#
# REQUIRED:
#   <input_dir>          Path to the folder containing images to optimize
#   -k, --key KEY        Your ShortPixel API key
#
# OUTPUT OPTIONS (mutually exclusive):
#   -o, --output-dir DIR Save optimized images to DIR
#                        (default: <input_dir>/optimized/)
#       --overwrite      Replace original files with optimized versions
#
# PROCESSING OPTIONS:
#   -j, --concurrency N  Number of files to process in parallel (default: 4)
#   -w, --wait N         Seconds to wait per API call before polling (1-30, default: 25)
#
# COMPRESSION OPTIONS:
#   -l, --lossy N        Compression mode: 0=lossless, 1=lossy (default), 2=glossy
#       --keep-exif      Preserve EXIF metadata (default: strip it)
#       --no-cmyk2rgb    Disable CMYK-to-RGB conversion (enabled by default)
#
# RESIZE OPTIONS:
#       --resize MODE    0=none (default), 1=outer box, 3=inner box, 4=smart crop
#       --resize-width N Target width in pixels
#       --resize-height N Target height in pixels
#
# FORMAT OPTIONS:
#       --convertto FMT  Convert output: +webp | +avif | +webp+avif
#       --upscale N      Upscale factor: 2, 3, or 4
#
# OTHER OPTIONS:
#       --bg-remove      Remove image background (uses extra API credits)
#   -h, --help           Show this help message and exit
#
# EXAMPLES:
#   # Basic optimization with default settings
#   ./shortpixel-optimize.sh -k MY_API_KEY ./images
#
#   # Lossless compression, 8 parallel workers, save to custom folder
#   ./shortpixel-optimize.sh -k MY_API_KEY -l 0 -j 8 -o ./optimized ./images
#
#   # Overwrite originals, keep EXIF, convert to WebP as well
#   ./shortpixel-optimize.sh -k MY_API_KEY --overwrite --keep-exif --convertto +webp ./images
#
#   # Smart-crop resize to 800x600, glossy compression
#   ./shortpixel-optimize.sh -k MY_API_KEY -l 2 --resize 4 --resize-width 800 \
#       --resize-height 600 ./images
#
# DEPENDENCIES: curl, jq
# ==============================================================================

# Strict mode:
#   -e  Exit immediately if any command fails (unhandled)
#   -u  Treat unset variables as errors (catches typos like $FIEL vs $FILE)
#   -o pipefail  A pipeline fails if any command in it fails, not just the last
set -euo pipefail


# ==============================================================================
# SECTION 1: CONFIGURATION — Default values for all settings
# These are global variables (UPPERCASE by convention). CLI arguments override them.
# ==============================================================================

# ShortPixel API endpoint for uploading local files via multipart POST
readonly API_ENDPOINT="https://api.shortpixel.com/v2/post-reducer.php"

# API key — must be set via --key (no hardcoded default for security)
API_KEY=""

# Compression mode:
#   1 = lossy     (best file size reduction, slight quality loss — good for photos)
#   0 = lossless  (no quality loss — good for graphics, logos, screenshots)
#   2 = glossy    (middle ground between lossy and lossless)
LOSSY=1

# Seconds to wait for the API to finish processing before returning "pending".
# Max is 30. Higher values reduce polling round-trips but slow individual requests.
API_WAIT=25

# Resize mode (0 = no resize). Only applied when resize_width/height are provided.
#   0 = no resize
#   1 = outer box (image fits within the box, may have whitespace)
#   3 = inner box (image fills the box, may crop)
#   4 = smart crop (AI-based crop to keep the most important part)
RESIZE=0
RESIZE_WIDTH=""   # Target width in pixels (empty = not set)
RESIZE_HEIGHT=""  # Target height in pixels (empty = not set)

# Output format conversion (empty = keep original format)
# Examples: "+webp", "+avif", "+webp+avif"
CONVERTTO=""

# 0 = strip EXIF metadata (smaller files, better privacy — the default)
# 1 = preserve EXIF metadata (useful for professional photography)
KEEP_EXIF=0

# 1 = convert CMYK color mode to RGB (enabled by default; CMYK is for print, not web)
# 0 = keep CMYK as-is
CMYK2RGB=1

# 1 = remove image background using AI (costs additional API credits)
BG_REMOVE=0

# Upscaling factor (empty = no upscaling). Valid values: 2, 3, 4
UPSCALE=""

# Number of images to process simultaneously.
# Each worker is a background subprocess. More workers = faster but uses more
# API rate and local CPU/memory.
CONCURRENCY=4

# How many times to poll the API before giving up on a pending image.
# Total max wait = MAX_POLL_RETRIES × POLL_SLEEP_SECONDS
MAX_POLL_RETRIES=12
POLL_SLEEP_SECONDS=5

# Input folder (populated from positional CLI argument)
INPUT_DIR=""

# Output folder (populated from --output-dir, or derived from INPUT_DIR)
OUTPUT_DIR=""

# If true, overwrite original files instead of saving to OUTPUT_DIR
OVERWRITE=false

# Temp directory used for atomic progress counters. Created in main(), cleaned up on exit.
PROGRESS_DIR=""

# Path to the FIFO file used as a semaphore for concurrency control
SEMAPHORE=""

# Path to the CSV results file (set after OUTPUT_DIR is resolved)
CSV_FILE=""

# Total number of image files to process (exported so background workers can read it)
TOTAL_FILES=0

# Per-worker temp upload file. Set inside optimize_single_file() and cleaned up
# by process_file()'s EXIT trap, even if an error occurs.
WORKER_TMP_FILE=""

# ------------------------------------------------------------------------------
# Terminal colors — only enabled when stderr is a real TTY (not a file/pipe)
# tput is more portable than hardcoding ANSI escape codes directly
# ------------------------------------------------------------------------------
if [ -t 2 ]; then
    COLOR_RED=$(tput setaf 1)
    COLOR_GREEN=$(tput setaf 2)
    COLOR_YELLOW=$(tput setaf 3)
    COLOR_BLUE=$(tput setaf 4)
    COLOR_RESET=$(tput sgr0)
    COLOR_BOLD=$(tput bold)
else
    # No TTY → no colors (e.g., when stderr is redirected to a log file)
    COLOR_RED="" COLOR_GREEN="" COLOR_YELLOW=""
    COLOR_BLUE="" COLOR_RESET="" COLOR_BOLD=""
fi


# ==============================================================================
# SECTION 2: HELPER FUNCTIONS — Logging
# All log output goes to stderr so it doesn't interfere with any stdout usage.
# ==============================================================================

log_info() {
    echo "${COLOR_BLUE}[INFO]${COLOR_RESET}  $*" >&2
}

log_success() {
    echo "${COLOR_GREEN}[OK]${COLOR_RESET}    $*" >&2
}

log_warn() {
    echo "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*" >&2
}

log_error() {
    echo "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}


# ==============================================================================
# SECTION 3: HELPER FUNCTIONS — Usage
# ==============================================================================

show_help() {
    # Extract and print the usage block from this script's own header comment.
    # Lines starting with "# ===..." are the section delimiters.
    # sed strips the leading "# " from each line before printing.
    sed -n '/^# ===/{p; :loop; n; /^# ===/q; p; b loop}' "$0" | sed 's/^# \{0,1\}//'
}


# ==============================================================================
# SECTION 4: HELPER FUNCTIONS — File utilities
# ==============================================================================

# ------------------------------------------------------------------------------
# get_file_size <file_path>
#
# Prints the file size in bytes. Supports both Linux (GNU stat) and macOS (BSD stat).
# Falls back to 0 if stat fails for any reason.
# ------------------------------------------------------------------------------
get_file_size() {
    local file="$1"
    # GNU stat (Linux): --format="%s"
    # BSD stat (macOS): -f "%z"
    # We try both and use whichever succeeds first.
    stat --format="%s" "$file" 2>/dev/null \
        || stat -f "%z" "$file" 2>/dev/null \
        || echo "0"
}

# ------------------------------------------------------------------------------
# get_file_extension <filename>
#
# Extracts the lowercase file extension from a filename.
# Example: "Photo.JPG" → "jpg"
# ------------------------------------------------------------------------------
get_file_extension() {
    local filename="$1"
    local ext="${filename##*.}"   # Remove everything up to the last dot
    echo "${ext,,}"               # Lowercase using bash parameter expansion
}


# ==============================================================================
# SECTION 5: HELPER FUNCTIONS — CSV output
# ==============================================================================

# ------------------------------------------------------------------------------
# init_csv <csv_path>
#
# Creates the CSV file and writes the header row.
# Called once before any workers start, so no locking is needed here.
# ------------------------------------------------------------------------------
init_csv() {
    local csv_path="$1"
    printf '%s\n' \
        "filename,original_size_bytes,optimized_size_bytes,savings_percent,compression_type,status,error_message" \
        > "$csv_path"
}

# ------------------------------------------------------------------------------
# write_csv_row <csv_path> <lock_file> <filename> <orig_bytes> <opt_bytes>
#               <savings_pct> <comp_type> <status> <error_msg>
#
# Appends one row to the CSV file in a concurrency-safe manner.
#
# WHY flock:
#   Multiple background workers write to the same file simultaneously.
#   Without a lock, two workers could interleave their writes mid-line,
#   corrupting the CSV. flock(1) acquires an exclusive advisory lock on a
#   lock file (separate from the CSV) before writing, then releases it
#   automatically when the subshell exits.
# ------------------------------------------------------------------------------
write_csv_row() {
    local csv_path="$1"
    local lock_file="$2"
    local filename="$3"
    local orig_bytes="$4"
    local opt_bytes="$5"
    local savings_pct="$6"
    local comp_type="$7"
    local status="$8"
    local error_msg="$9"

    # RFC 4180 CSV quoting: wrap strings in double quotes,
    # and escape any embedded double quotes by doubling them ("" per RFC 4180)
    local safe_filename safe_error
    safe_filename="\"${filename//\"/\"\"}\""
    safe_error="\"${error_msg//\"/\"\"}\""

    # The subshell ( ) releases the lock (closes FD 9) when it exits.
    # flock -x 9 acquires an exclusive (write) lock on FD 9.
    (
        flock -x 9
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$safe_filename" \
            "$orig_bytes" \
            "$opt_bytes" \
            "$savings_pct" \
            "$comp_type" \
            "$status" \
            "$safe_error" \
            >> "$csv_path"
    ) 9>"$lock_file"
}


# ==============================================================================
# SECTION 6: HELPER FUNCTIONS — Progress tracking
# ==============================================================================

# ------------------------------------------------------------------------------
# increment_counter <counter_file>
#
# Atomically increments a file-based counter by appending one newline.
# The count is read later with `wc -l`.
#
# WHY file-based counters:
#   Background workers (launched with &) are subshells — they get their own
#   copy of all variables. Changes to a variable inside a subshell do NOT
#   propagate back to the parent process. File writes, however, are shared
#   across all processes via the kernel's filesystem.
#
# WHY this is safe without a lock:
#   POSIX guarantees that writes of less than PIPE_BUF bytes (at minimum 512,
#   typically 4096) to files opened with O_APPEND are atomic. A single newline
#   (1 byte) is well within that limit, so concurrent appends never interleave.
# ------------------------------------------------------------------------------
increment_counter() {
    local counter_file="$1"
    printf '\n' >> "$counter_file"
}

# ------------------------------------------------------------------------------
# show_progress <total_files> <progress_dir>
#
# Prints a single-line progress status that overwrites itself using \r
# (carriage return moves the cursor to column 0 without advancing the line).
# This creates an in-place updating display without scrolling the terminal.
# ------------------------------------------------------------------------------
show_progress() {
    local total="$1"
    local progress_dir="$2"

    # Count completed files from the counter files (wc -l counts newlines)
    local success_count=0 error_count=0
    [[ -f "$progress_dir/success" ]] && success_count=$(wc -l < "$progress_dir/success")
    [[ -f "$progress_dir/error"   ]] && error_count=$(wc -l < "$progress_dir/error")

    local completed=$(( success_count + error_count ))
    local remaining=$(( total - completed ))

    # \r returns cursor to start of line; trailing spaces erase leftover chars
    # from any previous (potentially longer) progress line.
    printf '\r%s[%d/%d]%s Optimized: %s%d%s | Errors: %s%d%s | Remaining: %d   ' \
        "$COLOR_BOLD" "$completed" "$total" "$COLOR_RESET" \
        "$COLOR_GREEN" "$success_count" "$COLOR_RESET" \
        "$COLOR_RED"   "$error_count"   "$COLOR_RESET" \
        "$remaining" >&2
}


# ==============================================================================
# SECTION 7: HELPER FUNCTIONS — API interaction
# ==============================================================================

# ------------------------------------------------------------------------------
# download_file <url> <dest_path>
#
# Downloads a file from a URL to a local path.
# Returns 0 on success, 1 on failure.
#
# Flags used:
#   --fail        Return error exit code on HTTP 4xx/5xx
#   --location    Follow HTTP redirects (CDN may redirect to the actual file)
#   --silent      Suppress the default download progress meter
#   --show-error  Print error message even when --silent is active
# ------------------------------------------------------------------------------
download_file() {
    local url="$1"
    local dest_path="$2"

    # Create parent directory if it doesn't exist
    mkdir -p "$(dirname "$dest_path")"

    if curl --fail --silent --show-error --location \
            --output "$dest_path" \
            "$url"; then
        return 0
    else
        log_error "Download failed: $url"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# parse_api_response <json_string> <jq_query>
#
# Safely parses a field from the API response, handling two edge cases:
#   1. The API normally returns a JSON ARRAY: [{...}]
#   2. Global errors (e.g., invalid file_paths format) return a plain OBJECT: {...}
#
# This function normalizes the response to always be an array before parsing,
# then applies the given jq query. Returns "parse_error" if anything fails.
# ------------------------------------------------------------------------------
parse_api_response() {
    local json="$1"
    local query="$2"

    # Normalize to array, then apply query.
    # 'if type == "array" then . else [.] end' wraps a plain object in an array
    # so that .[0].Field works uniformly regardless of the response format.
    echo "$json" \
        | jq -r "if type == \"array\" then . else [.] end | ${query}" 2>/dev/null \
        || echo "parse_error"
}

# ------------------------------------------------------------------------------
# optimize_single_file <input_file_path>
#
# The core function. Handles the complete optimization lifecycle for one image:
#   1. Copy file to a temp path (curl can't upload files with spaces in paths)
#   2. POST to ShortPixel API via multipart form upload
#   3. Parse the JSON response for status
#   4. If pending (status "1"), poll using the returned OriginalURL (no re-upload)
#   5. On completion (status "2"), download the optimized file
#   6. Write result to CSV and update progress counters
#
# Note: The temp upload file (WORKER_TMP_FILE) is cleaned up by process_file()'s
#       EXIT trap, not here, so cleanup happens even if this function returns early.
#
# Returns 0 on success, 1 on any failure (the file is still logged in the CSV).
# ------------------------------------------------------------------------------
optimize_single_file() {
    local input_file="$1"

    # --------------------------------------------------------------------------
    # Derive names and paths
    # --------------------------------------------------------------------------

    local filename
    filename="$(basename "$input_file")"

    # Where to save the optimized file locally
    local output_file
    if [[ "$OVERWRITE" == "true" ]]; then
        output_file="$input_file"
    else
        output_file="${OUTPUT_DIR}/${filename}"
    fi

    # Human-readable label for the compression mode (used in the CSV)
    local comp_type
    case "$LOSSY" in
        0) comp_type="lossless" ;;
        1) comp_type="lossy"    ;;
        2) comp_type="glossy"   ;;
        *) comp_type="unknown"  ;;
    esac

    # --------------------------------------------------------------------------
    # Get original file size (for savings calculation and CSV)
    # --------------------------------------------------------------------------
    local original_size
    original_size=$(get_file_size "$input_file")

    # --------------------------------------------------------------------------
    # Create a temp upload file with a safe, space-free path
    #
    # WHY: curl's -F option cannot upload files whose paths contain spaces or
    # special characters (it terminates the path at the first space when parsing
    # the form field value). By copying to a temp file with a generated safe name,
    # we guarantee the upload always works regardless of the original filename.
    #
    # WORKER_TMP_FILE is a global (within this worker subshell) so that
    # process_file()'s EXIT trap can clean it up even if we return early.
    # --------------------------------------------------------------------------
    local extension
    extension=$(get_file_extension "$filename")
    WORKER_TMP_FILE=$(mktemp --suffix=".${extension}")

    if ! cp "$input_file" "$WORKER_TMP_FILE"; then
        log_error "Could not copy '$filename' to temp location for upload"
        write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
            "$filename" "$original_size" "0" "0" "$comp_type" "error" "failed to create temp upload file"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # --------------------------------------------------------------------------
    # Build the API request as a curl argument array
    #
    # WHY an array instead of a string:
    #   If we built a string like: args="-F key=... -F file=@my photo.jpg"
    #   and then ran: curl $args
    #   bash would split on spaces and break "my photo.jpg" into two tokens.
    #   An array preserves each argument as a single token regardless of content.
    #
    # file_paths format (from API docs):
    #   {"<field_name>": "<original_path_or_filename>"}
    #   The key must match the name of the form field containing the binary data.
    #   The value is the path/identifier used for reporting (can be the original name).
    #   We use "file1" as the constant field name (simple, matches the API docs example).
    # --------------------------------------------------------------------------
    local -a curl_args=(
        --silent
        --show-error
        -F "key=${API_KEY}"
        -F "lossy=${LOSSY}"
        -F "wait=${API_WAIT}"
        -F "resize=${RESIZE}"
        -F "keep_exif=${KEEP_EXIF}"
        -F "cmyk2rgb=${CMYK2RGB}"
        -F "bg_remove=${BG_REMOVE}"
        -F "file_paths={\"file1\":\"${filename}\"}"
        # "file1" is the field name; WORKER_TMP_FILE is the safe local path to upload
        -F "file1=@${WORKER_TMP_FILE}"
    )

    # Append optional parameters only if they have values.
    # Sending an empty string for an optional param could override API defaults.
    [[ -n "$RESIZE_WIDTH"  ]] && curl_args+=(-F "resize_width=${RESIZE_WIDTH}")
    [[ -n "$RESIZE_HEIGHT" ]] && curl_args+=(-F "resize_height=${RESIZE_HEIGHT}")
    [[ -n "$CONVERTTO"     ]] && curl_args+=(-F "convertto=${CONVERTTO}")
    [[ -n "$UPSCALE"       ]] && curl_args+=(-F "upscale=${UPSCALE}")

    log_info "Uploading: $filename"

    # --------------------------------------------------------------------------
    # Upload the file to the ShortPixel API
    # --------------------------------------------------------------------------
    local api_response
    if ! api_response=$(curl "${curl_args[@]}" "$API_ENDPOINT" 2>&1); then
        log_error "Upload request failed for: $filename"
        write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
            "$filename" "$original_size" "0" "0" "$comp_type" "error" "curl upload failed: $api_response"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # --------------------------------------------------------------------------
    # Parse the initial API response
    #
    # The API normally returns a JSON ARRAY of results, one per uploaded file.
    # Since we upload one file at a time, we read element [0].
    # parse_api_response() normalizes plain error objects to arrays first.
    #
    # Status codes (returned as strings, not integers):
    #   "1"  = Pending (API accepted the file but is still processing)
    #   "2"  = Complete (optimized file is ready to download)
    #   negative strings = Errors (e.g., "-111"=file too large, "-403"=quota exceeded)
    # --------------------------------------------------------------------------
    local status_code status_message original_url
    status_code=$(parse_api_response "$api_response" '.[0].Status.Code // "parse_error"')
    status_message=$(parse_api_response "$api_response" '.[0].Status.Message // "unknown"')
    original_url=$(parse_api_response "$api_response" '.[0].OriginalURL // ""')

    if [[ "$status_code" == "parse_error" ]]; then
        log_error "Could not parse API response for: $filename"
        log_error "Raw response: ${api_response:0:200}"  # Show first 200 chars only
        write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
            "$filename" "$original_size" "0" "0" "$comp_type" "error" "invalid API response"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # --------------------------------------------------------------------------
    # Polling loop — runs when the API returns status "1" (still processing)
    #
    # Instead of re-uploading the binary (slow, wastes bandwidth and API credits),
    # we send just the OriginalURL the API returned. The API uses this to check
    # the status of the already-queued file.
    # --------------------------------------------------------------------------
    local poll_count=0
    while [[ "$status_code" == "1" ]]; do

        if (( poll_count >= MAX_POLL_RETRIES )); then
            log_error "Polling timed out after $MAX_POLL_RETRIES attempts for: $filename"
            write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
                "$filename" "$original_size" "0" "0" "$comp_type" "error" "polling timeout"
            increment_counter "$PROGRESS_DIR/error"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            return 1
        fi

        log_info "  '$filename' still processing (poll $((poll_count + 1))/$MAX_POLL_RETRIES, waiting ${POLL_SLEEP_SECONDS}s)..."
        sleep "$POLL_SLEEP_SECONDS"
        (( poll_count++ ))

        # Poll using the OriginalURL returned by the initial upload response.
        # file_urls[] tells the API "check this job" instead of uploading a new file.
        if ! api_response=$(curl --silent --show-error \
                -F "key=${API_KEY}" \
                -F "wait=${API_WAIT}" \
                -F "file_urls[]=${original_url}" \
                "$API_ENDPOINT" 2>&1); then
            log_error "Poll request failed for: $filename"
            write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
                "$filename" "$original_size" "0" "0" "$comp_type" "error" "poll request failed"
            increment_counter "$PROGRESS_DIR/error"
            show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
            return 1
        fi

        status_code=$(parse_api_response "$api_response" '.[0].Status.Code // "parse_error"')
        status_message=$(parse_api_response "$api_response" '.[0].Status.Message // "unknown"')
    done

    # --------------------------------------------------------------------------
    # Handle API errors (any status code that is not "2")
    # Common error codes:
    #   -108  Not a valid image file
    #   -111  File too large
    #   -201  Not an image
    #   -301  Not enough API credits
    #   -401  Invalid API key
    #   -403  Quota exceeded
    # --------------------------------------------------------------------------
    if [[ "$status_code" != "2" ]]; then
        log_error "API error for '$filename': [Code $status_code] $status_message"
        write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
            "$filename" "$original_size" "0" "0" "$comp_type" "error" \
            "API error $status_code: $status_message"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # --------------------------------------------------------------------------
    # Extract download URL and optimized file size from the success response
    #
    # The API returns different URLs depending on compression type:
    #   LossyURL / LossySize       → for lossy (1) and glossy (2) modes
    #   LosslessURL / LoselessSize → for lossless (0) mode
    #   Note: "LoselessSize" is a typo in the API but that is the actual field name
    # --------------------------------------------------------------------------
    local download_url optimized_size
    if [[ "$LOSSY" == "0" ]]; then
        download_url=$(parse_api_response "$api_response"  '.[0].LosslessURL  // ""')
        optimized_size=$(parse_api_response "$api_response" '.[0].LoselessSize // "0"')
    else
        download_url=$(parse_api_response "$api_response"  '.[0].LossyURL  // ""')
        optimized_size=$(parse_api_response "$api_response" '.[0].LossySize // "0"')
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        log_error "API returned no download URL for: $filename"
        write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
            "$filename" "$original_size" "0" "0" "$comp_type" "error" "missing download URL in response"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # --------------------------------------------------------------------------
    # Download the optimized file
    # --------------------------------------------------------------------------
    if ! download_file "$download_url" "$output_file"; then
        write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
            "$filename" "$original_size" "$optimized_size" "0" "$comp_type" \
            "error" "download failed"
        increment_counter "$PROGRESS_DIR/error"
        show_progress "$TOTAL_FILES" "$PROGRESS_DIR"
        return 1
    fi

    # --------------------------------------------------------------------------
    # Calculate savings percentage
    #
    # Bash can only do integer math. To get 2 decimal places (e.g., "31.25%")
    # we multiply by 10000 before dividing, giving us a fixed-point integer,
    # then format it with printf. This avoids requiring `bc` or `python3`.
    #
    # Example: original=200000, optimized=137500
    #   savings_int = (200000 - 137500) * 10000 / 200000 = 3125
    #   result      = printf "%d.%02d" 31 25  →  "31.25"
    # --------------------------------------------------------------------------
    local savings_pct="0.00"
    if (( original_size > 0 && optimized_size > 0 )); then
        local savings_int=$(( (original_size - optimized_size) * 10000 / original_size ))
        savings_pct=$(printf '%d.%02d' $(( savings_int / 100 )) $(( savings_int % 100 )))
    fi

    # --------------------------------------------------------------------------
    # Record success and update the progress display
    # --------------------------------------------------------------------------
    write_csv_row "$CSV_FILE" "$PROGRESS_DIR/csv.lock" \
        "$filename" "$original_size" "$optimized_size" "$savings_pct" \
        "$comp_type" "success" ""

    increment_counter "$PROGRESS_DIR/success"
    show_progress "$TOTAL_FILES" "$PROGRESS_DIR"

    log_success "$filename — ${original_size} → ${optimized_size} bytes (${savings_pct}% saved)"
    return 0
}

# ------------------------------------------------------------------------------
# process_file <input_file>
#
# Thin wrapper around optimize_single_file that GUARANTEES:
#   1. The semaphore token is returned when this worker exits
#   2. Any temp upload file is cleaned up
# Both happen even if optimize_single_file fails or the subshell is killed.
#
# HOW THE SEMAPHORE WORKS:
#   The parent process fills a FIFO pipe (FD 3) with N tokens.
#   Before launching each worker, the parent reads one token (blocking if empty).
#   The worker runs in a background subshell (&) and inherits FD 3.
#   When the worker exits, this EXIT trap writes a token back, unblocking the parent.
#
# WHY "|| true":
#   With set -e, if optimize_single_file returns 1, bash would immediately exit
#   the subshell before the EXIT trap can clean up. The "|| true" converts the
#   non-zero return to 0, preventing set -e from firing while still allowing the
#   error handling INSIDE optimize_single_file to run and log the failure.
# ------------------------------------------------------------------------------
process_file() {
    local input_file="$1"

    # This trap runs when THIS subshell exits, for any reason.
    # It cleans up the temp upload file and returns the semaphore token.
    # "echo >&3" writes one byte to FD 3 (the semaphore FIFO), returning a token.
    trap '[[ -n "${WORKER_TMP_FILE:-}" ]] && rm -f "$WORKER_TMP_FILE"; echo >&3' EXIT

    optimize_single_file "$input_file" || true
}


# ==============================================================================
# SECTION 8: ARGUMENT PARSING
#
# We use a manual while/case loop rather than getopts because getopts does not
# support long options (--key, --output-dir) portably in bash.
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;

        # --- Required ---
        -k|--key)
            API_KEY="$2"; shift 2 ;;
        --key=*)
            API_KEY="${1#*=}"; shift ;;

        # --- Output destination ---
        -o|--output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*)
            OUTPUT_DIR="${1#*=}"; shift ;;
        --overwrite)
            OVERWRITE=true; shift ;;

        # --- Processing ---
        -j|--concurrency)
            CONCURRENCY="$2"; shift 2 ;;
        --concurrency=*)
            CONCURRENCY="${1#*=}"; shift ;;
        -w|--wait)
            API_WAIT="$2"; shift 2 ;;
        --wait=*)
            API_WAIT="${1#*=}"; shift ;;

        # --- Compression ---
        -l|--lossy)
            LOSSY="$2"; shift 2 ;;
        --lossy=*)
            LOSSY="${1#*=}"; shift ;;
        --keep-exif)
            KEEP_EXIF=1; shift ;;
        --no-cmyk2rgb)
            CMYK2RGB=0; shift ;;

        # --- Resize ---
        --resize)
            RESIZE="$2"; shift 2 ;;
        --resize=*)
            RESIZE="${1#*=}"; shift ;;
        --resize-width)
            RESIZE_WIDTH="$2"; shift 2 ;;
        --resize-width=*)
            RESIZE_WIDTH="${1#*=}"; shift ;;
        --resize-height)
            RESIZE_HEIGHT="$2"; shift 2 ;;
        --resize-height=*)
            RESIZE_HEIGHT="${1#*=}"; shift ;;

        # --- Format ---
        --convertto)
            CONVERTTO="$2"; shift 2 ;;
        --convertto=*)
            CONVERTTO="${1#*=}"; shift ;;
        --upscale)
            UPSCALE="$2"; shift 2 ;;
        --upscale=*)
            UPSCALE="${1#*=}"; shift ;;

        # --- Other ---
        --bg-remove)
            BG_REMOVE=1; shift ;;

        --)
            # End-of-options marker; everything after "--" is a positional argument
            shift; break ;;

        -*)
            log_error "Unknown option: $1"
            echo "Run with --help for usage information." >&2
            exit 1
            ;;

        *)
            # The first non-option argument is the input directory
            if [[ -z "$INPUT_DIR" ]]; then
                INPUT_DIR="$1"
            else
                log_error "Unexpected extra argument: $1"
                echo "Run with --help for usage information." >&2
                exit 1
            fi
            shift
            ;;
    esac
done


# ==============================================================================
# SECTION 9: VALIDATION
# Check all inputs before doing any real work. Fail fast with a clear message.
# ==============================================================================

# --- Dependency checks ---
if ! command -v curl &>/dev/null; then
    log_error "curl is not installed. Please install it and try again."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq is not installed. Please install it and try again."
    log_error "  Ubuntu/Debian: sudo apt install jq"
    log_error "  macOS:         brew install jq"
    exit 1
fi

# --- Required arguments ---
if [[ -z "$API_KEY" ]]; then
    log_error "API key is required. Use: --key YOUR_API_KEY"
    exit 1
fi

if [[ -z "$INPUT_DIR" ]]; then
    log_error "Input directory is required as a positional argument."
    echo "Usage: $0 [OPTIONS] <input_dir>" >&2
    exit 1
fi

if [[ ! -d "$INPUT_DIR" ]]; then
    log_error "Input directory does not exist: $INPUT_DIR"
    exit 1
fi

if [[ ! -r "$INPUT_DIR" ]]; then
    log_error "Input directory is not readable: $INPUT_DIR"
    exit 1
fi

# --- Numeric range checks ---
if ! [[ "$LOSSY" =~ ^[012]$ ]]; then
    log_error "--lossy must be 0 (lossless), 1 (lossy), or 2 (glossy). Got: $LOSSY"
    exit 1
fi

if ! [[ "$API_WAIT" =~ ^[0-9]+$ ]] || (( API_WAIT < 1 || API_WAIT > 30 )); then
    log_error "--wait must be an integer between 1 and 30. Got: $API_WAIT"
    exit 1
fi

if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 )); then
    log_error "--concurrency must be a positive integer. Got: $CONCURRENCY"
    exit 1
fi

if ! [[ "$RESIZE" =~ ^(0|1|3|4)$ ]]; then
    log_error "--resize must be 0 (none), 1 (outer), 3 (inner), or 4 (smart crop). Got: $RESIZE"
    exit 1
fi

if [[ -n "$RESIZE_WIDTH" ]] && ! [[ "$RESIZE_WIDTH" =~ ^[0-9]+$ && "$RESIZE_WIDTH" -gt 0 ]]; then
    log_error "--resize-width must be a positive integer. Got: $RESIZE_WIDTH"
    exit 1
fi

if [[ -n "$RESIZE_HEIGHT" ]] && ! [[ "$RESIZE_HEIGHT" =~ ^[0-9]+$ && "$RESIZE_HEIGHT" -gt 0 ]]; then
    log_error "--resize-height must be a positive integer. Got: $RESIZE_HEIGHT"
    exit 1
fi

if [[ -n "$CONVERTTO" ]] && ! [[ "$CONVERTTO" =~ ^\+(webp|avif|webp\+avif)$ ]]; then
    log_error "--convertto must be one of: +webp  +avif  +webp+avif. Got: $CONVERTTO"
    exit 1
fi

if [[ -n "$UPSCALE" ]] && ! [[ "$UPSCALE" =~ ^[234]$ ]]; then
    log_error "--upscale must be 2, 3, or 4. Got: $UPSCALE"
    exit 1
fi

# --- Mutually exclusive output options ---
if [[ "$OVERWRITE" == "true" && -n "$OUTPUT_DIR" ]]; then
    log_error "--overwrite and --output-dir cannot be used together."
    exit 1
fi

# --- Resolve output directory ---
if [[ "$OVERWRITE" == "true" ]]; then
    # In overwrite mode, we still need a place for the CSV file.
    # Use a hidden subfolder to keep it separate from the images.
    OUTPUT_DIR="${INPUT_DIR}/.shortpixel"
elif [[ -z "$OUTPUT_DIR" ]]; then
    # Default: create an "optimized" subfolder inside the input directory
    OUTPUT_DIR="${INPUT_DIR}/optimized"
fi

# Create the output directory if it doesn't exist
if ! mkdir -p "$OUTPUT_DIR"; then
    log_error "Could not create output directory: $OUTPUT_DIR"
    exit 1
fi

if [[ ! -w "$OUTPUT_DIR" ]]; then
    log_error "Output directory is not writable: $OUTPUT_DIR"
    exit 1
fi


# ==============================================================================
# SECTION 10: MAIN — Orchestrates file discovery and parallel processing
# ==============================================================================

main() {

    # --------------------------------------------------------------------------
    # Cleanup function — runs automatically on any exit (normal, error, Ctrl-C)
    # --------------------------------------------------------------------------
    cleanup() {
        # Print a newline after the \r-based progress line so the shell prompt
        # appears on a fresh line (not on top of the progress display)
        echo >&2

        # Remove temp files created during this run
        [[ -n "$SEMAPHORE"     && -p "$SEMAPHORE"     ]] && rm -f "$SEMAPHORE"
        [[ -n "$PROGRESS_DIR"  && -d "$PROGRESS_DIR"  ]] && rm -rf "$PROGRESS_DIR"
    }
    trap cleanup EXIT

    # On Ctrl-C or SIGTERM: wait for active workers to finish cleanly before exit.
    # This prevents half-written CSV rows and ensures semaphore tokens are returned.
    trap 'log_warn "Interrupted. Waiting for active workers to finish..."; wait; exit 130' INT TERM

    # --------------------------------------------------------------------------
    # Initialize temp directory for atomic progress counters
    # --------------------------------------------------------------------------
    PROGRESS_DIR=$(mktemp -d)

    # Pre-create counter files as empty (so `wc -l` returns 0 before any writes)
    touch "$PROGRESS_DIR/success" "$PROGRESS_DIR/error" "$PROGRESS_DIR/csv.lock"

    # --------------------------------------------------------------------------
    # Initialize CSV results file
    # --------------------------------------------------------------------------
    CSV_FILE="${OUTPUT_DIR}/optimization_results.csv"
    init_csv "$CSV_FILE"

    # --------------------------------------------------------------------------
    # Discover image files in the input directory
    #
    # WHY `find -print0` + `read -d ''`:
    #   A naive `for f in *.jpg` or `$(ls)` breaks on filenames with spaces,
    #   newlines, or special characters. This pattern handles ALL filenames safely
    #   by using the null byte (\0) as the delimiter instead of whitespace.
    #
    # -maxdepth 1: only process files directly in the input folder, not subfolders
    # -iname:      case-insensitive match (catches .JPG, .Jpeg, etc.)
    # --------------------------------------------------------------------------
    local -a FILES=()
    while IFS= read -r -d '' file; do
        FILES+=("$file")
    done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( \
        -iname "*.jpg"  -o \
        -iname "*.jpeg" -o \
        -iname "*.png"  -o \
        -iname "*.gif"  -o \
        -iname "*.webp" \
    \) -print0 | sort -z)
    # sort -z: sort the null-delimited list for deterministic, alphabetical processing

    TOTAL_FILES=${#FILES[@]}

    if (( TOTAL_FILES == 0 )); then
        log_warn "No supported image files found in: $INPUT_DIR"
        log_warn "Supported formats: JPG, JPEG, PNG, GIF, WEBP"
        exit 0
    fi

    # Export so background worker subshells can read the value for show_progress()
    export TOTAL_FILES CSV_FILE PROGRESS_DIR

    # --------------------------------------------------------------------------
    # Print run summary before starting
    # --------------------------------------------------------------------------
    local comp_label
    case "$LOSSY" in
        0) comp_label="lossless" ;;
        1) comp_label="lossy"    ;;
        2) comp_label="glossy"   ;;
    esac

    echo >&2
    log_info "ShortPixel Batch Optimizer"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Input folder  : $INPUT_DIR"
    if [[ "$OVERWRITE" == "true" ]]; then
        log_info "Output mode   : Overwrite originals"
    else
        log_info "Output folder : $OUTPUT_DIR"
    fi
    log_info "Images found  : $TOTAL_FILES"
    log_info "Compression   : $comp_label (lossy=$LOSSY)"
    log_info "Workers       : $CONCURRENCY parallel"
    log_info "Results CSV   : $CSV_FILE"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo >&2

    # --------------------------------------------------------------------------
    # Set up the FIFO-based semaphore for concurrency control
    #
    # HOW IT WORKS:
    #   A named pipe (FIFO) acts as a pool of N tokens. Before starting a worker,
    #   the parent reads one token (blocking if the pool is empty). When a worker
    #   finishes, its EXIT trap writes a token back, unblocking the next iteration.
    #
    # DETAILS:
    #   mktemp -u  generates a unique path WITHOUT creating the file (-u = unsafe mode)
    #   mkfifo     creates the named pipe at that path
    #   exec 3<>   opens the FIFO on FD 3 in read+write mode
    #              (read-write keeps the pipe open even when the pool is "empty",
    #               preventing a premature EOF that would make `read -u 3` fail)
    # --------------------------------------------------------------------------
    SEMAPHORE=$(mktemp -u)
    mkfifo "$SEMAPHORE"
    exec 3<>"$SEMAPHORE"

    # Fill the semaphore with N tokens (one per allowed concurrent worker)
    for i in $(seq 1 "$CONCURRENCY"); do
        echo >&3
    done

    # --------------------------------------------------------------------------
    # Process all files — dispatching workers up to CONCURRENCY at a time
    # --------------------------------------------------------------------------
    for input_file in "${FILES[@]}"; do

        # `read -u 3` blocks here until a token is available in the semaphore.
        # When a worker finishes and runs `echo >&3`, this unblocks.
        read -u 3

        # Launch the worker as a background subshell.
        # The & sends it to the background; the parent immediately continues
        # to the next loop iteration (and blocks at the next `read -u 3`).
        # FD 3 is inherited by the subshell so the EXIT trap can write back.
        process_file "$input_file" &

    done

    # Wait for ALL background workers to finish before printing the summary
    wait

    # --------------------------------------------------------------------------
    # Final summary
    # --------------------------------------------------------------------------
    local final_success final_error
    final_success=$(wc -l < "$PROGRESS_DIR/success")
    final_error=$(wc -l < "$PROGRESS_DIR/error")

    echo >&2
    echo "${COLOR_BOLD}===== Optimization Complete =====${COLOR_RESET}" >&2
    printf '  %-16s : %d\n'  "Files found"  "$TOTAL_FILES"                         >&2
    printf '  %-16s : %s%d%s\n' "Succeeded" "$COLOR_GREEN" "$final_success" "$COLOR_RESET" >&2
    printf '  %-16s : %s%d%s\n' "Failed"    "$COLOR_RED"   "$final_error"   "$COLOR_RESET" >&2
    printf '  %-16s : %s\n'  "Results CSV"  "$CSV_FILE"                             >&2
    echo "${COLOR_BOLD}=================================${COLOR_RESET}" >&2
}


# ==============================================================================
# ENTRY POINT
# All functions are defined above. main() is called last.
# ==============================================================================
main
