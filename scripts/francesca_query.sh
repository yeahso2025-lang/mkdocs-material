#!/usr/bin/env bash
###############################################################################
# francesca_query.sh — Phase 3, Tool 1
# YeahSo Network · Mothership · Francesca Knowledge Base Query Interface
#
# Search and retrieve data from the Francesca KB. Supports:
#   - Field lookup:    francesca_query.sh field device.cpu
#   - Module summary:  francesca_query.sh module browser
#   - Keyword search:  francesca_query.sh search "docker"
#   - Gaps:            francesca_query.sh gaps [severity]
#   - Actions:         francesca_query.sh actions [status]
#   - Summary:         francesca_query.sh summary
#   - Export:          francesca_query.sh export [format]
###############################################################################
set -uo pipefail

KB_DIR="$HOME/yeahso_mothership/francesca_kb"
PROFILE="$KB_DIR/francesca_device_profile.json"
GAPS="$KB_DIR/francesca_gap_analysis.json"
ACTIONS="$KB_DIR/francesca_action_items.json"
REPORT="$KB_DIR/francesca_device_profile.txt"

# ── Helpers ──────────────────────────────────────────────────────────────────
die() { echo "ERROR: $*" >&2; exit 1; }

check_kb() {
    [ -d "$KB_DIR" ] || die "Francesca KB not found at $KB_DIR — run francesca_ingest.sh first"
    [ -f "$PROFILE" ] || die "Device profile not found — run francesca_ingest.sh first"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  summary                 Show full device overview
  field <path>            Lookup a specific field (e.g., device.cpu, device.ram_gb)
  module <name>           Show module summary (chromeos|browser|research|android)
  search <keyword>        Search all KB files for a keyword
  gaps [severity]         List gaps (optional: high|medium|low)
  actions [status]        List action items (optional: pending|in_progress|completed)
  assets                  Show digital asset inventory
  health                  Device health scorecard
  export [json|txt]       Export consolidated report
  help                    Show this help
EOF
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_summary() {
    check_kb
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Francesca KB — Scout Device Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Device basics
    local hostname cpu ram storage model os debian
    hostname=$(grep -oP '"hostname"\s*:\s*"[^"]*"' "$PROFILE" | head -1 | sed 's/.*"hostname"\s*:\s*"//;s/"$//')
    cpu=$(grep -oP '"cpu"\s*:\s*"[^"]*"' "$PROFILE" | head -1 | sed 's/.*"cpu"\s*:\s*"//;s/"$//')
    ram=$(grep -oP '"ram_gb"\s*:\s*[0-9.]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    storage=$(grep -oP '"storage_local_gb"\s*:\s*[0-9.]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    model=$(grep -oP '"model"\s*:\s*"[^"]*"' "$PROFILE" | head -1 | sed 's/.*"model"\s*:\s*"//;s/"$//')
    os=$(grep -oP '"chromeos_version"\s*:\s*"[^"]*"' "$PROFILE" | head -1 | sed 's/.*"chromeos_version"\s*:\s*"//;s/"$//')
    debian=$(grep -oP '"debian_version"\s*:\s*"[^"]*"' "$PROFILE" | head -1 | sed 's/.*"debian_version"\s*:\s*"//;s/"$//')

    echo "  Hostname : $hostname"
    echo "  Model    : $model"
    echo "  ChromeOS : $os"
    echo "  CPU      : $cpu"
    echo "  RAM      : ${ram} GB"
    echo "  Storage  : ${storage} GB"
    echo "  Crostini : Debian $debian"
    echo ""

    # Quick stats
    local pkgs devtools docker
    pkgs=$(grep -oP '"packages_installed"\s*:\s*[0-9]+' "$PROFILE" | sed 's/.*:\s*//')
    devtools=$(grep -oP '"dev_tools_available"\s*:\s*[0-9]+' "$PROFILE" | sed 's/.*:\s*//')
    docker=$(grep -oP '"docker"\s*:\s*(true|false)' "$PROFILE" | head -1 | sed 's/.*:\s*//')

    echo "  Packages : $pkgs | Dev tools: $devtools | Docker: $docker"

    # Gaps count
    local gap_count
    gap_count=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$GAPS" | sed 's/.*:\s*//')
    echo "  Gaps     : $gap_count items need attention"

    # Action items
    local pending_actions
    pending_actions=$(grep -c '"status": "pending"' "$ACTIONS" 2>/dev/null || echo 0)
    echo "  Actions  : $pending_actions pending"
    echo ""
}

cmd_field() {
    check_kb
    local path="$1"
    # Convert dot path to grep pattern
    local key="${path##*.}"
    local result
    result=$(grep -oP "\"$key\"\\s*:\\s*[^\n,}]+" "$PROFILE" | head -1 | sed "s/\"$key\"\\s*:\\s*//" | sed 's/^"//;s/"$//')
    if [ -n "$result" ]; then
        echo "$path = $result"
    else
        echo "Field '$path' not found in device profile"
        echo "Hint: Try 'search $key' to find it across all KB files"
    fi
}

cmd_module() {
    check_kb
    local mod="$1"
    case "$mod" in
        chromeos|1|inventory)
            echo "── Module 01: ChromeOS Inventory ──"
            grep -A20 '"device"' "$PROFILE" | head -25
            ;;
        browser|2)
            echo "── Module 02: Browser Data ──"
            grep -A15 '"browser"' "$PROFILE" | head -18
            ;;
        research|3|files)
            echo "── Module 03: Research Files ──"
            grep -A15 '"digital_assets"' "$PROFILE" | head -18
            ;;
        android|4)
            echo "── Module 04: Android Data ──"
            grep -A12 '"android"' "$PROFILE" | head -15
            ;;
        *)
            echo "Unknown module: $mod"
            echo "Available: chromeos, browser, research, android"
            ;;
    esac
}

