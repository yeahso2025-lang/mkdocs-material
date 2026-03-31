#!/usr/bin/env bash
###############################################################################
# chromeos_scout_audit.sh — Stage 1 of 4
# YeahSo Network · Scout Satellite · ChromeOS Baseline Inventory
#
# Run inside Crostini (ChromeOS Linux container).
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
MODULE="module_01_chromeos_inventory"
JSON_OUT="$STAGING_DIR/${MODULE}.json"
SHA_OUT="$STAGING_DIR/${MODULE}.sha256"
TXT_OUT="$STAGING_DIR/${MODULE}.txt"
ERR_LOG="$STAGING_DIR/${MODULE}_errors.log"
TAKEOUT_JSON="$STAGING_DIR/takeout_checklist.json"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HOSTNAME_VAL="$(hostname 2>/dev/null || echo "chromeos-device")"
VERSION="1.0"

# ── Helpers ──────────────────────────────────────────────────────────────────
mkdir -p "$STAGING_DIR"
: > "$ERR_LOG"   # truncate error log

log_err() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ERROR: $*" >> "$ERR_LOG"
}

# Safe command runner — captures output or logs error, never crashes
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

# JSON-escape a string
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

echo "═══════════════════════════════════════════════════════════════"
echo "  YeahSo Network — Scout Satellite ChromeOS Audit (Stage 1)"
echo "  Timestamp : $TIMESTAMP"
echo "  Output    : $STAGING_DIR/"
echo "═══════════════════════════════════════════════════════════════"
echo ""

###############################################################################
# 1. ChromeOS System Information
###############################################################################
echo "[1/4] Collecting ChromeOS system information..."

# ChromeOS version & channel
CHROMEOS_VERSION=""
CHROMEOS_CHANNEL=""
if [ -f /etc/lsb-release ]; then
    CHROMEOS_VERSION=$(grep CHROMEOS_RELEASE_VERSION /etc/lsb-release 2>/dev/null | cut -d= -f2 || true)
    CHROMEOS_CHANNEL=$(grep CHROMEOS_RELEASE_TRACK /etc/lsb-release 2>/dev/null | cut -d= -f2 | sed 's/-channel//' || true)
fi
# Fallback: try reading from host via /mnt/host or crosh-style
if [ -z "$CHROMEOS_VERSION" ] && [ -f /mnt/stateful_partition/etc/lsb-release ]; then
    CHROMEOS_VERSION=$(grep CHROMEOS_RELEASE_VERSION /mnt/stateful_partition/etc/lsb-release 2>/dev/null | cut -d= -f2 || true)
    CHROMEOS_CHANNEL=$(grep CHROMEOS_RELEASE_TRACK /mnt/stateful_partition/etc/lsb-release 2>/dev/null | cut -d= -f2 | sed 's/-channel//' || true)
fi
if [ -z "$CHROMEOS_VERSION" ]; then
    # Try via garcon or host info
    CHROMEOS_VERSION=$(safe_run "chromeos-version" cat /etc/chromeos-version 2>/dev/null || echo "unknown")
    log_err "ChromeOS version not found via lsb-release; using fallback"
fi
[ -z "$CHROMEOS_VERSION" ] && CHROMEOS_VERSION="unknown"
[ -z "$CHROMEOS_CHANNEL" ] && CHROMEOS_CHANNEL="unknown"

# Device model
DEVICE_MODEL=$(safe_run "device-model" cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)
[ -z "$DEVICE_MODEL" ] && DEVICE_MODEL=$(safe_run "device-model-alt" cat /sys/class/dmi/id/product_name 2>/dev/null)
[ -z "$DEVICE_MODEL" ] && DEVICE_MODEL="unknown"

