#!/usr/bin/env bash
###############################################################################
# chromeos_browser_audit.sh — Stage 2 of 4
# YeahSo Network · Scout Satellite · Browser Data Inventory
#
# Run inside Crostini (ChromeOS Linux container).
# Collects Chrome/Chromium browser data: bookmarks, history, extensions,
# saved passwords (metadata only — NO plaintext), autofill, preferences,
# local storage summary, cookies summary, and session data.
#
# Produces JSON manifest, SHA256 checksum, human-readable report, error log.
#
# Standing rules:
#   - Air-gap first — no network transfers, no cloud sync, no SSH
#   - USB Lifeboat only for data movement
#   - No AI processing on satellite
#   - All credentials entered offline by DGANY only
#   - NO plaintext passwords or sensitive tokens extracted
###############################################################################
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
STAGING_DIR="$HOME/yeahso_audit_staging"
MODULE="module_02_browser_data"
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

# Detect browser profile directory
detect_browser_profile() {
    local candidates=(
        "$HOME/.config/google-chrome/Default"
        "$HOME/.config/google-chrome/Profile 1"
        "$HOME/.config/chromium/Default"
        "$HOME/.config/chromium/Profile 1"
        "$HOME/snap/chromium/common/chromium/Default"
    )
    for dir in "${candidates[@]}"; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    echo ""
    return 1
}

