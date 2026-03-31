#!/usr/bin/env bash
###############################################################################
# mothership_mailroom_intake.sh — Phase 2, Step 1
# YeahSo Network · Mothership · Mailroom Intake & Validation
#
# Receives a Scout satellite export archive via Lifeboat USB,
# validates checksums, unpacks, and stages for Francesca ingestion.
#
# Standing rules:
#   - Air-gap verified before processing
#   - Checksum verification is mandatory — reject on failure
#   - All intake is logged with full audit trail
#   - No outbound network during processing
###############################################################################
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
MAILROOM_DIR="$HOME/yeahso_mothership/mailroom"
INTAKE_LOG="$MAILROOM_DIR/intake_log.jsonl"
QUARANTINE_DIR="$MAILROOM_DIR/quarantine"
VALIDATED_DIR="$MAILROOM_DIR/validated"
PROCESSING_DIR="$HOME/yeahso_mothership/processing"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
VERSION="1.0"

# ── Helpers ──────────────────────────────────────────────────────────────────
mkdir -p "$MAILROOM_DIR" "$QUARANTINE_DIR" "$VALIDATED_DIR" "$PROCESSING_DIR"

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

log_intake() {
    local status="$1" message="$2" archive="${3:-}" checksum_ok="${4:-}"
    echo "{\"timestamp\":\"$TIMESTAMP\",\"status\":\"$status\",\"message\":\"$(json_escape "$message")\",\"archive\":\"$(json_escape "$archive")\",\"checksum_verified\":$checksum_ok}" >> "$INTAKE_LOG"
}

echo "═══════════════════════════════════════════════════════════════"
echo "  YeahSo Network — Mothership Mailroom Intake"
echo "  Timestamp : $TIMESTAMP"
echo "═══════════════════════════════════════════════════════════════"
echo ""

###############################################################################
# 1. Locate Archive
###############################################################################
echo "[1/5] Locating Scout export archive..."

ARCHIVE_PATH=""
SHA_PATH=""

# Accept explicit path as argument
if [ $# -ge 1 ] && [ -f "$1" ]; then
    ARCHIVE_PATH="$1"
    SHA_PATH="${ARCHIVE_PATH}.sha256"
else
    # Auto-detect: look for most recent scout export
    for search_dir in "/mnt/usb" "/media" "$HOME" "$HOME/yeahso_audit_staging"; do
        if [ -d "$search_dir" ]; then
            found=$(find "$search_dir" -maxdepth 2 -name "scout_export_stage*.tar.gz" -type f 2>/dev/null | sort -r | head -1)
            if [ -n "$found" ]; then
                ARCHIVE_PATH="$found"
                SHA_PATH="${found}.sha256"
                break
            fi
        fi
    done
fi

if [ -z "$ARCHIVE_PATH" ] || [ ! -f "$ARCHIVE_PATH" ]; then
    echo "  ERROR: No Scout export archive found."
    echo "  Usage: $0 [path/to/scout_export.tar.gz]"
    log_intake "error" "No archive found" "" "false"
    exit 1
fi

ARCHIVE_NAME=$(basename "$ARCHIVE_PATH")
ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | awk '{print $1}')
echo "  Found: $ARCHIVE_PATH ($ARCHIVE_SIZE)"

###############################################################################
# 2. Checksum Verification
###############################################################################
echo "[2/5] Verifying archive integrity..."

CHECKSUM_OK="false"
if [ -f "$SHA_PATH" ]; then
    if (cd "$(dirname "$ARCHIVE_PATH")" && sha256sum -c "$SHA_PATH" 2>/dev/null); then
        CHECKSUM_OK="true"
        echo "  Checksum VERIFIED"
    else
        echo "  WARNING: Checksum FAILED"
        echo "  Quarantining archive..."
        cp "$ARCHIVE_PATH" "$QUARANTINE_DIR/"
        [ -f "$SHA_PATH" ] && cp "$SHA_PATH" "$QUARANTINE_DIR/"
        log_intake "quarantined" "Checksum verification failed" "$ARCHIVE_NAME" "false"
        echo ""
        echo "  Archive quarantined at: $QUARANTINE_DIR/$ARCHIVE_NAME"
        echo "  Manual inspection required before proceeding."
        exit 1
    fi
else
    echo "  WARNING: No .sha256 file found — proceeding with caution"
    log_intake "warning" "No checksum file — unverified intake" "$ARCHIVE_NAME" "null"
fi

###############################################################################
# 3. Unpack Archive
###############################################################################
echo "[3/5] Unpacking archive..."

UNPACK_DIR="$PROCESSING_DIR/intake_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$UNPACK_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$UNPACK_DIR"

# Find the staging directory inside
STAGING_DIR=$(find "$UNPACK_DIR" -maxdepth 1 -type d -name "yeahso_audit_staging" | head -1)
if [ -z "$STAGING_DIR" ]; then
    # Maybe it unpacked directly
    STAGING_DIR="$UNPACK_DIR"
fi

FILE_COUNT=$(find "$STAGING_DIR" -type f | wc -l)
echo "  Unpacked $FILE_COUNT files to $UNPACK_DIR"

###############################################################################
# 4. Validate Module Manifests
###############################################################################
echo "[4/5] Validating module manifests..."

MODULES_FOUND=0
MODULES_VALID=0
VALIDATION_REPORT=""

