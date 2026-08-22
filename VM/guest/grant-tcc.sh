#!/bin/bash

set -euo pipefail

bundle_id="${2:-io.github.theautoscaler.floatkit}"
app_path="${1:-/Applications/FloatKit.app}"
client_type="${3:-0}"
accessibility_only="${4:-0}"
user_tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
system_tcc_db="/Library/Application Support/com.apple.TCC/TCC.db"
requirement_file="$(mktemp /tmp/floatkit-csreq.XXXXXX)"
trap 'rm -f "$requirement_file"' EXIT

if [[ ! -f "$user_tcc_db" || ! -f "$system_tcc_db" ]]; then
    echo "A required TCC database does not exist." >&2
    exit 1
fi

designated_requirement="$(/usr/bin/codesign -dr - "$app_path" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
requirement_sql="NULL"
if [[ -n "$designated_requirement" ]]; then
    /usr/bin/csreq -r="$designated_requirement" -b "$requirement_file"
    requirement_hex="$(/usr/bin/xxd -p "$requirement_file" | /usr/bin/tr -d '\n')"
    requirement_sql="X'$requirement_hex'"
fi

grant_service() {
    local database="$1"
    local service="$2"
    local client="${3:-$bundle_id}"
    local client_type="${4:-0}"
    local client_requirement_sql="${5:-$requirement_sql}"
    local sqlite=(/usr/bin/sqlite3 "$database")
    if [[ "$database" == "$system_tcc_db" ]]; then
        sqlite=(sudo /usr/bin/sqlite3 "$database")
    fi

    "${sqlite[@]}" <<SQL
INSERT OR REPLACE INTO access
    (service, client, client_type, auth_value, auth_reason, auth_version,
     csreq, policy_id, indirect_object_identifier_type,
     indirect_object_identifier, indirect_object_code_identity, flags,
     last_modified)
VALUES
    ('$service', '$client', $client_type, 2, 4, 1,
     $client_requirement_sql, NULL, 0, 'UNUSED', NULL, 0,
     CAST(strftime('%s','now') AS INTEGER));
SQL
}

# The official Tahoe base has SIP disabled specifically for automated image
# preparation. These grants apply only inside the disposable VM.
services=(kTCCServiceAccessibility kTCCServiceScreenCapture)
if [[ "$accessibility_only" == 1 ]]; then services=(kTCCServiceAccessibility); fi
for service in "${services[@]}"; do
    grant_service "$user_tcc_db" "$service" "$bundle_id" "$client_type"
    grant_service "$system_tcc_db" "$service" "$bundle_id" "$client_type"
done

if [[ "$accessibility_only" == 1 ]]; then
    /usr/bin/killall tccd 2>/dev/null || true
    sudo /usr/bin/killall tccd 2>/dev/null || true
    exit 0
fi

# macOS 15+ stores consent for bypassing the system content-sharing picker
# separately from TCC. FloatKit deliberately selects a window through its own
# accessibility-based UI, so seed that approval in this disposable VM as well.
# Without it, replayd places a consent dialog over the framebuffer and a visual
# comparison can mistake the dialog for a FloatKit rendering regression.
approval_dir="$HOME/Library/Group Containers/group.com.apple.replayd"
approval_plist="$approval_dir/ScreenCaptureApprovals.plist"
approval_key="${bundle_id//./\\.}"
/bin/mkdir -p "$approval_dir"
if [[ ! -f "$approval_plist" ]]; then
    /usr/bin/plutil -create binary1 "$approval_plist"
fi
/usr/bin/plutil -remove "$approval_key" "$approval_plist" 2>/dev/null || true
/usr/bin/plutil -insert "$approval_key" -dictionary "$approval_plist"
/usr/bin/plutil -insert "$approval_key.kScreenCaptureAlertableUsageCount" -integer 1 "$approval_plist"
/usr/bin/plutil -insert "$approval_key.kScreenCaptureApprovalLastAlerted" -date "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$approval_plist"
/usr/bin/plutil -insert "$approval_key.kScreenCaptureApprovalLastUsed" -date "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$approval_plist"
/usr/bin/plutil -insert "$approval_key.kScreenCapturePrivacyHintDate" -date "$(/bin/date -u -v+30d '+%Y-%m-%dT%H:%M:%SZ')" "$approval_plist"
/usr/bin/plutil -insert "$approval_key.kScreenCapturePrivacyHintPolicy" -integer 2592000 "$approval_plist"

/usr/bin/killall tccd 2>/dev/null || true
sudo /usr/bin/killall tccd 2>/dev/null || true
/usr/bin/killall replayd 2>/dev/null || true
