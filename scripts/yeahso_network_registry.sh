#!/usr/bin/env bash
###############################################################################
# yeahso_network_registry.sh — Phase 3, Tool 4
# YeahSo Network · Mothership · Device Registry & Network Dashboard
#
# Maintains a registry of all devices in the YeahSo Network, tracks their
# audit status, generates a network-wide dashboard, and produces a
# consolidated status report.
#
# Usage:
#   yeahso_network_registry.sh init              Initialize registry
#   yeahso_network_registry.sh register <role>    Register this device
#   yeahso_network_registry.sh status             Show network status
#   yeahso_network_registry.sh dashboard          Generate full dashboard
###############################################################################
set -uo pipefail

NETWORK_DIR="$HOME/yeahso_mothership/network"
REGISTRY="$NETWORK_DIR/device_registry.json"
DASHBOARD="$NETWORK_DIR/network_dashboard.txt"
DASHBOARD_JSON="$NETWORK_DIR/network_dashboard.json"
KB_DIR="$HOME/yeahso_mothership/francesca_kb"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
VERSION="1.0"

mkdir -p "$NETWORK_DIR"

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

###############################################################################
# Commands
###############################################################################

cmd_init() {
    echo "Initializing YeahSo Network device registry..."

    cat > "$REGISTRY" <<ENDJSON
{
  "yeahso_network": true,
  "registry_type": "device_registry",
  "version": "$VERSION",
  "created": "$TIMESTAMP",
  "last_updated": "$TIMESTAMP",
  "network_name": "YeahSo Network",
  "network_topology": {
    "mothership": {
      "description": "Primary processing hub — runs Francesca KB, AI workloads",
      "transfer_method": "direct"
    },
    "scout": {
      "description": "ChromeOS satellite — data collection, Google ecosystem access",
      "transfer_method": "usb_lifeboat"
    },
    "lifeboat_usb": {
      "description": "Air-gapped data transfer medium between Scout and Mothership",
      "transfer_method": "physical"
    }
  },
  "devices": [],
  "transfer_log": []
}
ENDJSON

    echo "  Registry created: $REGISTRY"

    # Auto-register Mothership
    cmd_register "mothership"
}

cmd_register() {
    local role="${1:-unknown}"
    [ -f "$REGISTRY" ] || { echo "ERROR: Registry not initialized. Run: $0 init"; exit 1; }

    local hostname cpu ram storage os_info device_id
    hostname=$(hostname 2>/dev/null || echo "unknown")
    cpu=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
    ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    ram_gb=$(awk "BEGIN {printf \"%.1f\", $ram_kb/1048576}" 2>/dev/null || echo "0")
    storage=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}' || echo "0")
    os_info=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | sed 's/PRETTY_NAME="//;s/"$//' || echo "unknown")
    device_id="${role}_${hostname}_$(date -u +%Y%m%d)"

    # Check for Francesca KB data if this is mothership
    local kb_status="none"
    local gap_count=0
    local modules_ingested=0
    if [ -f "$KB_DIR/francesca_device_profile.json" ]; then
        kb_status="active"
        gap_count=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$KB_DIR/francesca_gap_analysis.json" 2>/dev/null | sed 's/.*:\s*//' || echo "0")
        modules_ingested=$(grep -o '"module_' "$KB_DIR/francesca_device_profile.json" 2>/dev/null | wc -l)
        # Count from data_sources_ingested
        modules_ingested=$(grep -c '"module_' "$KB_DIR/francesca_device_profile.json" 2>/dev/null || echo "0")
    fi

    # Build device entry
    local device_entry
    device_entry=$(cat <<ENDJSON
{
    "device_id": "$device_id",
    "role": "$role",
    "hostname": "$(json_escape "$hostname")",
    "cpu": "$(json_escape "$cpu")",
    "ram_gb": $ram_gb,
    "storage_gb": $storage,
    "os": "$(json_escape "$os_info")",
    "registered": "$TIMESTAMP",
    "last_audit": "$TIMESTAMP",
    "audit_status": "complete",
    "kb_status": "$kb_status",
    "gaps": $gap_count,
    "modules_ingested": $modules_ingested
  }
ENDJSON
)

    # Add to registry (simple append approach — no jq dependency)
    # Read current devices array, append new device
    local tmp_reg
    tmp_reg=$(mktemp)

    # Replace empty devices array or append
    if grep -q '"devices": \[\]' "$REGISTRY"; then
        sed 's/"devices": \[\]/"devices": ['"$(echo "$device_entry" | tr '\n' ' ' | sed 's/  */ /g')"']/' "$REGISTRY" > "$tmp_reg"
    else
        # Add before the last ] in devices array
        sed 's/\(  \]\),\s*$/,'"$(echo "$device_entry" | tr '\n' ' ' | sed 's/  */ /g')"'\1/' "$REGISTRY" > "$tmp_reg"
    fi

    # Update last_updated
    sed -i "s/\"last_updated\": \"[^\"]*\"/\"last_updated\": \"$TIMESTAMP\"/" "$tmp_reg"
    mv "$tmp_reg" "$REGISTRY"

    echo "  Device registered: $device_id ($role)"
    echo "  Hostname: $hostname | CPU: $cpu | RAM: ${ram_gb}GB | Storage: ${storage}GB"
}