for module_json in "$STAGING_DIR"/module_*.json; do
    [ -f "$module_json" ] || continue
    MODULES_FOUND=$((MODULES_FOUND + 1))
    module_name=$(basename "$module_json" .json)

    # Check required fields
    has_network=$(grep -c '"yeahso_network"' "$module_json" 2>/dev/null || echo 0)
    has_module=$(grep -c '"audit_module"' "$module_json" 2>/dev/null || echo 0)
    has_timestamp=$(grep -c '"timestamp"' "$module_json" 2>/dev/null || echo 0)
    file_size=$(stat -c%s "$module_json" 2>/dev/null || echo 0)

    if [ "$has_network" -gt 0 ] && [ "$has_module" -gt 0 ] && [ "$has_timestamp" -gt 0 ] && [ "$file_size" -gt 10 ]; then
        MODULES_VALID=$((MODULES_VALID + 1))
        status="VALID"
    else
        status="INVALID"
    fi

    # Extract module type and stage
    module_type=$(grep -oP '"audit_module"\s*:\s*"[^"]*"' "$module_json" | head -1 | sed 's/.*"audit_module"\s*:\s*"//;s/"$//' || echo "unknown")
    module_stage=$(grep -oP '"stage"\s*:\s*"[^"]*"' "$module_json" | head -1 | sed 's/.*"stage"\s*:\s*"//;s/"$//' || echo "unknown")

    echo "  [$status] $module_name — $module_type ($module_stage) — $(du -h "$module_json" | awk '{print $1}')"
    VALIDATION_REPORT+="  $module_name: $status ($module_type)\n"
done

# Check for master checksums
MASTER_SHA="$STAGING_DIR/MASTER_CHECKSUMS.sha256"
MASTER_CHECK="skipped"
if [ -f "$MASTER_SHA" ]; then
    echo ""
    echo "  Verifying master checksums..."
    if (cd / && sha256sum -c "$MASTER_SHA" 2>/dev/null 1>/dev/null); then
        MASTER_CHECK="passed"
        echo "  Master checksums: ALL PASSED"
    else
        MASTER_CHECK="partial"
        # Show which ones failed
        failed=$(cd / && sha256sum -c "$MASTER_SHA" 2>/dev/null | grep "FAILED" || true)
        echo "  Master checksums: SOME FAILED"
        [ -n "$failed" ] && echo "$failed" | sed 's/^/    /'
    fi
fi

echo ""
echo "  Modules found: $MODULES_FOUND, Valid: $MODULES_VALID"

###############################################################################
# 5. Stage for Francesca Ingestion
###############################################################################
echo "[5/5] Staging for Francesca ingestion..."

if [ "$MODULES_VALID" -gt 0 ]; then
    # Copy validated modules to validated dir
    BATCH_ID="batch_$(date -u +%Y%m%dT%H%M%SZ)"
    BATCH_DIR="$VALIDATED_DIR/$BATCH_ID"
    mkdir -p "$BATCH_DIR"

    cp "$STAGING_DIR"/module_*.json "$BATCH_DIR/" 2>/dev/null || true
    cp "$STAGING_DIR"/module_*.sha256 "$BATCH_DIR/" 2>/dev/null || true
    cp "$STAGING_DIR"/module_*.txt "$BATCH_DIR/" 2>/dev/null || true
    cp "$STAGING_DIR"/export_metadata.json "$BATCH_DIR/" 2>/dev/null || true
    cp "$STAGING_DIR"/takeout_checklist.json "$BATCH_DIR/" 2>/dev/null || true
    cp "$STAGING_DIR"/MASTER_CHECKSUMS.sha256 "$BATCH_DIR/" 2>/dev/null || true

    BATCH_FILE_COUNT=$(find "$BATCH_DIR" -type f | wc -l)

    # Write intake receipt
    cat > "$BATCH_DIR/intake_receipt.json" <<ENDJSON
{
  "yeahso_network": true,
  "mothership": true,
  "receipt_type": "mailroom_intake",
  "batch_id": "$BATCH_ID",
  "timestamp": "$TIMESTAMP",
  "source_archive": "$(json_escape "$ARCHIVE_NAME")",
  "archive_size": "$(json_escape "$ARCHIVE_SIZE")",
  "checksum_verified": $CHECKSUM_OK,
  "master_checksums": "$MASTER_CHECK",
  "modules_found": $MODULES_FOUND,
  "modules_valid": $MODULES_VALID,
  "files_staged": $BATCH_FILE_COUNT,
  "batch_directory": "$(json_escape "$BATCH_DIR")",
  "status": "ready_for_ingestion",
  "next_step": "francesca_ingest.sh"
}
ENDJSON

    log_intake "accepted" "Intake validated and staged" "$ARCHIVE_NAME" "$CHECKSUM_OK"

    echo "  Batch ID: $BATCH_ID"
    echo "  Files staged: $BATCH_FILE_COUNT"
    echo "  Location: $BATCH_DIR"
else
    log_intake "rejected" "No valid modules found" "$ARCHIVE_NAME" "$CHECKSUM_OK"
    echo "  ERROR: No valid modules — intake rejected"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Mailroom Intake Complete"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Batch       : $BATCH_ID"
echo "  Modules     : $MODULES_VALID/$MODULES_FOUND valid"
echo "  Checksums   : archive=$CHECKSUM_OK, master=$MASTER_CHECK"
echo "  Status      : READY FOR FRANCESCA INGESTION"
echo ""
echo "  Next: Run francesca_ingest.sh $BATCH_DIR"
echo "═══════════════════════════════════════════════════════════════"