# SQLite query helper — uses sqlite3 if available, logs error otherwise
sql_query() {
    local label="$1"
    local db_path="$2"
    local query="$3"
    if ! command -v sqlite3 &>/dev/null; then
        log_err "$label — sqlite3 not installed"
        echo ""
        return
    fi
    if [ ! -f "$db_path" ]; then
        log_err "$label — database not found: $db_path"
        echo ""
        return
    fi
    # Copy DB to temp to avoid locking issues with running browser
    local tmp_db
    tmp_db=$(mktemp /tmp/browser_audit_XXXXXX.db)
    cp "$db_path" "$tmp_db" 2>/dev/null
    # Also copy WAL/SHM if present
    [ -f "${db_path}-wal" ] && cp "${db_path}-wal" "${tmp_db}-wal" 2>/dev/null || true
    [ -f "${db_path}-shm" ] && cp "${db_path}-shm" "${tmp_db}-shm" 2>/dev/null || true
    local result
    if result=$(sqlite3 -separator '	' "$tmp_db" "$query" 2>&1); then
        rm -f "$tmp_db" "${tmp_db}-wal" "${tmp_db}-shm"
        echo "$result"
    else
        log_err "$label — query failed: $result"
        rm -f "$tmp_db" "${tmp_db}-wal" "${tmp_db}-shm"
        echo ""
    fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "  YeahSo Network — Scout Satellite Browser Audit (Stage 2)"
echo "  Timestamp : $TIMESTAMP"
echo "  Output    : $STAGING_DIR/"
echo "═══════════════════════════════════════════════════════════════"
echo ""

###############################################################################
# 0. Detect Browser Profile
###############################################################################
echo "[0/6] Detecting browser profile..."

PROFILE_DIR=$(detect_browser_profile || true)
BROWSER_NAME="unknown"
if [ -n "$PROFILE_DIR" ]; then
    if [[ "$PROFILE_DIR" == *"google-chrome"* ]]; then
        BROWSER_NAME="Google Chrome"
    elif [[ "$PROFILE_DIR" == *"chromium"* ]]; then
        BROWSER_NAME="Chromium"
    fi
    echo "  Found: $BROWSER_NAME at $PROFILE_DIR"
else
    log_err "No Chrome/Chromium profile directory found"
    echo "  No browser profile found — will collect what's available"
    PROFILE_DIR=""
fi

SQLITE3_AVAILABLE="false"
command -v sqlite3 &>/dev/null && SQLITE3_AVAILABLE="true"
echo "  sqlite3 available: $SQLITE3_AVAILABLE"
echo ""

###############################################################################
# 1. Bookmarks
###############################################################################
echo "[1/6] Collecting bookmarks..."

BOOKMARKS_JSON="[]"
BOOKMARKS_COUNT=0
BOOKMARKS_FILE="${PROFILE_DIR:+$PROFILE_DIR/Bookmarks}"

parse_bookmarks() {
    local bk_file="$1"
    # Extract bookmark URLs and names using grep/sed (no jq dependency)
    # Bookmarks file is JSON — extract name/url pairs
    local result="["
    local first=true
    while IFS= read -r line; do
        local name url
        name=$(echo "$line" | sed 's/.*"name": *"//;s/".*//')
        # Read next relevant line for URL
        url=$(echo "$line" | sed 's/.*"url": *"//;s/".*//')
        if [ -n "$url" ] && [[ "$url" == http* ]]; then
            $first || result+=","
            first=false
            result+="{\"name\":\"$(json_escape "$name")\",\"url\":\"$(json_escape "$url")\"}"
        fi
    done < <(grep -B1 '"url"' "$bk_file" 2>/dev/null | paste - - | head -500)
    result+="]"
    echo "$result"
}

if [ -n "$PROFILE_DIR" ] && [ -f "$PROFILE_DIR/Bookmarks" ]; then
    BOOKMARKS_JSON=$(parse_bookmarks "$PROFILE_DIR/Bookmarks")
    BOOKMARKS_COUNT=$(echo "$BOOKMARKS_JSON" | grep -o '"url"' | wc -l)
    echo "  Bookmarks extracted: $BOOKMARKS_COUNT"
else
    log_err "Bookmarks file not found"
    echo "  Bookmarks file not found"
fi

###############################################################################
# 2. Browsing History
###############################################################################
echo "[2/6] Collecting browsing history..."

HISTORY_COUNT=0
HISTORY_TOP_SITES_JSON="[]"
HISTORY_TOTAL=0
HISTORY_DATE_RANGE="unknown"

if [ -n "$PROFILE_DIR" ] && [ "$SQLITE3_AVAILABLE" = "true" ]; then
    HISTORY_DB="$PROFILE_DIR/History"

    # Total visit count
    HISTORY_TOTAL=$(sql_query "history-total" "$HISTORY_DB" \
        "SELECT COUNT(*) FROM urls;" 2>/dev/null)
    [ -z "$HISTORY_TOTAL" ] && HISTORY_TOTAL=0

    # Date range
    HISTORY_OLDEST=$(sql_query "history-oldest" "$HISTORY_DB" \
        "SELECT datetime(MIN(last_visit_time)/1000000-11644473600,'unixepoch') FROM urls WHERE last_visit_time > 0;" 2>/dev/null)
    HISTORY_NEWEST=$(sql_query "history-newest" "$HISTORY_DB" \
        "SELECT datetime(MAX(last_visit_time)/1000000-11644473600,'unixepoch') FROM urls WHERE last_visit_time > 0;" 2>/dev/null)
    [ -n "$HISTORY_OLDEST" ] && [ -n "$HISTORY_NEWEST" ] && HISTORY_DATE_RANGE="${HISTORY_OLDEST} to ${HISTORY_NEWEST}"

    # Top 25 most visited sites (domain-level, no full URLs for privacy)
    TOP_SITES_RAW=$(sql_query "history-top-sites" "$HISTORY_DB" \
        "SELECT REPLACE(REPLACE(REPLACE(url, 'https://', ''), 'http://', ''), 'www.', '') AS domain, SUM(visit_count) AS visits FROM urls GROUP BY SUBSTR(domain, 1, INSTR(domain || '/', '/') - 1) ORDER BY visits DESC LIMIT 25;" 2>/dev/null)

    if [ -n "$TOP_SITES_RAW" ]; then
        HISTORY_TOP_SITES_JSON="["
        first=true
        while IFS=$'\t' read -r domain visits; do
            # Extract just the domain portion
            clean_domain=$(echo "$domain" | cut -d'/' -f1)
            [ -z "$clean_domain" ] && continue
            $first || HISTORY_TOP_SITES_JSON+=","
            first=false
            HISTORY_TOP_SITES_JSON+="{\"domain\":\"$(json_escape "$clean_domain")\",\"visits\":$visits}"
        done <<< "$TOP_SITES_RAW"
        HISTORY_TOP_SITES_JSON+="]"
    fi

    HISTORY_COUNT=$HISTORY_TOTAL
    echo "  History entries: $HISTORY_TOTAL, Range: $HISTORY_DATE_RANGE"
else
    log_err "History collection skipped — profile or sqlite3 unavailable"
    echo "  History collection skipped"
fi

###############################################################################
# 3. Saved Passwords (metadata only — NO plaintext)
###############################################################################
echo "[3/6] Collecting saved password metadata (NO plaintext)..."

PASSWORDS_COUNT=0
PASSWORDS_DOMAINS_JSON="[]"

if [ -n "$PROFILE_DIR" ] && [ "$SQLITE3_AVAILABLE" = "true" ]; then
    LOGIN_DB="$PROFILE_DIR/Login Data"

    # Count saved credentials
    PASSWORDS_COUNT=$(sql_query "passwords-count" "$LOGIN_DB" \
        "SELECT COUNT(*) FROM logins;" 2>/dev/null)
    [ -z "$PASSWORDS_COUNT" ] && PASSWORDS_COUNT=0

    # List domains with saved passwords (NO usernames, NO passwords)
    PASSWORDS_DOMAINS_RAW=$(sql_query "passwords-domains" "$LOGIN_DB" \
        "SELECT DISTINCT origin_url FROM logins ORDER BY origin_url LIMIT 100;" 2>/dev/null)

    if [ -n "$PASSWORDS_DOMAINS_RAW" ]; then
        PASSWORDS_DOMAINS_JSON="["
        first=true
        while IFS= read -r origin; do
            [ -z "$origin" ] && continue
            # Extract domain only for privacy
            domain=$(echo "$origin" | sed 's|https\?://||;s|/.*||;s|www\.||')
            $first || PASSWORDS_DOMAINS_JSON+=","
            first=false
            PASSWORDS_DOMAINS_JSON+="\"$(json_escape "$domain")\""
        done <<< "$PASSWORDS_DOMAINS_RAW"
        PASSWORDS_DOMAINS_JSON+="]"
    fi

    echo "  Saved credentials: $PASSWORDS_COUNT domains"
else
    log_err "Login Data collection skipped — profile or sqlite3 unavailable"
    echo "  Password metadata collection skipped"
fi

###############################################################################
# 4. Autofill Data
###############################################################################
echo "[4/6] Collecting autofill summary..."

AUTOFILL_COUNT=0
AUTOFILL_ADDRESSES=0
AUTOFILL_CREDIT_CARDS=0

if [ -n "$PROFILE_DIR" ] && [ "$SQLITE3_AVAILABLE" = "true" ]; then
    WEBDATA_DB="$PROFILE_DIR/Web Data"

    # Autofill entry count
    AUTOFILL_COUNT=$(sql_query "autofill-count" "$WEBDATA_DB" \
        "SELECT COUNT(*) FROM autofill;" 2>/dev/null)
    [ -z "$AUTOFILL_COUNT" ] && AUTOFILL_COUNT=0

    # Address count
    AUTOFILL_ADDRESSES=$(sql_query "autofill-addresses" "$WEBDATA_DB" \
        "SELECT COUNT(*) FROM autofill_profiles;" 2>/dev/null)
    [ -z "$AUTOFILL_ADDRESSES" ] && AUTOFILL_ADDRESSES=0

    # Credit card count (metadata only — NO card numbers)
    AUTOFILL_CREDIT_CARDS=$(sql_query "autofill-cards" "$WEBDATA_DB" \
        "SELECT COUNT(*) FROM credit_cards;" 2>/dev/null)
    [ -z "$AUTOFILL_CREDIT_CARDS" ] && AUTOFILL_CREDIT_CARDS=0

    echo "  Autofill entries: $AUTOFILL_COUNT, Addresses: $AUTOFILL_ADDRESSES, Cards: $AUTOFILL_CREDIT_CARDS"
else
    log_err "Autofill collection skipped — profile or sqlite3 unavailable"
    echo "  Autofill collection skipped"
fi

###############################################################################
# 5. Cookies & Local Storage Summary
###############################################################################
echo "[5/6] Collecting cookies and local storage summary..."

COOKIES_COUNT=0
COOKIES_DOMAINS_COUNT=0
LOCAL_STORAGE_SIZE="0"

if [ -n "$PROFILE_DIR" ] && [ "$SQLITE3_AVAILABLE" = "true" ]; then
    COOKIES_DB="$PROFILE_DIR/Cookies"

    # Total cookies
    COOKIES_COUNT=$(sql_query "cookies-count" "$COOKIES_DB" \
        "SELECT COUNT(*) FROM cookies;" 2>/dev/null)
    [ -z "$COOKIES_COUNT" ] && COOKIES_COUNT=0

    # Unique domains with cookies
    COOKIES_DOMAINS_COUNT=$(sql_query "cookies-domains" "$COOKIES_DB" \
        "SELECT COUNT(DISTINCT host_key) FROM cookies;" 2>/dev/null)
    [ -z "$COOKIES_DOMAINS_COUNT" ] && COOKIES_DOMAINS_COUNT=0

    echo "  Cookies: $COOKIES_COUNT across $COOKIES_DOMAINS_COUNT domains"
else
    log_err "Cookies collection skipped — profile or sqlite3 unavailable"
    echo "  Cookies collection skipped"
fi

# Local Storage directory size
if [ -n "$PROFILE_DIR" ] && [ -d "$PROFILE_DIR/Local Storage" ]; then
    LOCAL_STORAGE_SIZE=$(du -sh "$PROFILE_DIR/Local Storage" 2>/dev/null | awk '{print $1}')
    echo "  Local Storage size: $LOCAL_STORAGE_SIZE"
else
    log_err "Local Storage directory not found"
    echo "  Local Storage not found"
fi

# Session Storage
SESSION_STORAGE_SIZE="0"
if [ -n "$PROFILE_DIR" ] && [ -d "$PROFILE_DIR/Session Storage" ]; then
    SESSION_STORAGE_SIZE=$(du -sh "$PROFILE_DIR/Session Storage" 2>/dev/null | awk '{print $1}')
fi

# IndexedDB
INDEXEDDB_SIZE="0"
if [ -n "$PROFILE_DIR" ] && [ -d "$PROFILE_DIR/IndexedDB" ]; then
    INDEXEDDB_SIZE=$(du -sh "$PROFILE_DIR/IndexedDB" 2>/dev/null | awk '{print $1}')
fi

# Cache size
CACHE_SIZE="0"
for cache_dir in "$PROFILE_DIR/Cache" "$PROFILE_DIR/Code Cache" "${PROFILE_DIR%/*}/ShaderCache"; do
    if [ -d "$cache_dir" ] 2>/dev/null; then
        dir_size=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}')
        CACHE_SIZE=$((CACHE_SIZE + dir_size))
    fi
