#!/usr/bin/env bash
###############################################################################
# chromeos_research_audit.sh — Stage 3 of 4
# YeahSo Network · Scout Satellite · Research Files Inventory
#
# Run inside Crostini (ChromeOS Linux container).
# Scans for research-relevant files: documents, notes, code projects,
# downloads, media, archives, and configuration data across the user's
# home directory and accessible mounts.
#
# Produces JSON manifest, SHA256 checksum, human-readable report, error log.
#
# Standing rules:
#   - Air-gap first — no network transfers, no cloud sync, no SSH
#   - USB Lifeboat only for data movement
#   - No AI processing on satellite
#   - All credentials entered offline by DGANY only
###############################################################################
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
STAGING_DIR="$HOME/yeahso_audit_staging"
MODULE="module_03_research_files"
JSON_OUT="$STAGING_DIR/${MODULE}.json"
SHA_OUT="$STAGING_DIR/${MODULE}.sha256"
TXT_OUT="$STAGING_DIR/${MODULE}.txt"
ERR_LOG="$STAGING_DIR/${MODULE}_errors.log"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HOSTNAME_VAL="$(hostname 2>/dev/null || echo "chromeos-device")"
VERSION="1.0"

# ── Helpers ──────────────────────────────────────────────────────────────────
mkdir -p "$STAGING_DIR"
: > "$ERR_LOG"

log_err() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ERROR: $*" >> "$ERR_LOG"
}