cmd_search() {
    check_kb
    local keyword="$1"
    echo "Searching Francesca KB for: '$keyword'"
    echo ""
    local found=0
    for f in "$KB_DIR"/*.json "$KB_DIR"/*.txt; do
        [ -f "$f" ] || continue
        local matches
        matches=$(grep -in "$keyword" "$f" 2>/dev/null || true)
        if [ -n "$matches" ]; then
            echo "── $(basename "$f") ──"
            echo "$matches" | head -20
            echo ""
            found=$((found + 1))
        fi
    done
    [ "$found" -eq 0 ] && echo "  No results found for '$keyword'"
}

cmd_gaps() {
    check_kb
    local filter="${1:-}"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Francesca KB — Gap Analysis"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local total
    total=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$GAPS" | sed 's/.*:\s*//')
    echo "  Total gaps: $total"
    echo ""

    # Parse gaps
    if [ -n "$filter" ]; then
        echo "  Filtered by severity: $filter"
        echo ""
        grep -oP '\{[^}]*"severity"\s*:\s*"'"$filter"'"[^}]*\}' "$GAPS" 2>/dev/null | while IFS= read -r gap; do
            local module field note
            module=$(echo "$gap" | grep -oP '"module"\s*:\s*"[^"]*"' | sed 's/.*"module"\s*:\s*"//;s/"$//')
            field=$(echo "$gap" | grep -oP '"field"\s*:\s*"[^"]*"' | sed 's/.*"field"\s*:\s*"//;s/"$//')
            note=$(echo "$gap" | grep -oP '"note"\s*:\s*"[^"]*"' | sed 's/.*"note"\s*:\s*"//;s/"$//')
            echo "  [$filter] $module/$field"
            echo "    $note"
            echo ""
        done
    else
        # Show all gaps grouped by severity
        for sev in high medium low; do
            local sev_gaps
            sev_gaps=$(grep -oP '\{[^}]*"severity"\s*:\s*"'"$sev"'"[^}]*\}' "$GAPS" 2>/dev/null || true)
            [ -z "$sev_gaps" ] && continue
            local sev_upper
            sev_upper=$(echo "$sev" | tr '[:lower:]' '[:upper:]')
            echo "  ── $sev_upper ──"
            echo "$sev_gaps" | while IFS= read -r gap; do
                local module field note
                module=$(echo "$gap" | grep -oP '"module"\s*:\s*"[^"]*"' | sed 's/.*"module"\s*:\s*"//;s/"$//')
                field=$(echo "$gap" | grep -oP '"field"\s*:\s*"[^"]*"' | sed 's/.*"field"\s*:\s*"//;s/"$//')
                note=$(echo "$gap" | grep -oP '"note"\s*:\s*"[^"]*"' | sed 's/.*"note"\s*:\s*"//;s/"$//')
                echo "    $module/$field — $note"
            done
            echo ""
        done
    fi
}

cmd_actions() {
    check_kb
    local filter="${1:-}"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Francesca KB — Action Items"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Extract actions using multiline approach
    grep -oP '"id"\s*:\s*"[^"]*"' "$ACTIONS" | sed 's/"id"\s*:\s*"//;s/"$//' | while IFS= read -r action_id; do
        # Get surrounding context for this action
        local block priority title status assigned
        block=$(grep -A6 "\"$action_id\"" "$ACTIONS")
        priority=$(echo "$block" | grep -oP '"priority"\s*:\s*[0-9]+' | sed 's/.*:\s*//')
        title=$(echo "$block" | grep -oP '"title"\s*:\s*"[^"]*"' | sed 's/"title"\s*:\s*"//;s/"$//')
        status=$(echo "$block" | grep -oP '"status"\s*:\s*"[^"]*"' | sed 's/"status"\s*:\s*"//;s/"$//')
        assigned=$(echo "$block" | grep -oP '"assigned_to"\s*:\s*"[^"]*"' | sed 's/"assigned_to"\s*:\s*"//;s/"$//')

        # Apply filter
        if [ -n "$filter" ] && [ "$status" != "$filter" ]; then
            continue
        fi

        local status_icon="[ ]"
        [ "$status" = "in_progress" ] && status_icon="[~]"
        [ "$status" = "completed" ] && status_icon="[x]"

        echo "  $status_icon $action_id [P$priority] $title"
        echo "       Assigned: $assigned | Status: $status"
    done
    echo ""
}

