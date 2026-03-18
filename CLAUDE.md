# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`shortpixel-optimize.sh` — a bash script that batch-optimizes images using the [ShortPixel API](https://shortpixel.com/api-docs#post). It uploads local files via multipart POST, polls for results, downloads the optimized versions, and writes a CSV report.

## Running the script

```bash
# Basic usage (saves to ./images/optimized/)
close 

# Overwrite originals, 8 parallel workers
./shortpixel-optimize.sh -k YOUR_API_KEY --overwrite -j 8 ./images

# Glossy compression, custom output dir, convert to WebP
./shortpixel-optimize.sh -k YOUR_API_KEY -l 2 -o ./out --convertto +webp ./images

# Full help
./shortpixel-optimize.sh --help
```

**Dependencies:** `curl`, `jq`

## Architecture

The script is structured in 10 clearly labelled sections inside a single file:

1. **Configuration** — all defaults as UPPERCASE globals
2. **Logging helpers** — `log_info/success/warn/error()`, all write to stderr
3. **Usage** — `show_help()` extracts the header comment block from the script itself
4. **File utilities** — `get_file_size()` (GNU+BSD stat), `get_file_extension()`
5. **CSV output** — `init_csv()`, `write_csv_row()` (uses `flock` for concurrent safety)
6. **Progress tracking** — `increment_counter()` (atomic O_APPEND), `show_progress()` (`\r`-based in-place display)
7. **API interaction** — `download_file()`, `parse_api_response()`, `optimize_single_file()`, `process_file()`
8. **Argument parsing** — manual `while/case` loop (supports both `-k VAL` and `--key=VAL` forms)
9. **Validation** — dependency checks, range checks, output dir resolution
10. **Main** — file discovery, FIFO semaphore setup, parallel dispatch

### Concurrency model

A named pipe (FIFO) acts as a semaphore with N tokens. The main loop reads one token before launching each worker (`&`), blocking when all workers are busy. Each worker's `EXIT` trap in `process_file()` writes a token back unconditionally, even on error.

```
SEMAPHORE (FIFO, FD 3): [token][token][token][token]   ← N=CONCURRENCY tokens
for each file:
    read -u 3            # blocks until a worker slot is free
    process_file &       # EXIT trap always does: echo >&3  (returns token)
wait
```

### ShortPixel API behaviour

- Endpoint: `POST https://api.shortpixel.com/v2/post-reducer.php` (multipart form)
- `file_paths` must use a simple key (e.g. `"file1"`) that matches the form field name
- Files with spaces/special chars in their path must be copied to a temp file first — curl's `-F field=@path` cannot handle spaces in the path portion
- The API returns a JSON **array** on success, but a plain **object** for global errors; `parse_api_response()` normalizes both to array before parsing
- `Status.Code` is returned as a **string** (`"1"`, `"2"`, `"-403"`, etc.), not a number
- Status `"1"` = pending; poll with `file_urls[]=<OriginalURL>` (no binary re-upload)
- Status `"2"` = complete; download from `LossyURL` or `LosslessURL`

### CSV output

Saved to `<output_dir>/optimization_results.csv`, RFC 4180 compliant (string fields double-quoted, internal quotes doubled). Columns:

```
filename, original_size_bytes, optimized_size_bytes, savings_percent, compression_type, status, error_message
```

Every file gets a row — successes and failures alike.