# Hardware specs
CPU_INFO=$(safe_run "cpu-info" grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
[ -z "$CPU_INFO" ] && CPU_INFO="unknown"
RAM_KB=$(safe_run "ram-info" grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
RAM_GB="0"
if [ -n "$RAM_KB" ] && [ "$RAM_KB" -gt 0 ] 2>/dev/null; then
    RAM_GB=$(awk "BEGIN {printf \"%.1f\", $RAM_KB/1048576}")
fi

# Storage breakdown
STORAGE_LOCAL_GB="0"
STORAGE_GDRIVE_GB="0"
if command -v df &>/dev/null; then
    # Root filesystem size in GB
    STORAGE_LOCAL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}' || echo "0")
    # Check for Google Drive mount
    GDRIVE_MOUNT=$(df -BG 2>/dev/null | grep -i "google\|drivefs\|fuse" | awk '{gsub(/G/,"",$2); total+=$2} END {print total+0}' || echo "0")
    [ -n "$GDRIVE_MOUNT" ] && STORAGE_GDRIVE_GB="$GDRIVE_MOUNT"
fi

# Android subsystem status
ANDROID_ENABLED="false"
if pgrep -f "org.chromium.arc" &>/dev/null || [ -d /opt/google/containers/android ] 2>/dev/null; then
    ANDROID_ENABLED="true"
elif command -v adb &>/dev/null && adb devices 2>/dev/null | grep -q "device$"; then
    ANDROID_ENABLED="true"
fi

# Crostini status
CROSTINI_ENABLED="true"  # If this script is running, Crostini is enabled
CROSTINI_DEBIAN_VERSION=$(safe_run "debian-version" cat /etc/debian_version 2>/dev/null)
[ -z "$CROSTINI_DEBIAN_VERSION" ] && CROSTINI_DEBIAN_VERSION=$(safe_run "os-release" grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
[ -z "$CROSTINI_DEBIAN_VERSION" ] && CROSTINI_DEBIAN_VERSION="unknown"

echo "  ChromeOS $CHROMEOS_VERSION ($CHROMEOS_CHANNEL), Model: $DEVICE_MODEL"

###############################################################################
# 2. Google Ecosystem Inventory
###############################################################################
echo "[2/4] Collecting Google ecosystem inventory..."

# Chrome extensions — scan known Crostini-accessible extension paths
EXTENSIONS_JSON="[]"
CHROME_EXT_DIR="$HOME/.config/google-chrome/Default/Extensions"
CHROMIUM_EXT_DIR="$HOME/.config/chromium/Default/Extensions"

collect_extensions() {
    local ext_base="$1"
    local result="["
    local first=true
    if [ -d "$ext_base" ]; then
        for ext_id_dir in "$ext_base"/*/; do
            [ -d "$ext_id_dir" ] || continue
            local ext_id
            ext_id=$(basename "$ext_id_dir")
            # Find the latest version directory
            local latest_ver_dir
            latest_ver_dir=$(ls -1d "$ext_id_dir"*/ 2>/dev/null | sort -V | tail -1)
            [ -d "$latest_ver_dir" ] || continue
            local manifest_file="$latest_ver_dir/manifest.json"
            if [ -f "$manifest_file" ]; then
                local ext_name ext_version ext_perms
                # Parse manifest.json with basic tools (no jq dependency)
                ext_name=$(grep -oP '"name"\s*:\s*"[^"]*"' "$manifest_file" 2>/dev/null | head -1 | sed 's/"name"\s*:\s*"//;s/"$//' || echo "unknown")
                ext_version=$(grep -oP '"version"\s*:\s*"[^"]*"' "$manifest_file" 2>/dev/null | head -1 | sed 's/"version"\s*:\s*"//;s/"$//' || echo "unknown")
                ext_perms=$(grep -oP '"permissions"\s*:\s*\[[^\]]*\]' "$manifest_file" 2>/dev/null | head -1 || echo "[]")
                [ -z "$ext_perms" ] && ext_perms="[]"
                # Strip __MSG_ wrappers from name
                if [[ "$ext_name" == __MSG_* ]]; then
                    ext_name="$ext_id"
                fi
                $first || result+=","
                first=false
                result+="{\"id\":\"$(json_escape "$ext_id")\",\"name\":\"$(json_escape "$ext_name")\",\"version\":\"$(json_escape "$ext_version")\"}"
            fi
        done
    fi
    result+="]"
    echo "$result"
}

if [ -d "$CHROME_EXT_DIR" ]; then
    EXTENSIONS_JSON=$(collect_extensions "$CHROME_EXT_DIR")
elif [ -d "$CHROMIUM_EXT_DIR" ]; then
    EXTENSIONS_JSON=$(collect_extensions "$CHROMIUM_EXT_DIR")
else
    log_err "Chrome extensions directory not accessible from Crostini"
    EXTENSIONS_JSON="[]"
fi

# Chrome apps — check Preferences file
CHROME_APPS_JSON="[]"
for prefs_file in "$HOME/.config/google-chrome/Default/Preferences" "$HOME/.config/chromium/Default/Preferences"; do
    if [ -f "$prefs_file" ]; then
        # Extract app names if possible
        CHROME_APPS_JSON=$(grep -oP '"name"\s*:\s*"[^"]*"' "$prefs_file" 2>/dev/null | head -20 | sed 's/"name"\s*:\s*"//;s/"$//' | awk 'BEGIN{printf "["}{if(NR>1)printf ","; printf "\"%s\"", $0}END{printf "]"}' || echo "[]")
        break
    fi
done

# Android apps via ADB
ANDROID_APPS_JSON="[]"
if command -v adb &>/dev/null; then
    if adb devices 2>/dev/null | grep -q "device$"; then
        ANDROID_APPS_RAW=$(adb shell pm list packages 2>/dev/null | sed 's/package://' | sort || true)
        if [ -n "$ANDROID_APPS_RAW" ]; then
            ANDROID_APPS_JSON=$(echo "$ANDROID_APPS_RAW" | awk 'BEGIN{printf "["}{if(NR>1)printf ","; gsub(/\r/,""); printf "\"%s\"", $0}END{printf "]"}')
        fi
    else
        log_err "ADB available but no device connected — skipping Android app listing"
    fi
else
    log_err "ADB not available — skipping Android app listing"
fi

# Google accounts — check for known account indicator files
ACCOUNTS_JSON="[]"
for acct_file in "$HOME/.config/google-chrome/Default/Preferences" "$HOME/.config/chromium/Default/Preferences"; do
    if [ -f "$acct_file" ]; then
        ACCTS=$(grep -oP '"email"\s*:\s*"[^"]*@[^"]*"' "$acct_file" 2>/dev/null | sed 's/"email"\s*:\s*"//;s/"$//' | sort -u | awk 'BEGIN{printf "["}{if(NR>1)printf ","; printf "\"%s\"", $0}END{printf "]"}' || echo "[]")
        [ "$ACCTS" != "[]" ] && ACCOUNTS_JSON="$ACCTS"
        break
    fi
done

# Google Drive usage — check mount if accessible
GDRIVE_USAGE_GB="0"
GDRIVE_PATH="$HOME/Google Drive"
[ -d "$GDRIVE_PATH" ] || GDRIVE_PATH="/mnt/chromeos/GoogleDrive"
if [ -d "$GDRIVE_PATH" ]; then
    GDRIVE_USAGE_GB=$(du -sBG "$GDRIVE_PATH" 2>/dev/null | awk '{gsub(/G/,"",$1); print $1}' || echo "0")
fi

echo "  Extensions found, Android ADB: $(command -v adb &>/dev/null && echo 'available' || echo 'not available')"

###############################################################################
# 3. Crostini Linux Container Audit
###############################################################################
echo "[3/4] Auditing Crostini Linux container..."

# Installed packages
PACKAGES_JSON="[]"
if command -v dpkg &>/dev/null; then
    PACKAGES_RAW=$(dpkg --list 2>/dev/null | awk '/^ii/ {printf "{\"name\":\"%s\",\"version\":\"%s\"},", $2, $3}' || true)
    if [ -n "$PACKAGES_RAW" ]; then
        PACKAGES_JSON="[${PACKAGES_RAW%,}]"
    fi
else
    log_err "dpkg not available"
fi

# Running services
SERVICES_JSON="[]"
if command -v systemctl &>/dev/null; then
    SERVICES_RAW=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{printf "\"%s\",", $1}' || true)
    [ -n "$SERVICES_RAW" ] && SERVICES_JSON="[${SERVICES_RAW%,}]"
else
    # Fallback to init-style listing
    SERVICES_RAW=$(service --status-all 2>/dev/null | grep "+ " | awk '{printf "\"%s\",", $NF}' || true)
    [ -n "$SERVICES_RAW" ] && SERVICES_JSON="[${SERVICES_RAW%,}]"
fi

# Development tools
DEV_TOOLS_JSON="["
DEV_FIRST=true
check_dev_tool() {
    local tool="$1"
    local ver_flag="${2:---version}"
    if command -v "$tool" &>/dev/null; then
        local ver
        ver=$("$tool" "$ver_flag" 2>&1 | head -1 || echo "installed")
        $DEV_FIRST || DEV_TOOLS_JSON+=","
        DEV_FIRST=false
        DEV_TOOLS_JSON+="{\"tool\":\"$(json_escape "$tool")\",\"version\":\"$(json_escape "$ver")\"}"
    fi
}
check_dev_tool python3 --version
check_dev_tool python --version
check_dev_tool node --version
check_dev_tool npm --version
check_dev_tool git --version
check_dev_tool gcc --version
check_dev_tool g++ --version
check_dev_tool make --version
check_dev_tool cmake --version
check_dev_tool java -version
check_dev_tool go version
check_dev_tool rustc --version
check_dev_tool cargo --version
check_dev_tool docker --version
check_dev_tool code --version
DEV_TOOLS_JSON+="]"

# Docker check
DOCKER_INSTALLED="false"
command -v docker &>/dev/null && DOCKER_INSTALLED="true"

# Disk usage
CROSTINI_DISK_GB="0"
if command -v df &>/dev/null; then
    CROSTINI_DISK_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$3); print $3}' || echo "0")