cmd_assets() {
    check_kb
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Francesca KB — Digital Asset Inventory"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local docs data pres code imgs audio video archives home_size
    docs=$(grep -oP '"documents"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    data=$(grep -oP '"data_files"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    pres=$(grep -oP '"presentations"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    code=$(grep -oP '"code_projects"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    imgs=$(grep -oP '"images"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    audio=$(grep -oP '"audio"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    video=$(grep -oP '"video"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    archives=$(grep -oP '"archives"\s*:\s*[0-9]+' "$PROFILE" | head -1 | sed 's/.*:\s*//')
    home_size=$(grep -oP '"home_directory_size"\s*:\s*"[^"]*"' "$PROFILE" | sed 's/.*"home_directory_size"\s*:\s*"//;s/"$//')

    echo "  Documents      : $docs"
    echo "  Data files     : $data"
    echo "  Presentations  : $pres"
    echo "  Code projects  : $code"
    echo "  Images         : $imgs"
    echo "  Audio          : $audio"
    echo "  Video          : $video"
    echo "  Archives       : $archives"
    echo "  ─────────────────────"
    echo "  Home dir total : $home_size"
    echo ""
}

cmd_health() {
    check_kb
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Francesca KB — Scout Device Health Scorecard"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local score=100
    local total_gaps
    total_gaps=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$GAPS" | sed 's/.*:\s*//')
    local high_gaps medium_gaps low_gaps
    high_gaps=$(grep -c '"severity": "high"' "$GAPS" 2>/dev/null || echo 0)  # typo safe
    high_gaps=$(grep -o '"high"' "$GAPS" 2>/dev/null | wc -l)
    medium_gaps=$(grep -o '"medium"' "$GAPS" 2>/dev/null | wc -l)
    low_gaps=$(grep -o '"low"' "$GAPS" 2>/dev/null | wc -l)

    # Deductions
    score=$((score - high_gaps * 15))
    score=$((score - medium_gaps * 8))
    score=$((score - low_gaps * 3))
    [ $score -lt 0 ] && score=0

    local grade="F"
    [ $score -ge 90 ] && grade="A"
    [ $score -ge 80 ] && [ $score -lt 90 ] && grade="B"
    [ $score -ge 70 ] && [ $score -lt 80 ] && grade="C"
    [ $score -ge 60 ] && [ $score -lt 70 ] && grade="D"

    echo "  Health Score : $score / 100 ($grade)"
    echo ""
    echo "  Deductions:"
    echo "    High-severity gaps   : $high_gaps × 15 = -$((high_gaps * 15))"
    echo "    Medium-severity gaps : $medium_gaps × 8  = -$((medium_gaps * 8))"
    echo "    Low-severity gaps    : $low_gaps × 3  = -$((low_gaps * 3))"
    echo ""

    if [ $score -ge 80 ]; then
        echo "  Status: Good — minor gaps, mostly operational"
    elif [ $score -ge 60 ]; then
        echo "  Status: Fair — several data gaps need attention"
    else
        echo "  Status: Needs Work — significant gaps in audit coverage"
    fi

    echo ""
    echo "  Improve score by resolving gaps (run: $(basename "$0") gaps)"
    echo ""
}

cmd_export() {
    check_kb
    local format="${1:-txt}"
    case "$format" in
        txt)
            cat "$REPORT"
            ;;
        json)
            cat "$PROFILE"
            ;;
        *)
            echo "Supported formats: txt, json"
            ;;
    esac
}

# ── Main ─────────────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
    summary)    cmd_summary ;;
    field)      [ -n "${1:-}" ] && cmd_field "$1" || die "Usage: $0 field <path>" ;;
    module)     [ -n "${1:-}" ] && cmd_module "$1" || die "Usage: $0 module <name>" ;;
    search)     [ -n "${1:-}" ] && cmd_search "$1" || die "Usage: $0 search <keyword>" ;;
    gaps)       cmd_gaps "${1:-}" ;;
    actions)    cmd_actions "${1:-}" ;;
    assets)     cmd_assets ;;
    health)     cmd_health ;;
    export)     cmd_export "${1:-txt}" ;;
    help|--help|-h) usage ;;
    *)          echo "Unknown command: $CMD"; usage; exit 1 ;;
esac
