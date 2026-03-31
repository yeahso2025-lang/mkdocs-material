#!/usr/bin/env bash
###############################################################################
# chromeos_android_audit.sh — Stage 4 of 4
# YeahSo Network · Scout Satellite · Android Subsystem Data Inventory
#
# Run inside Crostini (ChromeOS Linux container).
# Audits the Android (ARC++) subsystem: installed apps, app permissions,
# storage usage, accounts, shared storage, and Android system properties.
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
MODULE="module_04_android_data"
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

echo "═══════════════════════════════════════════════════════════════"
echo "  YeahSo Network — Scout Satellite Android Audit (Stage 4)"
echo "  Timestamp : $TIMESTAMP"
echo "  Output    : $STAGING_DIR/"
echo "═══════════════════════════════════════════════════════════════"
echo ""

###############################################################################
# 0. Detect Android Subsystem
###############################################################################
echo "[0/6] Detecting Android subsystem..."

ADB_AVAILABLE="false"
ADB_CONNECTED="false"
ANDROID_DETECTED="false"

if command -v adb &>/dev/null; then
    ADB_AVAILABLE="true"
    # Start ADB server if needed
    adb start-server 2>/dev/null || true
    if adb devices 2>/dev/null | grep -q "device$"; then
        ADB_CONNECTED="true"
        ANDROID_DETECTED="true"
        echo "  ADB available and connected"
    else
        log_err "ADB available but no Android device/container connected"
        echo "  ADB available but not connected"
    fi
else
    log_err "ADB not installed"
    echo "  ADB not available"
fi

# Check for ARC++ indicators even without ADB
if [ "$ANDROID_DETECTED" = "false" ]; then
    if pgrep -f "org.chromium.arc" &>/dev/null; then
        ANDROID_DETECTED="true"
        echo "  ARC++ process detected (no ADB)"
    elif [ -d "/opt/google/containers/android" ]; then
        ANDROID_DETECTED="true"
        echo "  Android container directory found (no ADB)"
    fi
fi

[ "$ANDROID_DETECTED" = "false" ] && echo "  No Android subsystem detected"
echo ""

###############################################################################
# 1. Installed Apps
###############################################################################
echo "[1/6] Collecting installed Android apps..."

APPS_JSON="[]"
APPS_USER_COUNT=0
APPS_SYSTEM_COUNT=0
APPS_TOTAL_COUNT=0

if [ "$ADB_CONNECTED" = "true" ]; then
    # User-installed apps
    USER_APPS_RAW=$(adb shell pm list packages -3 2>/dev/null | sed 's/package://' | sort || true)
    # System apps
    SYSTEM_APPS_RAW=$(adb shell pm list packages -s 2>/dev/null | sed 's/package://' | sort || true)

    APPS_USER_COUNT=$(echo "$USER_APPS_RAW" | grep -c . || echo 0)
    APPS_SYSTEM_COUNT=$(echo "$SYSTEM_APPS_RAW" | grep -c . || echo 0)
    APPS_TOTAL_COUNT=$((APPS_USER_COUNT + APPS_SYSTEM_COUNT))

    APPS_JSON="["
    first=true

    # Detailed info for user apps
    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | tr -d '\r\n ')
        [ -z "$pkg" ] && continue

        # Get version
        app_version=$(adb shell dumpsys package "$pkg" 2>/dev/null | grep "versionName" | head -1 | sed 's/.*versionName=//' | tr -d '\r' || echo "unknown")
        [ -z "$app_version" ] && app_version="unknown"

        # Get install date
        install_date=$(adb shell dumpsys package "$pkg" 2>/dev/null | grep "firstInstallTime" | head -1 | sed 's/.*firstInstallTime=//' | tr -d '\r' || echo "unknown")
        [ -z "$install_date" ] && install_date="unknown"

        # Get app size
        app_size=$(adb shell du -s "/data/data/$pkg" 2>/dev/null | awk '{print $1}' || echo "0")
        [ -z "$app_size" ] && app_size="0"

        $first || APPS_JSON+=","
        first=false
        APPS_JSON+="{\"package\":\"$(json_escape "$pkg")\",\"type\":\"user\",\"version\":\"$(json_escape "$app_version")\",\"installed\":\"$(json_escape "$install_date")\",\"size_kb\":$app_size}"

    done <<< "$USER_APPS_RAW"

    # System apps (package name only — skip detailed info to avoid slow queries)
    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | tr -d '\r\n ')
        [ -z "$pkg" ] && continue
        $first || APPS_JSON+=","
        first=false
        APPS_JSON+="{\"package\":\"$(json_escape "$pkg")\",\"type\":\"system\"}"
    done <<< "$SYSTEM_APPS_RAW"

    APPS_JSON+="]"
    echo "  User apps: $APPS_USER_COUNT, System apps: $APPS_SYSTEM_COUNT"