done
if [ "$CACHE_SIZE" -gt 0 ] 2>/dev/null; then
    CACHE_SIZE_HUMAN=$(numfmt --to=iec "$CACHE_SIZE" 2>/dev/null || echo "${CACHE_SIZE}B")
else
    CACHE_SIZE_HUMAN="0"
fi

###############################################################################
# 6. Browser Preferences & Settings
###############################################################################
echo "[6/6] Collecting browser preferences..."

SYNC_ENABLED="unknown"
DEFAULT_SEARCH="unknown"
HOMEPAGE="unknown"
SAFE_BROWSING="unknown"
DO_NOT_TRACK="unknown"
PROFILE_NAME="unknown"

if [ -n "$PROFILE_DIR" ] && [ -f "$PROFILE_DIR/Preferences" ]; then
    PREFS_FILE="$PROFILE_DIR/Preferences"

    # Default search engine
    DEFAULT_SEARCH=$(grep -oP '"short_name"\s*:\s*"[^"]*"' "$PREFS_FILE" 2>/dev/null | head -1 | sed 's/"short_name"\s*:\s*"//;s/"$//' || echo "unknown")
    [ -z "$DEFAULT_SEARCH" ] && DEFAULT_SEARCH="unknown"

    # Homepage
    HOMEPAGE=$(grep -oP '"homepage"\s*:\s*"[^"]*"' "$PREFS_FILE" 2>/dev/null | head -1 | sed 's/"homepage"\s*:\s*"//;s/"$//' || echo "unknown")
    [ -z "$HOMEPAGE" ] && HOMEPAGE="unknown"

    # Sync status
    if grep -q '"sync"' "$PREFS_FILE" 2>/dev/null; then
        SYNC_ENABLED=$(grep -oP '"has_setup_completed"\s*:\s*(true|false)' "$PREFS_FILE" 2>/dev/null | head -1 | grep -oP '(true|false)' || echo "unknown")
    fi

    # Safe browsing
    SAFE_BROWSING=$(grep -oP '"safebrowsing"\s*:\s*\{[^}]*"enabled"\s*:\s*(true|false)' "$PREFS_FILE" 2>/dev/null | grep -oP '(true|false)$' || echo "unknown")
    [ -z "$SAFE_BROWSING" ] && SAFE_BROWSING="unknown"

    # Do Not Track
    DO_NOT_TRACK=$(grep -oP '"enable_do_not_track"\s*:\s*(true|false)' "$PREFS_FILE" 2>/dev/null | grep -oP '(true|false)' || echo "unknown")
    [ -z "$DO_NOT_TRACK" ] && DO_NOT_TRACK="unknown"

    # Profile name
    PROFILE_NAME=$(grep -oP '"name"\s*:\s*"[^"]*"' "$PREFS_FILE" 2>/dev/null | head -1 | sed 's/"name"\s*:\s*"//;s/"$//' || echo "unknown")
    [ -z "$PROFILE_NAME" ] && PROFILE_NAME="unknown"

    echo "  Search: $DEFAULT_SEARCH, Sync: $SYNC_ENABLED"