fi

echo "  Packages: $(dpkg --list 2>/dev/null | grep -c '^ii' || echo 0), Docker: $DOCKER_INSTALLED"

###############################################################################
# 4. Google Takeout Export Checklist
###############################################################################
echo "[4/4] Generating Takeout export checklist..."

TAKEOUT_CHECKLIST='{
  "yeahso_network": true,
  "scout_device": true,
  "audit_module": "takeout_checklist",
  "version": "'"$VERSION"'",
  "timestamp": "'"$TIMESTAMP"'",
  "export_format": "zip",
  "max_split_size_gb": 2,
  "usb_lifeboat_compatible": true,
  "products": [
    {
      "name": "Gemini",
      "product_id": "gemini",
      "priority": 1,
      "status": "pending",
      "takeout_url": "https://takeout.google.com",
      "notes": "Export all Gemini conversation history and saved prompts",
      "estimated_size": "varies"
    },
    {
      "name": "NotebookLM",
      "product_id": "notebooklm",
      "priority": 2,
      "status": "pending",
      "takeout_url": "https://takeout.google.com",
      "notes": "Export all notebooks, sources, and generated summaries",
      "estimated_size": "varies"
    },
    {
      "name": "Chrome",
      "product_id": "chrome",
      "priority": 3,
      "status": "pending",
      "takeout_url": "https://takeout.google.com",
      "notes": "Export bookmarks, history, passwords, autofill, extensions list",
      "estimated_size": "varies"
    },
    {
      "name": "Google Keep",
      "product_id": "google_keep",
      "priority": 4,
      "status": "pending",
      "takeout_url": "https://takeout.google.com",
      "notes": "Export all notes, labels, images, audio recordings",
      "estimated_size": "varies"
    },
    {
      "name": "Google Drive",
      "product_id": "google_drive",
      "priority": 5,
      "status": "pending",
      "takeout_url": "https://takeout.google.com",
      "notes": "Export all files; use 2GB zip splits for USB compatibility",
      "estimated_size": "varies"
    }
  ],
  "instructions": [
    "1. Go to https://takeout.google.com on the Scout device",
    "2. Deselect all products, then select only the target products above",
    "3. Choose export format: .zip, max 2GB per file",
    "4. Choose delivery method: Download link (do NOT use Drive or email)",
    "5. Download each export to ~/yeahso_audit_staging/takeout/",
    "6. Verify checksums before USB transfer to Mothership",
    "7. DGANY manually enters credentials — no stored passwords"
  ]
}'