else
    log_err "App listing skipped — ADB not connected"
    echo "  App listing skipped (no ADB)"
fi

###############################################################################
# 2. App Permissions
###############################################################################
echo "[2/6] Collecting app permissions..."

PERMISSIONS_JSON="[]"
DANGEROUS_PERMS_COUNT=0

if [ "$ADB_CONNECTED" = "true" ] && [ -n "$USER_APPS_RAW" ]; then
    PERMISSIONS_JSON="["
    first=true

    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | tr -d '\r\n ')
        [ -z "$pkg" ] && continue

        # Get granted runtime permissions
        granted_perms=$(adb shell dumpsys package "$pkg" 2>/dev/null | grep "android.permission\." | grep "granted=true" | sed 's/.*: //;s/:.*//' | tr -d '\r' | sort -u || true)

        if [ -n "$granted_perms" ]; then
            perms_array="["
            pfirst=true
            while IFS= read -r perm; do
                [ -z "$perm" ] && continue
                $pfirst || perms_array+=","
                pfirst=false
                perms_array+="\"$(json_escape "$perm")\""
                DANGEROUS_PERMS_COUNT=$((DANGEROUS_PERMS_COUNT + 1))
            done <<< "$granted_perms"
            perms_array+="]"

            $first || PERMISSIONS_JSON+=","
            first=false
            PERMISSIONS_JSON+="{\"package\":\"$(json_escape "$pkg")\",\"granted_permissions\":$perms_array}"
        fi
    done <<< "$USER_APPS_RAW"

    PERMISSIONS_JSON+="]"
    echo "  Granted runtime permissions: $DANGEROUS_PERMS_COUNT across user apps"
else
    log_err "Permissions collection skipped — ADB not connected"
    echo "  Permissions collection skipped"
fi

###############################################################################
# 3. Android System Properties
###############################################################################
echo "[3/6] Collecting Android system properties..."

ANDROID_VERSION="unknown"
ANDROID_SDK="unknown"
ANDROID_BUILD="unknown"
ANDROID_SECURITY_PATCH="unknown"
ANDROID_DEVICE="unknown"

if [ "$ADB_CONNECTED" = "true" ]; then
    ANDROID_VERSION=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "unknown")
    ANDROID_SDK=$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || echo "unknown")
    ANDROID_BUILD=$(adb shell getprop ro.build.display.id 2>/dev/null | tr -d '\r' || echo "unknown")
    ANDROID_SECURITY_PATCH=$(adb shell getprop ro.build.version.security_patch 2>/dev/null | tr -d '\r' || echo "unknown")
    ANDROID_DEVICE=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "unknown")

    echo "  Android $ANDROID_VERSION (SDK $ANDROID_SDK), Patch: $ANDROID_SECURITY_PATCH"
else
    log_err "System properties skipped — ADB not connected"
    echo "  System properties skipped"
fi

###############################################################################
# 4. Android Accounts
###############################################################################
echo "[4/6] Collecting Android accounts..."

ANDROID_ACCOUNTS_JSON="[]"
ACCOUNTS_COUNT=0

if [ "$ADB_CONNECTED" = "true" ]; then
    ACCOUNTS_RAW=$(adb shell dumpsys account 2>/dev/null | grep -oP 'Account \{name=[^,]+, type=[^}]+\}' | head -50 || true)
    if [ -n "$ACCOUNTS_RAW" ]; then
        ANDROID_ACCOUNTS_JSON="["
        first=true
        while IFS= read -r acct_line; do
            [ -z "$acct_line" ] && continue
            acct_name=$(echo "$acct_line" | grep -oP 'name=[^,]+' | sed 's/name=//')
            acct_type=$(echo "$acct_line" | grep -oP 'type=[^}]+' | sed 's/type=//')
            $first || ANDROID_ACCOUNTS_JSON+=","
            first=false
            ANDROID_ACCOUNTS_JSON+="{\"name\":\"$(json_escape "$acct_name")\",\"type\":\"$(json_escape "$acct_type")\"}"
            ACCOUNTS_COUNT=$((ACCOUNTS_COUNT + 1))
        done <<< "$ACCOUNTS_RAW"
        ANDROID_ACCOUNTS_JSON+="]"
    fi
    echo "  Accounts found: $ACCOUNTS_COUNT"
