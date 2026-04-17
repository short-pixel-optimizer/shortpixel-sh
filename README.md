
##  ShortPixel Optimizer CLI

`shortpixel-optimize.sh` v3.0 — a zero-dependency, production-ready bash script that batch-optimizes images using the [ShortPixel API](https://shortpixel.com/api-docs#post). It uploads local files via multipart POST, polls for results, downloads optimized versions, maintains per-folder `.splog` state files, mirrors originals to a backup directory, displays an analytics dashboard on exit, and optionally emails the report.

**No extra dependencies** — requires only `bash 4+` and `curl`. JSON parsing is handled with `grep`, `sed`, and `awk` (all standard Unix tools).

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

**Dependencies:** `curl` only (uses `grep`/`sed`/`awk` for JSON — no `jq`)

**First run:** If `.env` is missing and a TTY is attached, an interactive onboarding wizard runs automatically and creates `.env`. In non-interactive/CRON mode the wizard is skipped and a warning is printed.

**Configuration:** `.env` file in the script's directory (created by wizard or manually):
```
API_KEY=your_key_here
EMAIL=you@example.com            # optional — analytics report sent after each run
MAIL_CMD=mail                    # optional — auto-detected if empty (mail or sendmail)
BACKUP_DIR=/path/to/backups      # optional, default: <script_dir>/backups
OVERWRITE=false                  # optional, default: false
OUTPUT_DIR=/path/to/output       # optional — ignored when OVERWRITE=true
EXCLUDE_EXT=JPG,PNG              # optional, case-sensitive
LOSSY=1                          # optional, default: 1  (0=lossless, 1=lossy, 2=glossy)
KEEP_EXIF=0                      # optional, default: 0  (1=keep)
CONCURRENCY=4                    # optional, default: 4
API_WAIT=25                      # optional, default: 25 (seconds, 1-30)
```

**Configuration hierarchy:** CLI flags > `.env` file > internal script defaults.

## Architecture

The script is structured in 21 clearly labelled sections inside a single file:

1. **Configuration defaults** — UPPERCASE globals with hardcoded defaults
2. **Terminal colors** — TTY-conditional ANSI colors
3. **Logging helpers** — `log_info/success/warn/error()`, all write to stderr
4. **Help** — `show_help()` extracts the header comment block from the script itself
5. **File utilities** — `get_file_size()`, `get_file_extension()`, `get_md5()`, `format_bytes()`
6. **JSON parsing** — `_json_first()`, `_json_status_code/message()`, `_json_str()`, `_json_num()` — no jq
7. **Exclusion check** — `is_excluded()`: case-sensitive extension match against `EXCLUDE_EXT`
8. **`.splog` management** — `splog_prune()`, `splog_has_entry()`, `splog_write_entry()`
9. **Backup management** — `get_backup_path()`, `backup_file()`, `verify_backup()`
10. **Progress tracking** — `increment_counter()` (atomic O_APPEND), `show_progress()`
11. **Email report** — `_detect_mail_cmd()`, `send_email_report()`: plain-text dashboard via `mail`/`sendmail`
12. **API interaction** — `download_file()`, `optimize_single_file()`, `process_file()`
13. **Analytics Dashboard** — `show_dashboard()`: file counts, space savings (MB/GB), skipped folders; triggers email on exit
14. **Restore** — `do_restore()`: copies backup mirror → source, writes `restore_audit.log`
15. **Purge** — `do_purge_backups()`: age + `.splog` gated backup deletion
16. **Onboarding wizard** — `run_wizard()`: interactive first-run setup, creates `.env`
17. **Load `.env` + argument parsing** — sources `.env`, then `while/case` CLI loop (supports `-k VAL` and `--key=VAL` forms)
18. **Dependency check** — curl required; exits with code 3 if missing
19. **Restore / Purge dispatch** — early exit for `--restore` and `--purge-backups` modes
20. **Validation** — range checks, mutex flag checks, output/backup dir setup
21. **Main** — file discovery, per-dir `.splog` pruning, FIFO semaphore, parallel dispatch

### Onboarding wizard

Runs automatically on first use (no `.env`) when a TTY is present. Skipped silently in CRON/non-interactive mode. Prompts for:

| Section | Questions |
|---------|-----------|
| Required | API key (loops until non-empty) |
| Compression | Lossy mode `[1]`, keep EXIF `[N]` |
| Processing | Parallel workers `[4]`, API wait seconds `[25]` |
| Output | Overwrite originals `[N]`; if no → custom output dir (Enter = default `<source>/optimized/`) |
| Output | Extensions to exclude |
| Backup | Enable backups `[Y]`; if yes → backup directory `[<script_dir>/backups]` |
| Email | Email address (Enter to skip); if given → auto-detects `mail`/`sendmail`, optional test send |

All values default on Enter. Writes a fully commented `.env`. Re-run wizard by deleting `.env`.

### JSON parsing (no jq)

Section 6 provides targeted parsers for the ShortPixel API response format using only `awk`, `grep`, and `sed`:

- `_json_first JSON` — collapses newlines, extracts the first `{...}` object from an array (or passes through plain objects)
- `_json_status_code OBJ` — extracts `Status.Code` from `"Status":{"Code":"X",...}`
- `_json_status_message OBJ` — extracts `Status.Message`
- `_json_str OBJ KEY` — extracts a top-level string field value
- `_json_num OBJ KEY` — extracts a top-level numeric field value

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

- **Default** (no `--output-dir`, `OVERWRITE=false`): `<source_dir>/optimized/<filename>` — optimized file lands in an `optimized/` subfolder inside the same directory as the source
- **`--output-dir DIR`** / **`OUTPUT_DIR=`** in `.env`: all optimized files go flat into `DIR/`
- **`--overwrite`** / **`OVERWRITE=true`** in `.env`: replaces the source file in-place (backup is created first)

`--overwrite` and `--output-dir` are mutually exclusive. `optimized/` subdirectories are automatically excluded from recursive file discovery.

### ShortPixel API behaviour

- Endpoint: `POST https://api.shortpixel.com/v2/post-reducer.php` (multipart form)
- `file_paths` must use a simple key (e.g. `"file1"`) that matches the form field name
- Files with spaces/special chars in their path must be copied to a temp file first — curl's `-F field=@path` cannot handle spaces in the path portion
- The API returns a JSON **array** on success, but a plain **object** for global errors; `_json_first()` normalises both to a single object before parsing
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
- Source savings: original total vs current total vs bytes saved (MB/GB, 2 decimals)
- Total system footprint: current source + backup folder size

If `EMAIL` is set in `.env`, the dashboard is also sent as plain text email via `mail` or `sendmail` (auto-detected, or set `MAIL_CMD` explicitly).