cmd_register_scout() {
    # Register Scout device from its audit data
    [ -f "$REGISTRY" ] || { echo "ERROR: Registry not initialized."; exit 1; }
    [ -f "$KB_DIR/francesca_device_profile.json" ] || { echo "ERROR: No KB profile. Run francesca_ingest.sh first."; exit 1; }

    local profile="$KB_DIR/francesca_device_profile.json"
    local hostname cpu ram storage model os_ver
    hostname=$(grep -oP '"hostname"\s*:\s*"[^"]*"' "$profile" | head -1 | sed 's/.*"hostname"\s*:\s*"//;s/"$//')
    cpu=$(grep -oP '"cpu"\s*:\s*"[^"]*"' "$profile" | head -1 | sed 's/.*"cpu"\s*:\s*"//;s/"$//')
    ram=$(grep -oP '"ram_gb"\s*:\s*[0-9.]+' "$profile" | head -1 | sed 's/.*:\s*//')
    storage=$(grep -oP '"storage_local_gb"\s*:\s*[0-9.]+' "$profile" | head -1 | sed 's/.*:\s*//')
    model=$(grep -oP '"model"\s*:\s*"[^"]*"' "$profile" | head -1 | sed 's/.*"model"\s*:\s*"//;s/"$//')
    os_ver=$(grep -oP '"chromeos_version"\s*:\s*"[^"]*"' "$profile" | head -1 | sed 's/.*"chromeos_version"\s*:\s*"//;s/"$//')
    local gap_count
    gap_count=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$KB_DIR/francesca_gap_analysis.json" 2>/dev/null | sed 's/.*:\s*//' || echo "0")

    local device_id="scout_${hostname}_$(date -u +%Y%m%d)"

    local device_entry
    device_entry=$(cat <<ENDJSON
{
    "device_id": "$device_id",
    "role": "scout_satellite",
    "hostname": "$(json_escape "$hostname")",
    "model": "$(json_escape "$model")",
    "cpu": "$(json_escape "$cpu")",
    "ram_gb": $ram,
    "storage_gb": $storage,
    "os": "ChromeOS $(json_escape "$os_ver")",
    "registered": "$TIMESTAMP",
    "last_audit": "$TIMESTAMP",
    "audit_status": "complete",
    "transfer_method": "usb_lifeboat",
    "gaps": $gap_count
  }
ENDJSON
)

    local tmp_reg
    tmp_reg=$(mktemp)
    # Append to devices array
    if grep -q '"devices": \[' "$REGISTRY"; then
        # Insert before the closing bracket of devices array
        python3 -c "
import json, sys
with open('$REGISTRY') as f:
    reg = json.load(f)
device = json.loads('''$device_entry''')
# Remove existing scout entries to avoid duplicates
reg['devices'] = [d for d in reg['devices'] if d.get('role') != 'scout_satellite']
reg['devices'].append(device)
reg['last_updated'] = '$TIMESTAMP'
with open('$REGISTRY', 'w') as f:
    json.dump(reg, f, indent=2)
" 2>/dev/null || {
            # Fallback if python3 not available — just note it
            echo "  WARNING: Could not auto-register Scout (python3 needed for JSON merge)"
        }
    fi

    echo "  Scout registered: $device_id"
    echo "  Model: $model | ChromeOS: $os_ver | Gaps: $gap_count"
}