else
    log_err "Preferences file not found"
    echo "  Preferences not found"
fi

# Profile disk usage total
PROFILE_TOTAL_SIZE="0"
if [ -n "$PROFILE_DIR" ] && [ -d "$PROFILE_DIR" ]; then
    PROFILE_TOTAL_SIZE=$(du -sh "$PROFILE_DIR" 2>/dev/null | awk '{print $1}')
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
  "audit_module": "browser_data",
  "version": "$VERSION",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(json_escape "$HOSTNAME_VAL")",
  "collection_method": "Bash audit script via Crostini",
  "stage": "2 of 4",
  "browser_profile": {
    "browser": "$(json_escape "$BROWSER_NAME")",
    "profile_directory": "$(json_escape "$PROFILE_DIR")",
    "profile_name": "$(json_escape "$PROFILE_NAME")",
    "profile_total_size": "$(json_escape "$PROFILE_TOTAL_SIZE")",
    "sqlite3_available": $SQLITE3_AVAILABLE
  },
  "bookmarks": {
    "count": $BOOKMARKS_COUNT,
    "entries": $BOOKMARKS_JSON
  },
  "history": {
    "total_entries": $HISTORY_TOTAL,
    "date_range": "$(json_escape "$HISTORY_DATE_RANGE")",
    "top_sites": $HISTORY_TOP_SITES_JSON
  },
  "saved_passwords": {
    "note": "Metadata only — no plaintext passwords extracted",
    "credential_count": $PASSWORDS_COUNT,
    "domains_with_saved_passwords": $PASSWORDS_DOMAINS_JSON
  },
  "autofill": {
    "total_entries": $AUTOFILL_COUNT,
    "saved_addresses": $AUTOFILL_ADDRESSES,
    "saved_credit_cards": $AUTOFILL_CREDIT_CARDS
  },
  "cookies": {
    "total_cookies": $COOKIES_COUNT,
    "unique_domains": $COOKIES_DOMAINS_COUNT
  },
  "storage": {
    "local_storage": "$(json_escape "$LOCAL_STORAGE_SIZE")",
    "session_storage": "$(json_escape "$SESSION_STORAGE_SIZE")",
    "indexeddb": "$(json_escape "$INDEXEDDB_SIZE")",
    "cache": "$(json_escape "$CACHE_SIZE_HUMAN")"
  },
  "preferences": {
    "default_search_engine": "$(json_escape "$DEFAULT_SEARCH")",
    "homepage": "$(json_escape "$HOMEPAGE")",
    "sync_enabled": "$(json_escape "$SYNC_ENABLED")",
    "safe_browsing": "$(json_escape "$SAFE_BROWSING")",
    "do_not_track": "$(json_escape "$DO_NOT_TRACK")"
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
  YeahSo Network — Scout Satellite Browser Data Audit Report
  Stage 2 of 4: Browser Data
═══════════════════════════════════════════════════════════════════════════════

  Generated : $TIMESTAMP
  Hostname  : $HOSTNAME_VAL
  Module    : browser_data v$VERSION

───────────────────────────────────────────────────────────────────────────────
  1. Browser Profile
───────────────────────────────────────────────────────────────────────────────
  Browser       : $BROWSER_NAME
  Profile Dir   : $PROFILE_DIR
  Profile Name  : $PROFILE_NAME
  Total Size    : $PROFILE_TOTAL_SIZE
  sqlite3       : $SQLITE3_AVAILABLE

───────────────────────────────────────────────────────────────────────────────
  2. Bookmarks
───────────────────────────────────────────────────────────────────────────────
  Count         : $BOOKMARKS_COUNT

───────────────────────────────────────────────────────────────────────────────
  3. Browsing History
───────────────────────────────────────────────────────────────────────────────
  Total Entries : $HISTORY_TOTAL
  Date Range    : $HISTORY_DATE_RANGE

───────────────────────────────────────────────────────────────────────────────
  4. Saved Passwords (metadata only)
───────────────────────────────────────────────────────────────────────────────
  Credential Count     : $PASSWORDS_COUNT
  Domains with logins  : $(echo "$PASSWORDS_DOMAINS_JSON" | grep -o '"' | wc -l | awk '{print int($1/2)}')

───────────────────────────────────────────────────────────────────────────────
  5. Autofill
───────────────────────────────────────────────────────────────────────────────
  Total Entries    : $AUTOFILL_COUNT
  Saved Addresses  : $AUTOFILL_ADDRESSES
  Saved Cards      : $AUTOFILL_CREDIT_CARDS

───────────────────────────────────────────────────────────────────────────────
  6. Cookies & Storage
───────────────────────────────────────────────────────────────────────────────
  Cookies          : $COOKIES_COUNT across $COOKIES_DOMAINS_COUNT domains
  Local Storage    : $LOCAL_STORAGE_SIZE
  Session Storage  : $SESSION_STORAGE_SIZE
  IndexedDB        : $INDEXEDDB_SIZE
  Cache            : $CACHE_SIZE_HUMAN

───────────────────────────────────────────────────────────────────────────────
  7. Preferences
───────────────────────────────────────────────────────────────────────────────
  Search Engine  : $DEFAULT_SEARCH
  Homepage       : $HOMEPAGE
  Sync Enabled   : $SYNC_ENABLED
  Safe Browsing  : $SAFE_BROWSING
  Do Not Track   : $DO_NOT_TRACK

───────────────────────────────────────────────────────────────────────────────
  8. Errors
───────────────────────────────────────────────────────────────────────────────
$(cat "$ERR_LOG" 2>/dev/null || echo "  No errors logged.")

═══════════════════════════════════════════════════════════════════════════════
  End of Stage 2 Report — Transfer via Lifeboat USB to Mothership
═══════════════════════════════════════════════════════════════════════════════
ENDTXT

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Audit Complete — Stage 2 of 4"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Output files:"
echo "    JSON manifest  : $JSON_OUT"
echo "    SHA256 sum     : $SHA_OUT"
echo "    Readable report: $TXT_OUT"
echo "    Error log      : $ERR_LOG"
echo ""
echo "  Next: Run satellite_export.sh to repackage for Lifeboat USB"
echo "═══════════════════════════════════════════════════════════════"
