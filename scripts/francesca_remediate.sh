#!/usr/bin/env bash
###############################################################################
# francesca_remediate.sh — Phase 3, Tool 2
# YeahSo Network · Mothership · Automated Remediation Engine
#
# Reads the Francesca gap analysis and generates targeted fix scripts
# for each identified gap. Can run fixes automatically or produce
# a remediation plan for manual execution.
#
# Usage:
#   francesca_remediate.sh plan        Show remediation plan (dry run)
#   francesca_remediate.sh run         Execute all safe remediations
#   francesca_remediate.sh run <id>    Execute a specific remediation
###############################################################################
set -uo pipefail

KB_DIR="$HOME/yeahso_mothership/francesca_kb"
GAPS="$KB_DIR/francesca_gap_analysis.json"
REMEDIATION_DIR="$HOME/yeahso_mothership/remediation"
REMEDIATION_LOG="$REMEDIATION_DIR/remediation_log.jsonl"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$REMEDIATION_DIR"

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

log_remediation() {
    local gap_id="$1" action="$2" result="$3"
    echo "{\"timestamp\":\"$TIMESTAMP\",\"gap\":\"$gap_id\",\"action\":\"$(json_escape "$action")\",\"result\":\"$(json_escape "$result")\"}" >> "$REMEDIATION_LOG"
}

[ -f "$GAPS" ] || { echo "ERROR: Gap analysis not found. Run francesca_ingest.sh first."; exit 1; }

###############################################################################
# Remediation Registry — maps gap fields to fix strategies
###############################################################################

# Each remediation function returns:
#   0 = fixable automatically
#   1 = requires manual intervention
#   2 = informational only

remediate_chromeos_version() {
    local mode="$1"
    echo "  GAP: chromeos_version — ChromeOS version not detected"
    echo "  FIX: Run audit on physical Scout device (not VM)"
    echo "  CMD: bash scripts/chromeos_scout_audit.sh"
    if [ "$mode" = "run" ]; then
        echo "  STATUS: MANUAL — requires physical device access"
        log_remediation "chromeos_version" "manual_required" "Cannot fix in VM — needs physical Scout"
    fi
    return 1
}

remediate_device_model() {
    local mode="$1"
    echo "  GAP: device_model — Device model not accessible"
    echo "  FIX: Run on physical device with DMI access, or manually set"
    if [ "$mode" = "run" ]; then
        # Try alternative detection methods
        local model=""
        model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null || true)
        [ -z "$model" ] && model=$(dmidecode -s system-product-name 2>/dev/null || true)
        if [ -n "$model" ]; then
            echo "  STATUS: DETECTED — $model"
            log_remediation "device_model" "auto_detected" "$model"
            return 0
        fi
        echo "  STATUS: MANUAL — not detectable in this environment"
        log_remediation "device_model" "manual_required" "DMI not accessible"
    fi
    return 1
}

remediate_bookmarks() {
    local mode="$1"
    echo "  GAP: bookmarks — No bookmarks found"
    echo "  FIX: Ensure Chrome profile is accessible from Crostini"
    echo "  ALT: Export bookmarks manually via Chrome > Bookmarks > Export"
    echo "  CMD: cp /mnt/chromeos/MyFiles/Downloads/bookmarks.html ~/yeahso_audit_staging/"
    if [ "$mode" = "run" ]; then
        # Check if Chrome profile has become accessible
        for bk_dir in "$HOME/.config/google-chrome/Default" "$HOME/.config/chromium/Default"; do
            if [ -f "$bk_dir/Bookmarks" ]; then
                echo "  STATUS: FOUND — $bk_dir/Bookmarks"
                log_remediation "bookmarks" "profile_found" "$bk_dir/Bookmarks"
                return 0
            fi
        done
        echo "  STATUS: MANUAL — Chrome profile not accessible from Crostini"
        log_remediation "bookmarks" "manual_required" "Export bookmarks HTML from Chrome"
    fi
    return 1
}