echo "$TAKEOUT_CHECKLIST" > "$TAKEOUT_JSON"
echo "  Takeout checklist written to $TAKEOUT_JSON"

###############################################################################
# Assemble JSON Manifest
###############################################################################
echo ""
echo "Assembling JSON manifest..."

cat > "$JSON_OUT" <<ENDJSON
{
  "yeahso_network": true,
  "scout_device": true,
  "audit_module": "chromeos_inventory",
  "version": "$VERSION",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(json_escape "$HOSTNAME_VAL")",
  "collection_method": "Bash audit script via Crostini",
  "stage": "1 of 4",
  "chromeos_system": {
    "version": "$(json_escape "$CHROMEOS_VERSION")",
    "channel": "$(json_escape "$CHROMEOS_CHANNEL")",
    "device_model": "$(json_escape "$DEVICE_MODEL")",
    "cpu": "$(json_escape "$CPU_INFO")",
    "ram_gb": $RAM_GB,
    "storage_local_gb": $STORAGE_LOCAL_GB,
    "storage_gdrive_gb": $STORAGE_GDRIVE_GB,
    "android_enabled": $ANDROID_ENABLED,
    "crostini_enabled": $CROSTINI_ENABLED
  },
  "google_ecosystem": {
    "accounts_connected": $ACCOUNTS_JSON,
    "chrome_extensions": $EXTENSIONS_JSON,
    "chrome_apps": $CHROME_APPS_JSON,
    "android_apps": $ANDROID_APPS_JSON,
    "gdrive_usage_gb": $GDRIVE_USAGE_GB
  },
  "crostini_linux": {
    "debian_version": "$(json_escape "$CROSTINI_DEBIAN_VERSION")",
    "installed_packages": $PACKAGES_JSON,
    "running_services": $SERVICES_JSON,
    "dev_tools": $DEV_TOOLS_JSON,
    "docker_installed": $DOCKER_INSTALLED,
    "disk_usage_gb": $CROSTINI_DISK_GB
  },
  "takeout_checklist": {
    "gemini": {"status": "pending", "priority": 1},
    "notebooklm": {"status": "pending", "priority": 2},
    "chrome": {"status": "pending", "priority": 3},
    "google_keep": {"status": "pending", "priority": 4},
    "google_drive": {"status": "pending", "priority": 5}
  }
}
ENDJSON

