#!/usr/bin/env bash
###############################################################################
# francesca_diff.sh — Phase 3, Tool 3
# YeahSo Network · Mothership · Audit Diff & Change Tracker
#
# Compares two Francesca device profiles (or audit snapshots) and reports
# what changed: new packages, removed tools, storage changes, new gaps
# resolved, new gaps introduced, etc.
#
# Usage:
#   francesca_diff.sh                       Compare latest vs previous snapshot
#   francesca_diff.sh <old.json> <new.json> Compare two specific profiles
#   francesca_diff.sh snapshot              Save current KB state as snapshot
#   francesca_diff.sh history               List all snapshots
###############################################################################
set -uo pipefail

KB_DIR="$HOME/yeahso_mothership/francesca_kb"
SNAPSHOTS_DIR="$HOME/yeahso_mothership/snapshots"
DIFF_DIR="$HOME/yeahso_mothership/diffs"
PROFILE="$KB_DIR/francesca_device_profile.json"
GAPS="$KB_DIR/francesca_gap_analysis.json"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TIMESTAMP_COMPACT="$(date -u +"%Y%m%dT%H%M%SZ")"

mkdir -p "$SNAPSHOTS_DIR" "$DIFF_DIR"

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

extract_val() {
    local file="$1" key="$2"
    grep -oP "\"$key\"\\s*:\\s*[\"0-9][^,}]*" "$file" 2>/dev/null | head -1 | sed "s/\"$key\"\\s*:\\s*//;s/\"//g" || echo ""
}

###############################################################################
# Commands
###############################################################################

cmd_snapshot() {
    [ -f "$PROFILE" ] || { echo "ERROR: No device profile to snapshot"; exit 1; }

    local snap_name="snapshot_${TIMESTAMP_COMPACT}"
    local snap_dir="$SNAPSHOTS_DIR/$snap_name"
    mkdir -p "$snap_dir"

    cp "$KB_DIR"/*.json "$snap_dir/" 2>/dev/null || true
    cp "$KB_DIR"/*.txt "$snap_dir/" 2>/dev/null || true

    # Write snapshot metadata
    local gap_count
    gap_count=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$GAPS" 2>/dev/null | sed 's/.*:\s*//' || echo "0")

    cat > "$snap_dir/snapshot_meta.json" <<ENDJSON
{
  "snapshot_id": "$snap_name",
  "timestamp": "$TIMESTAMP",
  "source": "francesca_kb",
  "gap_count": $gap_count,
  "files": $(find "$snap_dir" -type f -name "*.json" -o -name "*.txt" | wc -l)
}
ENDJSON

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Snapshot saved: $snap_name"
    echo "  Location: $snap_dir"
    echo "  Files: $(find "$snap_dir" -type f | wc -l)"
    echo "═══════════════════════════════════════════════════════════════"
}

cmd_history() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Francesca KB — Snapshot History"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local count=0
    for snap_dir in "$SNAPSHOTS_DIR"/snapshot_*/; do
        [ -d "$snap_dir" ] || continue
        count=$((count + 1))
        local snap_name meta_ts gap_count files
        snap_name=$(basename "$snap_dir")
        if [ -f "$snap_dir/snapshot_meta.json" ]; then
            meta_ts=$(extract_val "$snap_dir/snapshot_meta.json" "timestamp")
            gap_count=$(extract_val "$snap_dir/snapshot_meta.json" "gap_count")
            files=$(extract_val "$snap_dir/snapshot_meta.json" "files")
        else
            meta_ts="unknown"
            gap_count="?"
            files=$(find "$snap_dir" -type f | wc -l)
        fi
        echo "  [$count] $snap_name"
        echo "      Time: $meta_ts | Gaps: $gap_count | Files: $files"
    done

    [ $count -eq 0 ] && echo "  No snapshots found. Run: $(basename "$0") snapshot"
    echo ""
}