remediate_history() {
    local mode="$1"
    echo "  GAP: history — No browsing history collected"
    echo "  FIX: Install sqlite3 and ensure Chrome profile access"
    if [ "$mode" = "run" ]; then
        if ! command -v sqlite3 &>/dev/null; then
            echo "  ACTION: Installing sqlite3..."
            if sudo apt-get install -y sqlite3 2>/dev/null; then
                echo "  STATUS: FIXED — sqlite3 installed"
                log_remediation "history" "auto_fixed" "sqlite3 installed via apt"
                return 0
            else
                echo "  STATUS: FAILED — could not install sqlite3"
                log_remediation "history" "install_failed" "apt-get install sqlite3 failed"
                return 1
            fi
        else
            echo "  STATUS: sqlite3 already installed — Chrome profile access needed"
            log_remediation "history" "partial" "sqlite3 present, need Chrome profile"
        fi
    fi
    return 1
}

remediate_saved_passwords() {
    local mode="$1"
    echo "  GAP: saved_passwords — No password metadata collected"
    echo "  FIX: Requires sqlite3 + Chrome profile access (Login Data DB)"
    echo "  NOTE: Only domain metadata is collected — never plaintext passwords"
    if [ "$mode" = "run" ]; then
        echo "  STATUS: MANUAL — same prereqs as history (sqlite3 + profile access)"
        log_remediation "saved_passwords" "manual_required" "Needs sqlite3 + Chrome profile"
    fi
    return 1
}

remediate_android_subsystem() {
    local mode="$1"
    echo "  GAP: android_subsystem — Android/ARC++ not detected"
    echo "  FIX: Enable Google Play Store in ChromeOS settings, then install ADB"
    echo "  CMD: sudo apt-get install android-tools-adb"
    if [ "$mode" = "run" ]; then
        if command -v adb &>/dev/null; then
            echo "  STATUS: ADB already installed — enable ARC++ in ChromeOS settings"
            log_remediation "android_subsystem" "partial" "ADB present, ARC++ not enabled"
        else
            echo "  ACTION: Installing ADB tools..."
            if sudo apt-get install -y android-tools-adb 2>/dev/null; then
                echo "  STATUS: PARTIAL — ADB installed, still need ARC++ enabled"
                log_remediation "android_subsystem" "adb_installed" "ADB installed, ARC++ pending"
                return 0
            else
                echo "  STATUS: MANUAL — install ADB and enable Play Store"
                log_remediation "android_subsystem" "manual_required" "Install ADB + enable ARC++"
            fi
        fi
    fi
    return 1
}

remediate_documents() {
    local mode="$1"
    echo "  GAP: documents — No documents found"
    echo "  FIX: Check shared folders and Google Drive mount"
    echo "  CMD: ls /mnt/chromeos/MyFiles/Documents/ /mnt/chromeos/GoogleDrive/"
    if [ "$mode" = "run" ]; then
        local found=0
        for doc_dir in /mnt/chromeos/MyFiles/Documents /mnt/chromeos/GoogleDrive "$HOME/Documents" "$HOME/Downloads"; do
            if [ -d "$doc_dir" ]; then
                local count
                count=$(find "$doc_dir" -type f \( -iname "*.pdf" -o -iname "*.docx" -o -iname "*.txt" -o -iname "*.md" \) 2>/dev/null | wc -l)
                if [ "$count" -gt 0 ]; then
                    echo "  FOUND: $count documents in $doc_dir"
                    found=$((found + count))
                fi
            fi
        done
        if [ "$found" -gt 0 ]; then
            echo "  STATUS: FOUND $found documents — re-run chromeos_research_audit.sh"
            log_remediation "documents" "found" "$found documents located"
            return 0
        else
            echo "  STATUS: MANUAL — documents may be in Google Drive (Takeout needed)"
            log_remediation "documents" "manual_required" "No local documents found"
        fi
    fi
    return 1
}