else
    log_err "Account listing skipped — ADB not connected"
    echo "  Account listing skipped"
fi

###############################################################################
# 5. Android Storage
###############################################################################
echo "[5/6] Collecting Android storage info..."

ANDROID_STORAGE_TOTAL="unknown"
ANDROID_STORAGE_USED="unknown"
ANDROID_STORAGE_FREE="unknown"
SHARED_STORAGE_JSON="[]"

if [ "$ADB_CONNECTED" = "true" ]; then
    # Internal storage
    STORAGE_INFO=$(adb shell df /data 2>/dev/null | tail -1 || true)
    if [ -n "$STORAGE_INFO" ]; then
        ANDROID_STORAGE_TOTAL=$(echo "$STORAGE_INFO" | awk '{print $2}')
        ANDROID_STORAGE_USED=$(echo "$STORAGE_INFO" | awk '{print $3}')
        ANDROID_STORAGE_FREE=$(echo "$STORAGE_INFO" | awk '{print $4}')
    fi

    # Shared storage / SD card
    SHARED_RAW=$(adb shell sm list-volumes 2>/dev/null || true)
    if [ -n "$SHARED_RAW" ]; then
        SHARED_STORAGE_JSON="["
        first=true
        while IFS= read -r vol; do
            [ -z "$vol" ] && continue
            $first || SHARED_STORAGE_JSON+=","
            first=false
            SHARED_STORAGE_JSON+="\"$(json_escape "$vol")\""
        done <<< "$SHARED_RAW"
        SHARED_STORAGE_JSON+="]"
    fi

    echo "  Storage total: $ANDROID_STORAGE_TOTAL, Used: $ANDROID_STORAGE_USED, Free: $ANDROID_STORAGE_FREE"
else
    log_err "Storage info skipped — ADB not connected"
    echo "  Storage info skipped"
fi

# ChromeOS shared Android files (Play Files)
PLAY_FILES_SIZE="0"
PLAY_FILES_COUNT=0
for play_dir in "/mnt/chromeos/PlayFiles" "$HOME/.local/share/anthropic" "/mnt/user/0/android-data"; do
    if [ -d "$play_dir" ]; then
        PLAY_FILES_COUNT=$(find "$play_dir" -type f 2>/dev/null | wc -l)
        PLAY_FILES_SIZE=$(du -sh "$play_dir" 2>/dev/null | awk '{print $1}')
        break
    fi
done

###############################################################################
# 6. Running Android Services
###############################################################################
echo "[6/6] Collecting running Android services..."

ANDROID_SERVICES_JSON="[]"
SERVICES_COUNT=0

if [ "$ADB_CONNECTED" = "true" ]; then
    SERVICES_RAW=$(adb shell dumpsys activity services 2>/dev/null | grep "ServiceRecord" | head -50 | sed 's/.*ServiceRecord{[^ ]* [^ ]* //' | sed 's/}.*//' | sort -u || true)
    if [ -n "$SERVICES_RAW" ]; then
        ANDROID_SERVICES_JSON="["
        first=true
        while IFS= read -r svc; do
            svc=$(echo "$svc" | tr -d '\r')
            [ -z "$svc" ] && continue
            $first || ANDROID_SERVICES_JSON+=","
            first=false
            ANDROID_SERVICES_JSON+="\"$(json_escape "$svc")\""
            SERVICES_COUNT=$((SERVICES_COUNT + 1))
        done <<< "$SERVICES_RAW"
        ANDROID_SERVICES_JSON+="]"
    fi
    echo "  Running services: $SERVICES_COUNT"
else
    log_err "Service listing skipped — ADB not connected"
    echo "  Service listing skipped"
fi

echo ""
echo "Assembling JSON manifest..."

