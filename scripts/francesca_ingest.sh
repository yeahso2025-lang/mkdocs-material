#!/usr/bin/env bash
###############################################################################
# francesca_ingest.sh — Phase 2, Step 2
# YeahSo Network · Mothership · Francesca Knowledge Base Ingestion
#
# Reads validated Scout module JSONs from the Mailroom batch directory,
# parses, normalizes, and merges them into a unified Francesca knowledge
# base manifest. Generates a consolidated device profile, asset inventory,
# gap analysis, and action items for the YeahSo Network.
#
# Standing rules:
#   - Input must come from validated Mailroom batch (intake_receipt.json)
#   - All transformations are logged
#   - Output is the single source of truth for Francesca
###############################################################################
set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
MOTHERSHIP_DIR="$HOME/yeahso_mothership"
KB_DIR="$MOTHERSHIP_DIR/francesca_kb"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
VERSION="1.0"

# ── Helpers ──────────────────────────────────────────────────────────────────
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

extract_json_string() {
    local file="$1" key="$2"
    grep -oP "\"$key\"\\s*:\\s*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed "s/\"$key\"\\s*:\\s*\"//;s/\"$//" || echo ""
}

extract_json_number() {
    local file="$1" key="$2"
    grep -oP "\"$key\"\\s*:\\s*[0-9.]+" "$file" 2>/dev/null | head -1 | sed "s/\"$key\"\\s*:\\s*//" || echo "0"
}

extract_json_bool() {
    local file="$1" key="$2"
    grep -oP "\"$key\"\\s*:\\s*(true|false)" "$file" 2>/dev/null | head -1 | sed "s/\"$key\"\\s*:\\s*//" || echo "false"
}

echo "═══════════════════════════════════════════════════════════════"
echo "  YeahSo Network — Francesca Knowledge Base Ingestion"
echo "  Timestamp : $TIMESTAMP"
echo "═══════════════════════════════════════════════════════════════"
echo ""

###############################################################################
# 1. Locate Batch
###############################################################################
echo "[1/6] Locating validated batch..."