cmd_status() {
    [ -f "$REGISTRY" ] || { echo "ERROR: Registry not initialized."; exit 1; }

    echo "═══════════════════════════════════════════════════════════════"
    echo "  YeahSo Network — Status Overview"
    echo "  $TIMESTAMP"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Count devices
    local device_count
    device_count=$(grep -c '"device_id"' "$REGISTRY" 2>/dev/null || echo 0)
    echo "  Registered devices: $device_count"
    echo ""

    # List each device
    grep -oP '"device_id"\s*:\s*"[^"]*"' "$REGISTRY" | sed 's/"device_id"\s*:\s*"//;s/"$//' | while IFS= read -r dev_id; do
        local role hostname gaps
        # Get context around this device
        local block
        block=$(grep -A10 "\"$dev_id\"" "$REGISTRY")
        role=$(echo "$block" | grep -oP '"role"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"role"\s*:\s*"//;s/"$//')
        hostname=$(echo "$block" | grep -oP '"hostname"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"hostname"\s*:\s*"//;s/"$//')
        gaps=$(echo "$block" | grep -oP '"gaps"\s*:\s*[0-9]+' | head -1 | sed 's/.*:\s*//')
        echo "  [$role] $dev_id"
        echo "    Hostname: $hostname | Gaps: ${gaps:-0}"
    done
    echo ""
}