###############################################################################
# Assemble JSON Manifest
###############################################################################
cat > "$JSON_OUT" <<ENDJSON
{
  "yeahso_network": true,
  "scout_device": true,
  "audit_module": "android_data",
  "version": "$VERSION",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(json_escape "$HOSTNAME_VAL")",
  "collection_method": "Bash audit script via Crostini",
  "stage": "4 of 4",
  "android_subsystem": {
    "detected": $ANDROID_DETECTED,
    "adb_available": $ADB_AVAILABLE,
    "adb_connected": $ADB_CONNECTED,
    "android_version": "$(json_escape "$ANDROID_VERSION")",
    "sdk_version": "$(json_escape "$ANDROID_SDK")",
    "build_id": "$(json_escape "$ANDROID_BUILD")",
    "security_patch": "$(json_escape "$ANDROID_SECURITY_PATCH")",
    "device_model": "$(json_escape "$ANDROID_DEVICE")"
  },
  "installed_apps": {
    "user_count": $APPS_USER_COUNT,
    "system_count": $APPS_SYSTEM_COUNT,
    "total_count": $APPS_TOTAL_COUNT,
    "apps": $APPS_JSON
  },
  "permissions": {
    "total_granted_runtime": $DANGEROUS_PERMS_COUNT,
    "app_permissions": $PERMISSIONS_JSON
  },
  "accounts": {
    "count": $ACCOUNTS_COUNT,
    "accounts": $ANDROID_ACCOUNTS_JSON
  },
  "storage": {
    "internal_total": "$(json_escape "$ANDROID_STORAGE_TOTAL")",
    "internal_used": "$(json_escape "$ANDROID_STORAGE_USED")",
    "internal_free": "$(json_escape "$ANDROID_STORAGE_FREE")",
    "volumes": $SHARED_STORAGE_JSON,
    "play_files_count": $PLAY_FILES_COUNT,
    "play_files_size": "$(json_escape "$PLAY_FILES_SIZE")"
  },
  "services": {
    "running_count": $SERVICES_COUNT,
    "services": $ANDROID_SERVICES_JSON
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
  YeahSo Network — Scout Satellite Android Data Audit Report
  Stage 4 of 4: Android Data
═══════════════════════════════════════════════════════════════════════════════

  Generated : $TIMESTAMP
  Hostname  : $HOSTNAME_VAL
  Module    : android_data v$VERSION

───────────────────────────────────────────────────────────────────────────────
  1. Android Subsystem
───────────────────────────────────────────────────────────────────────────────
  Detected       : $ANDROID_DETECTED
  ADB Available  : $ADB_AVAILABLE
  ADB Connected  : $ADB_CONNECTED
  Android Version: $ANDROID_VERSION (SDK $ANDROID_SDK)
  Build          : $ANDROID_BUILD
  Security Patch : $ANDROID_SECURITY_PATCH
  Device Model   : $ANDROID_DEVICE

───────────────────────────────────────────────────────────────────────────────
  2. Installed Apps
───────────────────────────────────────────────────────────────────────────────
  User Apps      : $APPS_USER_COUNT
  System Apps    : $APPS_SYSTEM_COUNT
  Total          : $APPS_TOTAL_COUNT

───────────────────────────────────────────────────────────────────────────────
  3. Permissions
───────────────────────────────────────────────────────────────────────────────
  Granted Runtime Permissions: $DANGEROUS_PERMS_COUNT

───────────────────────────────────────────────────────────────────────────────
  4. Accounts
───────────────────────────────────────────────────────────────────────────────
  Connected      : $ACCOUNTS_COUNT

───────────────────────────────────────────────────────────────────────────────
  5. Storage
───────────────────────────────────────────────────────────────────────────────
  Internal Total : $ANDROID_STORAGE_TOTAL
  Internal Used  : $ANDROID_STORAGE_USED
  Internal Free  : $ANDROID_STORAGE_FREE
  Play Files     : $PLAY_FILES_COUNT files ($PLAY_FILES_SIZE)

───────────────────────────────────────────────────────────────────────────────
  6. Running Services
───────────────────────────────────────────────────────────────────────────────
  Count          : $SERVICES_COUNT

───────────────────────────────────────────────────────────────────────────────
  7. Errors
───────────────────────────────────────────────────────────────────────────────
$(cat "$ERR_LOG" 2>/dev/null || echo "  No errors logged.")

═══════════════════════════════════════════════════════════════════════════════
  End of Stage 4 Report — All stages complete!
  Transfer via Lifeboat USB to Mothership for Francesca ingestion
═══════════════════════════════════════════════════════════════════════════════
ENDTXT

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Audit Complete — Stage 4 of 4 (FINAL)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Output files:"
echo "    JSON manifest  : $JSON_OUT"
echo "    SHA256 sum     : $SHA_OUT"
echo "    Readable report: $TXT_OUT"
echo "    Error log      : $ERR_LOG"
echo ""
echo "  ALL 4 STAGES COMPLETE. Run satellite_export.sh to package"
echo "  the full audit for Lifeboat USB transfer to Mothership."
echo "═══════════════════════════════════════════════════════════════"