cmd_diff() {
    local old_profile="$1"
    local new_profile="$2"

    [ -f "$old_profile" ] || { echo "ERROR: Old profile not found: $old_profile"; exit 1; }
    [ -f "$new_profile" ] || { echo "ERROR: New profile not found: $new_profile"; exit 1; }

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Francesca KB — Audit Diff Report"
    echo "  Comparing:"
    echo "    OLD: $old_profile"
    echo "    NEW: $new_profile"
    echo "  Generated: $TIMESTAMP"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local changes=0
    local diff_json="["
    local diff_first=true

    add_change() {
        local field="$1" old_val="$2" new_val="$3" change_type="$4"
        $diff_first || diff_json+=","
        diff_first=false
        diff_json+="{\"field\":\"$(json_escape "$field")\",\"old\":\"$(json_escape "$old_val")\",\"new\":\"$(json_escape "$new_val")\",\"type\":\"$change_type\"}"
        changes=$((changes + 1))
    }

    # Compare key fields
    TRACKED_FIELDS=(
        "chromeos_version"
        "chromeos_channel"
        "model"
        "cpu"
        "ram_gb"
        "storage_local_gb"
        "debian_version"
        "packages_installed"
        "dev_tools_available"
        "docker"
        "detected"
        "android_version"
        "user_apps"
        "system_apps"
        "bookmarks"
        "history_entries"
        "saved_credentials"
        "cookies"
        "default_search"
        "sync_enabled"
        "documents"
        "data_files"
        "code_projects"
        "images"
        "audio"
        "video"
        "archives"
        "home_directory_size"
    )

    echo "── Field-by-Field Comparison ──"
    echo ""

    for field in "${TRACKED_FIELDS[@]}"; do
        local old_val new_val
        old_val=$(extract_val "$old_profile" "$field")
        new_val=$(extract_val "$new_profile" "$field")

        [ -z "$old_val" ] && old_val="(empty)"
        [ -z "$new_val" ] && new_val="(empty)"

        if [ "$old_val" != "$new_val" ]; then
            local change_type="modified"
            [ "$old_val" = "(empty)" ] && change_type="added"
            [ "$new_val" = "(empty)" ] && change_type="removed"

            echo "  CHANGED  $field"
            echo "    old: $old_val"
            echo "    new: $new_val"
            echo ""
            add_change "$field" "$old_val" "$new_val" "$change_type"
        fi
    done

    if [ $changes -eq 0 ]; then
        echo "  No changes detected between snapshots."
    fi

    diff_json+="]"

    # Compare gap counts if gap analysis files exist
    local old_gap_file new_gap_file old_gaps new_gaps
    old_gap_file=$(dirname "$old_profile")/francesca_gap_analysis.json
    new_gap_file=$(dirname "$new_profile")/francesca_gap_analysis.json

    echo "── Gap Analysis Delta ──"
    echo ""
    if [ -f "$old_gap_file" ] && [ -f "$new_gap_file" ]; then
        old_gaps=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$old_gap_file" | sed 's/.*:\s*//')
        new_gaps=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$new_gap_file" | sed 's/.*:\s*//')
        local gap_delta=$((new_gaps - old_gaps))
        local gap_direction="unchanged"
        [ $gap_delta -gt 0 ] && gap_direction="increased (+$gap_delta)"
        [ $gap_delta -lt 0 ] && gap_direction="decreased ($gap_delta)"

        echo "  Old gaps: $old_gaps | New gaps: $new_gaps | Delta: $gap_direction"

        # Show specific gap changes
        local old_gap_fields new_gap_fields
        old_gap_fields=$(grep -oP '"field"\s*:\s*"[^"]*"' "$old_gap_file" 2>/dev/null | sed 's/"field"\s*:\s*"//;s/"$//' | sort)
        new_gap_fields=$(grep -oP '"field"\s*:\s*"[^"]*"' "$new_gap_file" 2>/dev/null | sed 's/"field"\s*:\s*"//;s/"$//' | sort)

        local resolved new_gaps_list
        resolved=$(comm -23 <(echo "$old_gap_fields") <(echo "$new_gap_fields") 2>/dev/null || true)
        new_gaps_list=$(comm -13 <(echo "$old_gap_fields") <(echo "$new_gap_fields") 2>/dev/null || true)

        if [ -n "$resolved" ]; then
            echo ""
            echo "  RESOLVED gaps:"
            echo "$resolved" | sed 's/^/    [+] /'
        fi
        if [ -n "$new_gaps_list" ]; then
            echo ""
            echo "  NEW gaps:"
            echo "$new_gaps_list" | sed 's/^/    [-] /'
        fi
    else
        echo "  Gap analysis files not available for comparison"
    fi

    # Write diff report JSON
    local diff_report="$DIFF_DIR/diff_${TIMESTAMP_COMPACT}.json"
    cat > "$diff_report" <<ENDJSON
{
  "yeahso_network": true,
  "mothership": true,
  "type": "audit_diff",
  "timestamp": "$TIMESTAMP",
  "old_profile": "$(json_escape "$old_profile")",
  "new_profile": "$(json_escape "$new_profile")",
  "total_changes": $changes,
  "changes": $diff_json
}
ENDJSON

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Total changes: $changes"
    echo "  Diff saved: $diff_report"
    echo "═══════════════════════════════════════════════════════════════"
}

cmd_auto_diff() {
    # Compare the two most recent snapshots
    local snaps
    snaps=$(find "$SNAPSHOTS_DIR" -maxdepth 1 -type d -name "snapshot_*" | sort | tail -2)
    local snap_count
    snap_count=$(echo "$snaps" | grep -c . || echo 0)

    if [ "$snap_count" -lt 2 ]; then
        echo "Need at least 2 snapshots to diff. Current: $snap_count"
        echo ""
        echo "Take a snapshot first: $(basename "$0") snapshot"
        echo "Then re-run audits, re-ingest, and snapshot again."
        exit 1
    fi

    local old_snap new_snap
    old_snap=$(echo "$snaps" | head -1)
    new_snap=$(echo "$snaps" | tail -1)

    cmd_diff "$old_snap/francesca_device_profile.json" "$new_snap/francesca_device_profile.json"
}

###############################################################################
# Main
###############################################################################
CMD="${1:-}"

case "$CMD" in
    snapshot)
        cmd_snapshot
        ;;
    history)
        cmd_history
        ;;
    diff)
        if [ $# -ge 3 ]; then
            cmd_diff "$2" "$3"
        else
            cmd_auto_diff
        fi
        ;;
    ""|help|--help|-h)
        cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  snapshot              Save current KB state as a timestamped snapshot
  history               List all saved snapshots
  diff                  Compare two most recent snapshots
  diff <old> <new>      Compare two specific profile JSONs
  help                  Show this help

Workflow:
  1. Run audits and ingest into Francesca KB
  2. $(basename "$0") snapshot     — save baseline
  3. ... time passes, re-run audits ...
  4. $(basename "$0") snapshot     — save new state
  5. $(basename "$0") diff         — see what changed
EOF
        ;;
    *)
        echo "Unknown command: $CMD"
        exit 1
        ;;
esac
