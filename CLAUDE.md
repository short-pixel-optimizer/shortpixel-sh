# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`shortpixel-optimize.sh` v2.0 — a production-ready bash script that batch-optimizes images using the [ShortPixel API](https://shortpixel.com/api-docs#post). It uploads local files via multipart POST, polls for results, downloads optimized versions, maintains per-folder `.splog` state files, mirrors originals to a backup directory, and displays an analytics dashboard on exit.

## Running the script

```bash
# Optimize current directory recursively (key from .env)
./shortpixel-optimize.sh

# Optimize a specific folder, 8 workers, overwrite originals
./shortpixel-optimize.sh -k YOUR_API_KEY --overwrite -j 8 ./images

# Glossy compression, custom output dir, convert to WebP
./shortpixel-optimize.sh -k YOUR_API_KEY -l 2 -o ./out --convertto +webp ./images

# Re-optimize everything, ignoring .splog state
./shortpixel-optimize.sh --force --overwrite ./images

# Restore all originals from backup (deletes .splog files after)
./shortpixel-optimize.sh --restore ./images

# Purge backups older than 14 days that have a .splog entry
./shortpixel-optimize.sh --purge-backups 14 ./images

# Full help (includes exit codes and .env schema)
./shortpixel-optimize.sh --help
```

**Dependencies:** `curl`, `jq` (auto-installed via `apt` if missing)

**Configuration:** Create a `.env` file in the script's directory:
```
API_KEY=your_key_here
BACKUP_DIR=/path/to/backups          # optional, default: <script_dir>/backups
EXCLUDE_EXT=JPG,PNG                  # optional, case-sensitive
```

## Architecture

The script is structured in 18 clearly labelled sections inside a single file:

1. **Configuration + .env loading** — loads `.env` from script dir, sets UPPERCASE globals
2. **Terminal colors** — TTY-conditional ANSI colors
3. **Logging helpers** — `log_info/success/warn/error()`, all write to stderr
4. **Help** — `show_help()` extracts the header comment block from the script itself
5. **File utilities** — `get_file_size()`, `get_file_extension()`, `get_md5()`, `format_bytes()`
6. **Exclusion check** — `is_excluded()`: case-sensitive extension match against `EXCLUDE_EXT`
7. **`.splog` management** — `splog_prune()`, `splog_has_entry()`, `splog_write_entry()`
8. **Backup management** — `get_backup_path()`, `backup_file()`, `verify_backup()`
9. **Progress tracking** — `increment_counter()` (atomic O_APPEND), `show_progress()`
10. **API interaction** — `download_file()`, `parse_api_response()`, `optimize_single_file()`, `process_file()`
11. **Analytics Dashboard** — `show_dashboard()`: file counts, space savings (MB/GB), skipped folders
12. **Restore** — `do_restore()`: copies backup mirror → source, writes `restore_audit.log`
13. **Purge** — `do_purge_backups()`: age + `.splog` gated backup deletion
14. **Argument parsing** — manual `while/case` loop (supports `-k VAL` and `--key=VAL` forms)
15. **Dependency checks** — curl required; jq auto-installed via apt if missing
16. **Restore / Purge dispatch** — early exit for `--restore` and `--purge-backups` modes
17. **Validation** — range checks, mutex flag checks, output/backup dir setup
18. **Main** — file discovery, per-dir `.splog` pruning, FIFO semaphore, parallel dispatch

### Concurrency model

A named pipe (FIFO) acts as a semaphore with N tokens. The main loop reads one token before launching each worker (`&`), blocking when all workers are busy. Each worker's `EXIT` trap in `process_file()` writes a token back unconditionally, even on error.

```
SEMAPHORE (FIFO, FD 3): [token][token][token][token]   ← N=CONCURRENCY tokens
for each file:
    read -u 3            # blocks until a worker slot is free
    process_file &       # EXIT trap always does: echo >&3  (returns token)
wait
```

### State management (.splog)

Each source directory gets a `.splog` file alongside its images. Format (pipe-delimited):
```
md5hash|filename|orig_size|opt_size|savings_pct|comp_type|epoch_timestamp
```

- Written only on successful optimization (never on failure)
- Pruned at startup: entries for deleted files are removed before processing begins
- Skipped on the next run unless `--force` is passed
- Deleted entirely after `--restore` completes

### Backup & restore

Before any file is processed, the original is copied to a mirrored backup tree:
```
source:  <INPUT_DIR>/subdir/photo.jpg
backup:  <BACKUP_DIR>/subdir/photo.jpg
```

The backup is verified (exists and size > 0) before the API call. If verification fails, the file is skipped and flagged as an error — the original is never touched.

`--restore` copies every file in the backup tree back to its source location, overwrites `restore_audit.log` in the script directory, then deletes all `.splog` files.

`--purge-backups N` deletes backup files that are **both** older than N days **and** present in the corresponding `.splog`. Files with no `.splog` entry are kept regardless of age.

### Output path

- **Default** (no `--output-dir`): `<source_dir>/optimized/<filename>` — optimized file lands in an `optimized/` subfolder inside the same directory as the source
- **`--output-dir DIR`**: all optimized files go flat into `DIR/`
- **`--overwrite`**: replaces the source file in-place (backup is created first)

`optimized/` subdirectories are automatically excluded from recursive file discovery.

### ShortPixel API behaviour

- Endpoint: `POST https://api.shortpixel.com/v2/post-reducer.php` (multipart form)
- `file_paths` must use a simple key (e.g. `"file1"`) that matches the form field name
- Files with spaces/special chars in their path must be copied to a temp file first — curl's `-F field=@path` cannot handle spaces in the path portion
- The API returns a JSON **array** on success, but a plain **object** for global errors; `parse_api_response()` normalizes both to array before parsing
- `Status.Code` is returned as a **string** (`"1"`, `"2"`, `"-403"`, etc.), not a number
- Status `"1"` = pending; poll with `file_urls[]=<OriginalURL>` (no binary re-upload)
- Status `"2"` = complete; download from `LossyURL` or `LosslessURL`
- curl `--max-time` is set to `max(60, API_WAIT + 60)` to prevent infinite hangs
- A timeout (curl exit 28) produces a specific error message suggesting the key may be domain-restricted

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | API / Network error (fatal) |
| 2 | Permissions error |
| 3 | Configuration / dependency error |

The Analytics Dashboard is always printed on exit, regardless of exit code.

### Analytics Dashboard

Shown on every exit (normal, error, Ctrl-C). Displays:
- File counts: processed / failed / skipped (`.splog`) / excluded (extension)
- Skipped folders list (no write permission)
- Source savings: original total vs current total vs bytes saved (MB/GB)
- Total system footprint: current source + backup folder size