###############################################################################
# Generate SHA256 Checksum
###############################################################################
sha256sum "$JSON_OUT" > "$SHA_OUT"
sha256sum "$TAKEOUT_JSON" >> "$SHA_OUT"
echo "  SHA256 checksums written to $SHA_OUT"

###############################################################################
# Generate Human-Readable Report
###############################################################################
cat > "$TXT_OUT" <<ENDTXT
═══════════════════════════════════════════════════════════════════════════════
  YeahSo Network — Scout Satellite ChromeOS Baseline Audit Report
  Stage 1 of 4: ChromeOS Inventory
═══════════════════════════════════════════════════════════════════════════════

  Generated : $TIMESTAMP
  Hostname  : $HOSTNAME_VAL
  Module    : chromeos_inventory v$VERSION

───────────────────────────────────────────────────────────────────────────────
  1. ChromeOS System
───────────────────────────────────────────────────────────────────────────────
  Version       : $CHROMEOS_VERSION
  Channel       : $CHROMEOS_CHANNEL
  Device Model  : $DEVICE_MODEL
  CPU           : $CPU_INFO
  RAM           : ${RAM_GB} GB
  Local Storage : ${STORAGE_LOCAL_GB} GB
  GDrive Storage: ${STORAGE_GDRIVE_GB} GB
  Android       : $ANDROID_ENABLED
  Crostini      : $CROSTINI_ENABLED

───────────────────────────────────────────────────────────────────────────────
  2. Google Ecosystem
───────────────────────────────────────────────────────────────────────────────
  Accounts      : $ACCOUNTS_JSON
  Extensions    : $(echo "$EXTENSIONS_JSON" | grep -o '"name"' | wc -l) found
  Chrome Apps   : $(echo "$CHROME_APPS_JSON" | grep -o '"' | wc -l | awk '{print int($1/2)}') found
  Android Apps  : $(echo "$ANDROID_APPS_JSON" | grep -o '"' | wc -l | awk '{print int($1/2)}') found
  GDrive Usage  : ${GDRIVE_USAGE_GB} GB

───────────────────────────────────────────────────────────────────────────────
  3. Crostini Linux Container
───────────────────────────────────────────────────────────────────────────────
  Debian Version: $CROSTINI_DEBIAN_VERSION
  Packages      : $(echo "$PACKAGES_JSON" | grep -o '"name"' | wc -l) installed
  Services      : $(echo "$SERVICES_JSON" | grep -o '"' | wc -l | awk '{print int($1/2)}') running
  Docker        : $DOCKER_INSTALLED
  Disk Used     : ${CROSTINI_DISK_GB} GB

───────────────────────────────────────────────────────────────────────────────
  4. Takeout Export Checklist
───────────────────────────────────────────────────────────────────────────────
  Priority 1: Gemini          [PENDING]
  Priority 2: NotebookLM      [PENDING]
  Priority 3: Chrome           [PENDING]
  Priority 4: Google Keep      [PENDING]
  Priority 5: Google Drive     [PENDING]

  Format: .zip, 2GB max splits, USB Lifeboat compatible

───────────────────────────────────────────────────────────────────────────────
  5. Errors
───────────────────────────────────────────────────────────────────────────────
$(cat "$ERR_LOG" 2>/dev/null || echo "  No errors logged.")

═══════════════════════════════════════════════════════════════════════════════
  End of Stage 1 Report — Transfer via Lifeboat USB to Mothership
═══════════════════════════════════════════════════════════════════════════════
ENDTXT

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Audit Complete — Stage 1 of 4"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Output files:"
echo "    JSON manifest  : $JSON_OUT"
echo "    SHA256 sums    : $SHA_OUT"
echo "    Readable report: $TXT_OUT"
echo "    Error log      : $ERR_LOG"
echo "    Takeout checklist: $TAKEOUT_JSON"
echo ""
echo "  Next: Run satellite_export.sh to package for Lifeboat USB"
echo "═══════════════════════════════════════════════════════════════"