remediate_code_projects() {
    local mode="$1"
    echo "  GAP: code_projects — No git repositories found"
    echo "  FIX: Check ~/projects, ~/src, ~/code, or clone repos as needed"
    if [ "$mode" = "run" ]; then
        local repos
        repos=$(find "$HOME" -maxdepth 4 -type d -name ".git" 2>/dev/null | wc -l)
        if [ "$repos" -gt 0 ]; then
            echo "  FOUND: $repos git repos — re-run chromeos_research_audit.sh"
            log_remediation "code_projects" "found" "$repos repos located"
            return 0
        else
            echo "  STATUS: No repos found — clone or create as needed"
            log_remediation "code_projects" "none_found" "No git repos in home"
        fi
    fi
    return 1
}

###############################################################################
# Main
###############################################################################
CMD="${1:-plan}"
TARGET="${2:-all}"

echo "═══════════════════════════════════════════════════════════════"
echo "  YeahSo Network — Francesca Remediation Engine"
echo "  Mode: $CMD | Target: $TARGET"
echo "  Timestamp: $TIMESTAMP"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Parse gaps and run remediations
TOTAL_GAPS=0
AUTO_FIXABLE=0
MANUAL_REQUIRED=0
FIXED=0

# Map of known gap fields to remediation functions
declare -A REMEDIATION_MAP=(
    ["chromeos_version"]="remediate_chromeos_version"
    ["device_model"]="remediate_device_model"
    ["bookmarks"]="remediate_bookmarks"
    ["history"]="remediate_history"
    ["saved_passwords"]="remediate_saved_passwords"
    ["android_subsystem"]="remediate_android_subsystem"
    ["documents"]="remediate_documents"
    ["code_projects"]="remediate_code_projects"
)

# Extract gap fields from the gap analysis JSON
GAP_FIELDS=$(grep -oP '"field"\s*:\s*"[^"]*"' "$GAPS" 2>/dev/null | sed 's/"field"\s*:\s*"//;s/"$//')

while IFS= read -r field; do
    [ -z "$field" ] && continue
    TOTAL_GAPS=$((TOTAL_GAPS + 1))

    if [ "$TARGET" != "all" ] && [ "$TARGET" != "$field" ]; then
        continue
    fi

    echo "── Gap $TOTAL_GAPS: $field ──"
    if [ -n "${REMEDIATION_MAP[$field]+x}" ]; then
        ${REMEDIATION_MAP[$field]} "$CMD"
        result=$?
        if [ $result -eq 0 ]; then
            FIXED=$((FIXED + 1))
        elif [ $result -eq 1 ]; then
            MANUAL_REQUIRED=$((MANUAL_REQUIRED + 1))
        fi
    else
        echo "  No remediation strategy for: $field"
        MANUAL_REQUIRED=$((MANUAL_REQUIRED + 1))
    fi
    echo ""
done <<< "$GAP_FIELDS"

# Write remediation summary
SUMMARY_FILE="$REMEDIATION_DIR/remediation_summary.json"
cat > "$SUMMARY_FILE" <<ENDJSON
{
  "yeahso_network": true,
  "mothership": true,
  "type": "remediation_summary",
  "timestamp": "$TIMESTAMP",
  "mode": "$CMD",
  "total_gaps": $TOTAL_GAPS,
  "auto_fixed": $FIXED,
  "manual_required": $MANUAL_REQUIRED,
  "remaining": $((TOTAL_GAPS - FIXED))
}
ENDJSON

echo "═══════════════════════════════════════════════════════════════"
echo "  Remediation Summary"
echo "═══════════════════════════════════════════════════════════════"
echo "  Total gaps    : $TOTAL_GAPS"
echo "  Auto-fixed    : $FIXED"
echo "  Manual needed : $MANUAL_REQUIRED"
echo "  Remaining     : $((TOTAL_GAPS - FIXED))"
echo "═══════════════════════════════════════════════════════════════"