cmd_dashboard() {
    [ -f "$REGISTRY" ] || cmd_init

    echo "Generating network dashboard..."

    # Register Scout from KB if available
    if [ -f "$KB_DIR/francesca_device_profile.json" ]; then
        cmd_register_scout 2>/dev/null
    fi

    local device_count
    device_count=$(grep -c '"device_id"' "$REGISTRY" 2>/dev/null || echo 0)

    # Gather KB stats
    local total_gaps=0 total_actions=0 pending_actions=0
    [ -f "$KB_DIR/francesca_gap_analysis.json" ] && total_gaps=$(grep -oP '"total_gaps"\s*:\s*[0-9]+' "$KB_DIR/francesca_gap_analysis.json" | sed 's/.*:\s*//' || echo 0)
    [ -f "$KB_DIR/francesca_action_items.json" ] && {
        total_actions=$(grep -c '"id"' "$KB_DIR/francesca_action_items.json" 2>/dev/null || echo 0)
        pending_actions=$(grep -c '"pending"' "$KB_DIR/francesca_action_items.json" 2>/dev/null || echo 0)
    }

    # Snapshot count
    local snap_count
    snap_count=$(find "$HOME/yeahso_mothership/snapshots" -maxdepth 1 -type d -name "snapshot_*" 2>/dev/null | wc -l)

    # Remediation status
    local remediation_status="not run"
    [ -f "$HOME/yeahso_mothership/remediation/remediation_summary.json" ] && {
        local auto_fixed remaining
        auto_fixed=$(grep -oP '"auto_fixed"\s*:\s*[0-9]+' "$HOME/yeahso_mothership/remediation/remediation_summary.json" | sed 's/.*:\s*//')
        remaining=$(grep -oP '"remaining"\s*:\s*[0-9]+' "$HOME/yeahso_mothership/remediation/remediation_summary.json" | sed 's/.*:\s*//')
        remediation_status="$auto_fixed fixed, $remaining remaining"
    }

    # Build dashboard
    cat > "$DASHBOARD" <<ENDTXT
╔═══════════════════════════════════════════════════════════════════════════════╗
║                    YeahSo Network — Command Dashboard                       ║
║                    Generated: $TIMESTAMP                          ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  NETWORK TOPOLOGY                                                           ║
║  ┌─────────────┐     USB Lifeboat     ┌──────────────┐                      ║
║  │   SCOUT     │ ──────────────────── │  MOTHERSHIP  │                      ║
║  │ (ChromeOS)  │    air-gapped        │  (Francesca) │                      ║
║  └─────────────┘                      └──────────────┘                      ║
║                                                                             ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  DEVICES: $device_count registered                                                  ║
║                                                                             ║
$(grep -oP '"device_id"\s*:\s*"[^"]*"' "$REGISTRY" 2>/dev/null | sed 's/"device_id"\s*:\s*"//;s/"$//' | while IFS= read -r dev_id; do
    local block role hostname
    block=$(grep -A10 "\"$dev_id\"" "$REGISTRY")
    role=$(echo "$block" | grep -oP '"role"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"role"\s*:\s*"//;s/"$//')
    hostname=$(echo "$block" | grep -oP '"hostname"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"hostname"\s*:\s*"//;s/"$//')
    printf "║    %-12s %-25s %-20s    ║\n" "[$role]" "$dev_id" "$hostname"
done)
║                                                                             ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  FRANCESCA KNOWLEDGE BASE                                                   ║
║    Gaps identified    : $total_gaps                                                  ║
║    Action items       : $total_actions total, $pending_actions pending                                   ║
║    Snapshots saved    : $snap_count                                                     ║
║    Remediation status : $remediation_status                              ║
║                                                                             ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  PIPELINE STATUS                                                            ║
║    Phase 1 (Scout Collection)   : COMPLETE — 4/4 stages                     ║
║    Phase 2 (Mothership Ingest)  : COMPLETE — Mailroom + Francesca           ║
║    Phase 3 (Operationalize)     : ACTIVE                                    ║
║                                                                             ║
║  AVAILABLE COMMANDS                                                         ║
║    francesca_query.sh summary     Query the knowledge base                  ║
║    francesca_query.sh gaps        View gap analysis                         ║
║    francesca_query.sh health      Device health scorecard                   ║
║    francesca_remediate.sh plan    View remediation plan                     ║
║    francesca_remediate.sh run     Execute safe remediations                 ║
║    francesca_diff.sh snapshot     Save current state                        ║
║    francesca_diff.sh diff         Compare snapshots                         ║
║    yeahso_network_registry.sh status   Network overview                     ║
║                                                                             ║
╚═══════════════════════════════════════════════════════════════════════════════╝
ENDTXT

    cat "$DASHBOARD"

    # JSON version
    cat > "$DASHBOARD_JSON" <<ENDJSON
{
  "yeahso_network": true,
  "mothership": true,
  "type": "network_dashboard",
  "version": "$VERSION",
  "generated": "$TIMESTAMP",
  "network": {
    "name": "YeahSo Network",
    "devices_registered": $device_count,
    "topology": ["scout_satellite", "lifeboat_usb", "mothership"]
  },
  "francesca_kb": {
    "status": "active",
    "gaps": $total_gaps,
    "action_items_total": $total_actions,
    "action_items_pending": $pending_actions,
    "snapshots": $snap_count,
    "remediation": "$(json_escape "$remediation_status")"
  },
  "pipeline": {
    "phase_1": "complete",
    "phase_2": "complete",
    "phase_3": "active"
  }
}
ENDJSON

    echo ""
    echo "Dashboard saved: $DASHBOARD"
    echo "Dashboard JSON:  $DASHBOARD_JSON"
}

###############################################################################
# Main
###############################################################################
CMD="${1:-status}"
shift 2>/dev/null || true

case "$CMD" in
    init)       cmd_init ;;
    register)   cmd_register "${1:-unknown}" ;;
    scout)      cmd_register_scout ;;
    status)     cmd_status ;;
    dashboard)  cmd_dashboard ;;
    help|--help|-h)
        cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  init                Initialize the device registry
  register <role>     Register current device (mothership|scout|workstation)
  scout               Register Scout device from Francesca KB data
  status              Show network status overview
  dashboard           Generate full network dashboard
  help                Show this help
EOF
        ;;
    *)  echo "Unknown: $CMD"; exit 1 ;;
esac