BATCH_DIR=""
if [ $# -ge 1 ] && [ -d "$1" ]; then
    BATCH_DIR="$1"
else
    # Find most recent validated batch
    BATCH_DIR=$(find "$MOTHERSHIP_DIR/mailroom/validated" -maxdepth 1 -type d -name "batch_*" 2>/dev/null | sort -r | head -1)
fi

if [ -z "$BATCH_DIR" ] || [ ! -d "$BATCH_DIR" ]; then
    echo "  ERROR: No validated batch found."
    echo "  Usage: $0 [path/to/batch_dir]"
    exit 1
fi

BATCH_ID=$(basename "$BATCH_DIR")

# Verify intake receipt
if [ ! -f "$BATCH_DIR/intake_receipt.json" ]; then
    echo "  ERROR: No intake_receipt.json — batch not validated by Mailroom"
    exit 1
fi

RECEIPT_STATUS=$(extract_json_string "$BATCH_DIR/intake_receipt.json" "status")
if [ "$RECEIPT_STATUS" != "ready_for_ingestion" ]; then
    echo "  ERROR: Batch status is '$RECEIPT_STATUS', expected 'ready_for_ingestion'"
    exit 1
fi

echo "  Batch: $BATCH_ID"
echo "  Status: $RECEIPT_STATUS"
echo ""

###############################################################################
# 2. Parse Module 01 — ChromeOS Inventory
###############################################################################
echo "[2/6] Parsing Module 01: ChromeOS Inventory..."

M01="$BATCH_DIR/module_01_chromeos_inventory.json"
M01_VERSION="" M01_CHANNEL="" M01_MODEL="" M01_CPU="" M01_RAM="" M01_STORAGE=""
M01_DEBIAN="" M01_DOCKER="" M01_PKG_COUNT=0 M01_DEVTOOLS_COUNT=0

if [ -f "$M01" ]; then
    M01_VERSION=$(extract_json_string "$M01" "version" | head -1)
    # Get nested values
    M01_CHROMEOS_VER=$(grep -oP '"version"\s*:\s*"[^"]*"' "$M01" | head -1 | sed 's/"version"\s*:\s*"//;s/"$//')
    M01_CHANNEL=$(extract_json_string "$M01" "channel")
    M01_MODEL=$(extract_json_string "$M01" "device_model")
    M01_CPU=$(extract_json_string "$M01" "cpu")
    M01_RAM=$(extract_json_number "$M01" "ram_gb")
    M01_STORAGE=$(extract_json_number "$M01" "storage_local_gb")
    M01_DEBIAN=$(extract_json_string "$M01" "debian_version")
    M01_DOCKER=$(extract_json_bool "$M01" "docker_installed")
    M01_PKG_COUNT=$(grep -o '"name"' "$M01" 2>/dev/null | wc -l)
    M01_DEVTOOLS_COUNT=$(grep -o '"tool"' "$M01" 2>/dev/null | wc -l)
    echo "  ChromeOS: $M01_CHROMEOS_VER ($M01_CHANNEL)"
    echo "  Hardware: $M01_MODEL | $M01_CPU | ${M01_RAM}GB RAM | ${M01_STORAGE}GB storage"
    echo "  Crostini: Debian $M01_DEBIAN | $M01_PKG_COUNT packages | $M01_DEVTOOLS_COUNT dev tools | Docker: $M01_DOCKER"
else
    echo "  WARNING: Module 01 not found"
fi

###############################################################################
# 3. Parse Module 02 — Browser Data
###############################################################################
echo "[3/6] Parsing Module 02: Browser Data..."

M02="$BATCH_DIR/module_02_browser_data.json"
M02_BROWSER="" M02_BOOKMARKS=0 M02_HISTORY=0 M02_PASSWORDS=0
M02_AUTOFILL=0 M02_COOKIES=0 M02_SEARCH="" M02_SYNC=""

if [ -f "$M02" ]; then
    M02_BROWSER=$(extract_json_string "$M02" "browser")
    M02_BOOKMARKS=$(extract_json_number "$M02" "count" | head -1)
    M02_HISTORY=$(extract_json_number "$M02" "total_entries" | head -1)
    M02_PASSWORDS=$(extract_json_number "$M02" "credential_count")
    M02_AUTOFILL=$(grep -oP '"total_entries"\s*:\s*[0-9]+' "$M02" 2>/dev/null | tail -1 | grep -oP '[0-9]+$' || echo "0")
    M02_COOKIES=$(extract_json_number "$M02" "total_cookies")
    M02_SEARCH=$(extract_json_string "$M02" "default_search_engine")
    M02_SYNC=$(extract_json_string "$M02" "sync_enabled")
    echo "  Browser: $M02_BROWSER | Bookmarks: $M02_BOOKMARKS | History: $M02_HISTORY"
    echo "  Passwords: $M02_PASSWORDS | Autofill: $M02_AUTOFILL | Cookies: $M02_COOKIES"
    echo "  Search: $M02_SEARCH | Sync: $M02_SYNC"
else
    echo "  WARNING: Module 02 not found"
fi

###############################################################################
# 4. Parse Module 03 — Research Files
###############################################################################
echo "[4/6] Parsing Module 03: Research Files..."

M03="$BATCH_DIR/module_03_research_files.json"
M03_DOCS=0 M03_DATA=0 M03_PRES=0 M03_CODE=0
M03_IMAGES=0 M03_AUDIO=0 M03_VIDEO=0 M03_ARCHIVES=0 M03_HOME_SIZE=""

if [ -f "$M03" ]; then
    # Extract counts from each section
    M03_DOCS=$(grep -oP '"documents"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_DATA=$(grep -oP '"data_files"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_PRES=$(grep -oP '"presentations"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_CODE=$(grep -oP '"code_projects"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_IMAGES=$(grep -oP '"images"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_AUDIO=$(grep -oP '"audio"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_VIDEO=$(grep -oP '"video"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_ARCHIVES=$(grep -oP '"archives"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M03" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M03_HOME_SIZE=$(extract_json_string "$M03" "home_total_size")
    echo "  Documents: $M03_DOCS | Data: $M03_DATA | Presentations: $M03_PRES"
    echo "  Code repos: $M03_CODE | Images: $M03_IMAGES | Audio: $M03_AUDIO | Video: $M03_VIDEO"
    echo "  Archives: $M03_ARCHIVES | Home size: $M03_HOME_SIZE"
else
    echo "  WARNING: Module 03 not found"
fi

###############################################################################
# 5. Parse Module 04 — Android Data
###############################################################################
echo "[5/6] Parsing Module 04: Android Data..."

M04="$BATCH_DIR/module_04_android_data.json"
M04_DETECTED="" M04_ANDROID_VER="" M04_USER_APPS=0 M04_SYSTEM_APPS=0
M04_PERMS=0 M04_ACCOUNTS=0 M04_SERVICES=0

if [ -f "$M04" ]; then
    M04_DETECTED=$(extract_json_bool "$M04" "detected")
    M04_ANDROID_VER=$(extract_json_string "$M04" "android_version")
    M04_USER_APPS=$(extract_json_number "$M04" "user_count")
    M04_SYSTEM_APPS=$(extract_json_number "$M04" "system_count")
    M04_PERMS=$(extract_json_number "$M04" "total_granted_runtime")
    M04_ACCOUNTS=$(grep -oP '"accounts"\s*:\s*\{[^}]*"count"\s*:\s*[0-9]+' "$M04" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    M04_SERVICES=$(grep -oP '"running_count"\s*:\s*[0-9]+' "$M04" 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    echo "  Android detected: $M04_DETECTED | Version: $M04_ANDROID_VER"
    echo "  User apps: $M04_USER_APPS | System apps: $M04_SYSTEM_APPS"
    echo "  Runtime permissions: $M04_PERMS | Accounts: $M04_ACCOUNTS | Services: $M04_SERVICES"
else
    echo "  WARNING: Module 04 not found"
fi

###############################################################################
# 6. Generate Consolidated Knowledge Base
###############################################################################
echo ""
echo "[6/6] Building Francesca Knowledge Base..."

mkdir -p "$KB_DIR"
KB_MANIFEST="$KB_DIR/francesca_device_profile.json"
KB_REPORT="$KB_DIR/francesca_device_profile.txt"
KB_GAPS="$KB_DIR/francesca_gap_analysis.json"
KB_ACTIONS="$KB_DIR/francesca_action_items.json"
KB_SHA="$KB_DIR/francesca_kb.sha256"

# ── Device Profile (consolidated) ───────────────────────────────────────────
cat > "$KB_MANIFEST" <<ENDJSON
{
  "yeahso_network": true,
  "mothership": true,
  "knowledge_base": "francesca",
  "manifest_type": "consolidated_device_profile",
  "version": "$VERSION",
  "generated": "$TIMESTAMP",
  "source_batch": "$BATCH_ID",
  "device": {
    "role": "scout_satellite",
    "hostname": "$(extract_json_string "$M01" "hostname")",
    "chromeos_version": "$(json_escape "$M01_CHROMEOS_VER")",
    "chromeos_channel": "$(json_escape "$M01_CHANNEL")",
    "model": "$(json_escape "$M01_MODEL")",
    "cpu": "$(json_escape "$M01_CPU")",
    "ram_gb": $M01_RAM,
    "storage_local_gb": $M01_STORAGE,
    "crostini": {
      "debian_version": "$(json_escape "$M01_DEBIAN")",
      "packages_installed": $M01_PKG_COUNT,
      "dev_tools_available": $M01_DEVTOOLS_COUNT,
      "docker": $M01_DOCKER
    },
    "android": {
      "detected": $M04_DETECTED,
      "version": "$(json_escape "$M04_ANDROID_VER")",
      "user_apps": $M04_USER_APPS,
      "system_apps": $M04_SYSTEM_APPS,
      "runtime_permissions": $M04_PERMS,
      "accounts": $M04_ACCOUNTS,
      "services_running": $M04_SERVICES
    },
    "browser": {
      "name": "$(json_escape "$M02_BROWSER")",
      "bookmarks": $M02_BOOKMARKS,
      "history_entries": $M02_HISTORY,
      "saved_credentials": $M02_PASSWORDS,
      "autofill_entries": $M02_AUTOFILL,
      "cookies": $M02_COOKIES,
      "default_search": "$(json_escape "$M02_SEARCH")",
      "sync_enabled": "$(json_escape "$M02_SYNC")"
    }
  },
  "digital_assets": {
    "documents": $M03_DOCS,
    "data_files": $M03_DATA,
    "presentations": $M03_PRES,
    "code_projects": $M03_CODE,
    "images": $M03_IMAGES,
    "audio": $M03_AUDIO,
    "video": $M03_VIDEO,
    "archives": $M03_ARCHIVES,
    "home_directory_size": "$(json_escape "$M03_HOME_SIZE")"
  },
  "data_sources_ingested": [
    "module_01_chromeos_inventory",
    "module_02_browser_data",
    "module_03_research_files",
    "module_04_android_data"
  ]
}
ENDJSON

echo "  Device profile written: $KB_MANIFEST"

# ── Gap Analysis ─────────────────────────────────────────────────────────────
# Identify what data is missing or incomplete
GAPS="["
GAPS_FIRST=true

add_gap() {
    local module="$1" field="$2" severity="$3" note="$4"
    $GAPS_FIRST || GAPS+=","
    GAPS_FIRST=false
    GAPS+="{\"module\":\"$module\",\"field\":\"$field\",\"severity\":\"$severity\",\"note\":\"$(json_escape "$note")\"}"
}

[ "$M01_CHROMEOS_VER" = "unknown" ] || [ -z "$M01_CHROMEOS_VER" ] && add_gap "chromeos_inventory" "chromeos_version" "high" "ChromeOS version not detected — run on actual Scout device"
[ "$M01_MODEL" = "unknown" ] || [ -z "$M01_MODEL" ] && add_gap "chromeos_inventory" "device_model" "medium" "Device model not detected — DMI not accessible"
[ "$M02_BOOKMARKS" = "0" ] && add_gap "browser_data" "bookmarks" "medium" "No bookmarks found — Chrome profile may not be accessible from Crostini"
[ "$M02_HISTORY" = "0" ] && add_gap "browser_data" "history" "medium" "No history found — need sqlite3 and Chrome profile access"
[ "$M02_PASSWORDS" = "0" ] && add_gap "browser_data" "saved_passwords" "low" "No saved passwords metadata — may require direct Chrome access"
[ "$M04_DETECTED" = "false" ] && add_gap "android_data" "android_subsystem" "medium" "Android/ARC++ not detected — enable Play Store or install ADB"
[ "$M03_DOCS" = "0" ] && add_gap "research_files" "documents" "high" "No documents found — check if user files are on GDrive or shared paths"
[ "$M03_CODE" = "0" ] && add_gap "research_files" "code_projects" "low" "No git repos found in scanned directories"

GAPS+="]"
GAPS_COUNT=$(echo "$GAPS" | grep -o '"module"' | wc -l)

cat > "$KB_GAPS" <<ENDJSON
{
  "yeahso_network": true,
  "mothership": true,
  "knowledge_base": "francesca",
  "manifest_type": "gap_analysis",
  "version": "$VERSION",
  "generated": "$TIMESTAMP",
  "source_batch": "$BATCH_ID",
  "total_gaps": $GAPS_COUNT,
  "gaps": $GAPS
}
ENDJSON

echo "  Gap analysis written: $KB_GAPS ($GAPS_COUNT gaps identified)"

# ── Action Items ─────────────────────────────────────────────────────────────
cat > "$KB_ACTIONS" <<ENDJSON
{
  "yeahso_network": true,
  "mothership": true,
  "knowledge_base": "francesca",
  "manifest_type": "action_items",
  "version": "$VERSION",
  "generated": "$TIMESTAMP",
  "source_batch": "$BATCH_ID",
  "actions": [
    {
      "id": "ACT-001",
      "priority": 1,
      "category": "data_collection",
      "title": "Re-run audit on physical Scout Chromebook",
      "description": "Current audit ran in VM. Re-run all 4 stages on the actual Scout ChromeOS device for complete data.",
      "status": "pending",
      "assigned_to": "DGANY"
    },
    {
      "id": "ACT-002",
      "priority": 2,
      "category": "data_collection",
      "title": "Execute Google Takeout exports",
      "description": "Export Gemini, NotebookLM, Chrome, Google Keep, and Google Drive data via Takeout as specified in takeout_checklist.json.",
      "status": "pending",
      "assigned_to": "DGANY"
    },
    {
      "id": "ACT-003",
      "priority": 3,
      "category": "infrastructure",
      "title": "Install sqlite3 in Crostini",
      "description": "Required for browser history, passwords, autofill, and cookies extraction. Run: sudo apt install sqlite3",
      "status": "pending",
      "assigned_to": "DGANY"
    },
    {
      "id": "ACT-004",
      "priority": 4,
      "category": "data_transfer",
      "title": "Lifeboat USB transfer to Mothership",
      "description": "Transfer scout_export archive to Mothership physical machine via USB. Verify checksums on arrival.",
      "status": "pending",
      "assigned_to": "DGANY"
    },
    {
      "id": "ACT-005",
      "priority": 5,
      "category": "knowledge_base",
      "title": "Francesca initial context load",
      "description": "Load consolidated device profile into Francesca for baseline context. This enables personalized assistance.",
      "status": "in_progress",
      "assigned_to": "Francesca"
    }
  ]
}
ENDJSON

echo "  Action items written: $KB_ACTIONS"

# ── Human-Readable Report ───────────────────────────────────────────────────
cat > "$KB_REPORT" <<ENDTXT
═══════════════════════════════════════════════════════════════════════════════
  YeahSo Network — Francesca Knowledge Base · Scout Device Profile
═══════════════════════════════════════════════════════════════════════════════

  Generated   : $TIMESTAMP
  Source Batch: $BATCH_ID
  KB Version  : $VERSION

───────────────────────────────────────────────────────────────────────────────
  DEVICE OVERVIEW
───────────────────────────────────────────────────────────────────────────────
  Role        : Scout Satellite
  ChromeOS    : $M01_CHROMEOS_VER ($M01_CHANNEL)
  Model       : $M01_MODEL
  CPU         : $M01_CPU
  RAM         : ${M01_RAM} GB
  Storage     : ${M01_STORAGE} GB local
  Crostini    : Debian $M01_DEBIAN ($M01_PKG_COUNT pkgs, $M01_DEVTOOLS_COUNT dev tools)
  Docker      : $M01_DOCKER
  Android     : detected=$M04_DETECTED, ver=$M04_ANDROID_VER, apps=$M04_USER_APPS user/$M04_SYSTEM_APPS system

───────────────────────────────────────────────────────────────────────────────
  BROWSER PROFILE
───────────────────────────────────────────────────────────────────────────────
  Browser     : $M02_BROWSER
  Bookmarks   : $M02_BOOKMARKS
  History     : $M02_HISTORY entries
  Credentials : $M02_PASSWORDS domains
  Autofill    : $M02_AUTOFILL entries
  Cookies     : $M02_COOKIES
  Search      : $M02_SEARCH
  Sync        : $M02_SYNC

───────────────────────────────────────────────────────────────────────────────
  DIGITAL ASSETS
───────────────────────────────────────────────────────────────────────────────
  Documents     : $M03_DOCS
  Data files    : $M03_DATA
  Presentations : $M03_PRES
  Code projects : $M03_CODE
  Images        : $M03_IMAGES
  Audio         : $M03_AUDIO
  Video         : $M03_VIDEO
  Archives      : $M03_ARCHIVES
  Home dir size : $M03_HOME_SIZE

───────────────────────────────────────────────────────────────────────────────
  GAP ANALYSIS — $GAPS_COUNT items need attention
───────────────────────────────────────────────────────────────────────────────
$(echo "$GAPS" | sed 's/},{/}\n{/g' | grep -oP '"field":"[^"]*".*?"note":"[^"]*"' | sed 's/"field":"//;s/","severity":"/  [/;s/","note":"/ ] /;s/"$//' | sed 's/^/  /' || echo "  No gaps")

───────────────────────────────────────────────────────────────────────────────
  NEXT ACTIONS
───────────────────────────────────────────────────────────────────────────────
  ACT-001 [P1] Re-run audit on physical Scout Chromebook
  ACT-002 [P2] Execute Google Takeout exports
  ACT-003 [P3] Install sqlite3 in Crostini
  ACT-004 [P4] Lifeboat USB transfer to Mothership
  ACT-005 [P5] Francesca initial context load

═══════════════════════════════════════════════════════════════════════════════
  End of Francesca Knowledge Base — Scout Device Profile
═══════════════════════════════════════════════════════════════════════════════
ENDTXT

echo "  Report written: $KB_REPORT"

# ── Checksums ────────────────────────────────────────────────────────────────
sha256sum "$KB_MANIFEST" "$KB_GAPS" "$KB_ACTIONS" "$KB_REPORT" > "$KB_SHA"
echo "  Checksums written: $KB_SHA"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Francesca Ingestion Complete"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Knowledge Base : $KB_DIR/"
echo "  Device Profile : $KB_MANIFEST"
echo "  Gap Analysis   : $KB_GAPS ($GAPS_COUNT gaps)"
echo "  Action Items   : $KB_ACTIONS"
echo "  Report         : $KB_REPORT"
echo ""
echo "  Francesca now has baseline context for the Scout device."
echo "═══════════════════════════════════════════════════════════════"