safe_run() {
    local label="$1"; shift
    local output
    if output=$("$@" 2>&1); then
        echo "$output"
    else
        log_err "$label — command failed: $* — $output"
        echo ""
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Convert bytes to human-readable
human_size() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.1f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "  YeahSo Network — Scout Satellite Research Audit (Stage 3)"
echo "  Timestamp : $TIMESTAMP"
echo "  Output    : $STAGING_DIR/"
echo "═══════════════════════════════════════════════════════════════"
echo ""

###############################################################################
# Define scan locations
###############################################################################
SCAN_DIRS=("$HOME")

# Add ChromeOS shared paths if accessible
for extra_dir in \
    "/mnt/chromeos/MyFiles" \
    "/mnt/chromeos/GoogleDrive" \
    "/mnt/chromeos/removable" \
    "$HOME/Downloads" \
    "$HOME/Documents" \
    "$HOME/Desktop"; do
    if [ -d "$extra_dir" ] && [[ "$extra_dir" != "$HOME" ]]; then
        SCAN_DIRS+=("$extra_dir")
    fi
done

echo "  Scan locations: ${SCAN_DIRS[*]}"
echo ""

###############################################################################
# 1. Documents (PDF, DOCX, ODT, TXT, RTF, EPUB, XLSX, PPTX, CSV)
###############################################################################
echo "[1/7] Scanning for documents..."

DOCS_JSON="["
DOCS_FIRST=true
DOCS_COUNT=0
DOCS_TOTAL_BYTES=0

scan_file_type() {
    local category="$1"
    local extensions="$2"  # pipe-separated: "pdf|docx|odt"
    local json_var_name="$3"
    local count=0
    local total_bytes=0
    local json_result="["
    local first=true

    for scan_dir in "${SCAN_DIRS[@]}"; do
        [ -d "$scan_dir" ] || continue
        while IFS= read -r -d '' filepath; do
            [ -f "$filepath" ] || continue
            local filename basename_f size_bytes mod_date
            basename_f=$(basename "$filepath")
            size_bytes=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
            mod_date=$(stat -c%Y "$filepath" 2>/dev/null || echo 0)
            mod_date_iso=$(date -u -d "@$mod_date" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
            ext="${basename_f##*.}"
            ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

            $first || json_result+=","
            first=false
            json_result+="{\"path\":\"$(json_escape "$filepath")\",\"name\":\"$(json_escape "$basename_f")\",\"ext\":\"$ext_lower\",\"size_bytes\":$size_bytes,\"modified\":\"$mod_date_iso\"}"
            count=$((count + 1))
            total_bytes=$((total_bytes + size_bytes))

            # Cap at 500 entries per category to avoid huge manifests
            if [ $count -ge 500 ]; then
                log_err "$category — capped at 500 files, more may exist"
                break 2
            fi
        done < <(find "$scan_dir" -maxdepth 6 -type f \( $(echo "$extensions" | sed 's/|/ -o -iname *./g;s/^/-iname *./' ) \) -print0 2>/dev/null)
    done

    json_result+="]"
    # Return count, total_bytes, and json via stdout (pipe-separated)
    echo "${count}|${total_bytes}|${json_result}"
}

DOC_RESULT=$(scan_file_type "documents" "pdf|docx|doc|odt|txt|rtf|epub|md|tex|org" "DOCS")
DOCS_COUNT=$(echo "$DOC_RESULT" | cut -d'|' -f1)
DOCS_TOTAL_BYTES=$(echo "$DOC_RESULT" | cut -d'|' -f2)
DOCS_JSON=$(echo "$DOC_RESULT" | cut -d'|' -f3-)
DOCS_SIZE_HUMAN=$(human_size "$DOCS_TOTAL_BYTES")
echo "  Documents: $DOCS_COUNT files ($DOCS_SIZE_HUMAN)"

###############################################################################
# 2. Spreadsheets & Data Files
###############################################################################
echo "[2/7] Scanning for spreadsheets & data files..."

DATA_RESULT=$(scan_file_type "data_files" "xlsx|xls|csv|tsv|ods|json|xml|yaml|yml|sqlite|db" "DATA")
DATA_COUNT=$(echo "$DATA_RESULT" | cut -d'|' -f1)
DATA_TOTAL_BYTES=$(echo "$DATA_RESULT" | cut -d'|' -f2)
DATA_JSON=$(echo "$DATA_RESULT" | cut -d'|' -f3-)
DATA_SIZE_HUMAN=$(human_size "$DATA_TOTAL_BYTES")
echo "  Data files: $DATA_COUNT files ($DATA_SIZE_HUMAN)"

###############################################################################
# 3. Presentations & Slides
###############################################################################
echo "[3/7] Scanning for presentations..."

PRES_RESULT=$(scan_file_type "presentations" "pptx|ppt|odp|key" "PRES")
PRES_COUNT=$(echo "$PRES_RESULT" | cut -d'|' -f1)
PRES_TOTAL_BYTES=$(echo "$PRES_RESULT" | cut -d'|' -f2)
PRES_JSON=$(echo "$PRES_RESULT" | cut -d'|' -f3-)
PRES_SIZE_HUMAN=$(human_size "$PRES_TOTAL_BYTES")
echo "  Presentations: $PRES_COUNT files ($PRES_SIZE_HUMAN)"

###############################################################################
# 4. Code Projects & Repositories
###############################################################################
echo "[4/7] Scanning for code projects..."

CODE_PROJECTS_JSON="["
CODE_FIRST=true
CODE_COUNT=0

for scan_dir in "${SCAN_DIRS[@]}"; do
    [ -d "$scan_dir" ] || continue
    # Find git repositories
    while IFS= read -r git_dir; do
        [ -d "$git_dir" ] || continue
        project_dir=$(dirname "$git_dir")
        project_name=$(basename "$project_dir")
        project_size=$(du -sb "$project_dir" 2>/dev/null | awk '{print $1}')
        [ -z "$project_size" ] && project_size=0

        # Get primary language by file extension count
        primary_lang="unknown"
        if [ -d "$project_dir/src" ] || [ -d "$project_dir/lib" ]; then
            top_ext=$(find "$project_dir" -maxdepth 4 -type f -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.rb' -o -name '*.cpp' -o -name '*.c' 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
            [ -n "$top_ext" ] && primary_lang="$top_ext"
        fi

        # Last commit date
        last_commit=$(git -C "$project_dir" log -1 --format="%aI" 2>/dev/null || echo "unknown")

        # Remote URL
        remote_url=$(git -C "$project_dir" remote get-url origin 2>/dev/null || echo "none")

        $CODE_FIRST || CODE_PROJECTS_JSON+=","
        CODE_FIRST=false
        CODE_PROJECTS_JSON+="{\"name\":\"$(json_escape "$project_name")\",\"path\":\"$(json_escape "$project_dir")\",\"size_bytes\":$project_size,\"primary_language\":\"$(json_escape "$primary_lang")\",\"last_commit\":\"$(json_escape "$last_commit")\",\"remote\":\"$(json_escape "$remote_url")\"}"
        CODE_COUNT=$((CODE_COUNT + 1))

        [ $CODE_COUNT -ge 100 ] && break
    done < <(find "$scan_dir" -maxdepth 5 -type d -name ".git" 2>/dev/null)
done
CODE_PROJECTS_JSON+="]"
echo "  Code projects (git repos): $CODE_COUNT"

###############################################################################
# 5. Media Files (images, audio, video)
###############################################################################
echo "[5/7] Scanning for media files..."

# Images
IMG_RESULT=$(scan_file_type "images" "jpg|jpeg|png|gif|bmp|svg|webp|ico|tiff|heic" "IMG")
IMG_COUNT=$(echo "$IMG_RESULT" | cut -d'|' -f1)
IMG_TOTAL_BYTES=$(echo "$IMG_RESULT" | cut -d'|' -f2)
IMG_JSON=$(echo "$IMG_RESULT" | cut -d'|' -f3-)
IMG_SIZE_HUMAN=$(human_size "$IMG_TOTAL_BYTES")

# Audio
AUDIO_RESULT=$(scan_file_type "audio" "mp3|wav|flac|ogg|m4a|aac|wma" "AUDIO")
AUDIO_COUNT=$(echo "$AUDIO_RESULT" | cut -d'|' -f1)
AUDIO_TOTAL_BYTES=$(echo "$AUDIO_RESULT" | cut -d'|' -f2)
AUDIO_JSON=$(echo "$AUDIO_RESULT" | cut -d'|' -f3-)
AUDIO_SIZE_HUMAN=$(human_size "$AUDIO_TOTAL_BYTES")

# Video
VIDEO_RESULT=$(scan_file_type "video" "mp4|mkv|avi|mov|wmv|flv|webm" "VIDEO")
VIDEO_COUNT=$(echo "$VIDEO_RESULT" | cut -d'|' -f1)
VIDEO_TOTAL_BYTES=$(echo "$VIDEO_RESULT" | cut -d'|' -f2)
VIDEO_JSON=$(echo "$VIDEO_RESULT" | cut -d'|' -f3-)
VIDEO_SIZE_HUMAN=$(human_size "$VIDEO_TOTAL_BYTES")

echo "  Images: $IMG_COUNT ($IMG_SIZE_HUMAN), Audio: $AUDIO_COUNT ($AUDIO_SIZE_HUMAN), Video: $VIDEO_COUNT ($VIDEO_SIZE_HUMAN)"

###############################################################################
# 6. Archives & Downloads
###############################################################################
echo "[6/7] Scanning for archives..."

ARCHIVE_RESULT=$(scan_file_type "archives" "zip|tar|gz|bz2|xz|7z|rar|tgz|tar.gz" "ARCHIVE")
ARCHIVE_COUNT=$(echo "$ARCHIVE_RESULT" | cut -d'|' -f1)
ARCHIVE_TOTAL_BYTES=$(echo "$ARCHIVE_RESULT" | cut -d'|' -f2)
ARCHIVE_JSON=$(echo "$ARCHIVE_RESULT" | cut -d'|' -f3-)
ARCHIVE_SIZE_HUMAN=$(human_size "$ARCHIVE_TOTAL_BYTES")
echo "  Archives: $ARCHIVE_COUNT files ($ARCHIVE_SIZE_HUMAN)"

# Downloads directory summary
DOWNLOADS_COUNT=0
DOWNLOADS_SIZE="0"
if [ -d "$HOME/Downloads" ]; then
    DOWNLOADS_COUNT=$(find "$HOME/Downloads" -maxdepth 1 -type f 2>/dev/null | wc -l)
    DOWNLOADS_SIZE=$(du -sh "$HOME/Downloads" 2>/dev/null | awk '{print $1}')
fi

###############################################################################
# 7. Disk Usage Summary
###############################################################################
echo "[7/7] Computing disk usage summary..."

HOME_SIZE_BYTES=$(du -sb "$HOME" 2>/dev/null | awk '{print $1}')
[ -z "$HOME_SIZE_BYTES" ] && HOME_SIZE_BYTES=0
HOME_SIZE_HUMAN=$(human_size "$HOME_SIZE_BYTES")

# Top-level directory sizes
DIR_BREAKDOWN_JSON="["
DIR_FIRST=true
while IFS=$'\t' read -r size dir_path; do
    [ -z "$dir_path" ] && continue
    dir_name=$(basename "$dir_path")
    $DIR_FIRST || DIR_BREAKDOWN_JSON+=","
    DIR_FIRST=false
    DIR_BREAKDOWN_JSON+="{\"directory\":\"$(json_escape "$dir_name")\",\"size_bytes\":$size}"
done < <(du -sb "$HOME"/*/ 2>/dev/null | sort -rn | head -20)
DIR_BREAKDOWN_JSON+="]"

# Total files by extension (top 20)
EXT_BREAKDOWN_JSON="["
EXT_FIRST=true
while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    ext=$(echo "$line" | awk '{print $2}')
    [ -z "$ext" ] && continue
    $EXT_FIRST || EXT_BREAKDOWN_JSON+=","
    EXT_FIRST=false
    EXT_BREAKDOWN_JSON+="{\"extension\":\"$(json_escape "$ext")\",\"count\":$count}"
done < <(find "$HOME" -maxdepth 5 -type f -name '*.*' 2>/dev/null | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -rn | head -20)
EXT_BREAKDOWN_JSON+="]"

echo "  Home directory: $HOME_SIZE_HUMAN"
echo ""
echo "Assembling JSON manifest..."

###############################################################################
# Assemble JSON Manifest
###############################################################################
cat > "$JSON_OUT" <<ENDJSON
{
  "yeahso_network": true,
  "scout_device": true,
  "audit_module": "research_files",
  "version": "$VERSION",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(json_escape "$HOSTNAME_VAL")",
  "collection_method": "Bash audit script via Crostini",
  "stage": "3 of 4",
  "scan_locations": [$(printf '"%s",' "${SCAN_DIRS[@]}" | sed 's/,$//')],
  "documents": {
    "count": $DOCS_COUNT,
    "total_size": "$(json_escape "$DOCS_SIZE_HUMAN")",
    "total_bytes": $DOCS_TOTAL_BYTES,
    "files": $DOCS_JSON
  },
  "data_files": {
    "count": $DATA_COUNT,
    "total_size": "$(json_escape "$DATA_SIZE_HUMAN")",
    "total_bytes": $DATA_TOTAL_BYTES,
    "files": $DATA_JSON
  },
  "presentations": {
    "count": $PRES_COUNT,
    "total_size": "$(json_escape "$PRES_SIZE_HUMAN")",
    "total_bytes": $PRES_TOTAL_BYTES,
    "files": $PRES_JSON
  },
  "code_projects": {
    "count": $CODE_COUNT,
    "repositories": $CODE_PROJECTS_JSON
  },
  "media": {
    "images": {
      "count": $IMG_COUNT,
      "total_size": "$(json_escape "$IMG_SIZE_HUMAN")",
      "total_bytes": $IMG_TOTAL_BYTES,
      "files": $IMG_JSON
    },
    "audio": {
      "count": $AUDIO_COUNT,
      "total_size": "$(json_escape "$AUDIO_SIZE_HUMAN")",
      "total_bytes": $AUDIO_TOTAL_BYTES,
      "files": $AUDIO_JSON
    },
    "video": {
      "count": $VIDEO_COUNT,
      "total_size": "$(json_escape "$VIDEO_SIZE_HUMAN")",
      "total_bytes": $VIDEO_TOTAL_BYTES,
      "files": $VIDEO_JSON
    }
  },
  "archives": {
    "count": $ARCHIVE_COUNT,
    "total_size": "$(json_escape "$ARCHIVE_SIZE_HUMAN")",
    "total_bytes": $ARCHIVE_TOTAL_BYTES,
    "files": $ARCHIVE_JSON
  },
  "downloads": {
    "file_count": $DOWNLOADS_COUNT,
    "total_size": "$(json_escape "$DOWNLOADS_SIZE")"
  },
  "disk_usage": {
    "home_total_bytes": $HOME_SIZE_BYTES,
    "home_total_size": "$(json_escape "$HOME_SIZE_HUMAN")",
    "directory_breakdown": $DIR_BREAKDOWN_JSON,
    "extension_breakdown": $EXT_BREAKDOWN_JSON
  }
}
ENDJSON

###############################################################################
# Generate SHA256 Checksum
###############################################################################
sha256sum "$JSON_OUT" > "$SHA_OUT"
echo "  SHA256 checksum written to $SHA_OUT"

###############################################################################
# Generate Human-Readable Report
###############################################################################
cat > "$TXT_OUT" <<ENDTXT
═══════════════════════════════════════════════════════════════════════════════
  YeahSo Network — Scout Satellite Research Files Audit Report
  Stage 3 of 4: Research Files
═══════════════════════════════════════════════════════════════════════════════

  Generated : $TIMESTAMP
  Hostname  : $HOSTNAME_VAL
  Module    : research_files v$VERSION

───────────────────────────────────────────────────────────────────────────────
  1. Documents
───────────────────────────────────────────────────────────────────────────────
  Count         : $DOCS_COUNT files
  Total Size    : $DOCS_SIZE_HUMAN

───────────────────────────────────────────────────────────────────────────────
  2. Data Files (spreadsheets, databases, structured data)
───────────────────────────────────────────────────────────────────────────────
  Count         : $DATA_COUNT files
  Total Size    : $DATA_SIZE_HUMAN

───────────────────────────────────────────────────────────────────────────────
  3. Presentations
───────────────────────────────────────────────────────────────────────────────
  Count         : $PRES_COUNT files
  Total Size    : $PRES_SIZE_HUMAN

───────────────────────────────────────────────────────────────────────────────
  4. Code Projects
───────────────────────────────────────────────────────────────────────────────
  Git Repos     : $CODE_COUNT

───────────────────────────────────────────────────────────────────────────────
  5. Media Files
───────────────────────────────────────────────────────────────────────────────
  Images        : $IMG_COUNT ($IMG_SIZE_HUMAN)
  Audio         : $AUDIO_COUNT ($AUDIO_SIZE_HUMAN)
  Video         : $VIDEO_COUNT ($VIDEO_SIZE_HUMAN)

───────────────────────────────────────────────────────────────────────────────
  6. Archives
───────────────────────────────────────────────────────────────────────────────
  Count         : $ARCHIVE_COUNT files
  Total Size    : $ARCHIVE_SIZE_HUMAN

───────────────────────────────────────────────────────────────────────────────
  7. Downloads
───────────────────────────────────────────────────────────────────────────────
  Files         : $DOWNLOADS_COUNT
  Total Size    : $DOWNLOADS_SIZE

───────────────────────────────────────────────────────────────────────────────
  8. Disk Usage
───────────────────────────────────────────────────────────────────────────────
  Home Total    : $HOME_SIZE_HUMAN

───────────────────────────────────────────────────────────────────────────────
  9. Errors
───────────────────────────────────────────────────────────────────────────────
$(cat "$ERR_LOG" 2>/dev/null || echo "  No errors logged.")

═══════════════════════════════════════════════════════════════════════════════
  End of Stage 3 Report — Transfer via Lifeboat USB to Mothership
═══════════════════════════════════════════════════════════════════════════════
ENDTXT

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Audit Complete — Stage 3 of 4"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Output files:"
echo "    JSON manifest  : $JSON_OUT"
echo "    SHA256 sum     : $SHA_OUT"
echo "    Readable report: $TXT_OUT"
echo "    Error log      : $ERR_LOG"
echo ""
echo "  Next: Run chromeos_android_audit.sh for Stage 4 (Android data)"
echo "═══════════════════════════════════════════════════════════════"
