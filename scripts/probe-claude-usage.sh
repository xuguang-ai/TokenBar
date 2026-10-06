#!/usr/bin/env bash
# TokenBar probe for spec §13 V1/V3: read Claude Code's login token the same way Claude Code
# does (/usr/bin/security), call the official usage endpoint, and print ONLY usage numbers.
#
# The token is never printed and never appears in argv or the environment. It stays in a
# shell variable and reaches curl through a pipe (curl -H @-).
#
#   bash scripts/probe-claude-usage.sh                                    # default login (~/.claude)
#   CLAUDE_CONFIG_DIR=/Users/you/.tokenbar/claude/work bash scripts/probe-claude-usage.sh
#   bash scripts/probe-claude-usage.sh --parse-only saved-response.json   # offline: format a saved body
set -uo pipefail

# Formats a usage response body read from stdin. It prints field names and numbers only.
PY_REPORT=$(cat <<'PY'
import json, sys, datetime as dt
body = sys.stdin.read()
try:
    d = json.loads(body)
except Exception:
    print("  (response is not JSON)"); sys.exit(0)
now = dt.datetime.now(dt.timezone.utc)

def parse_ts(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return dt.datetime.fromtimestamp(v, dt.timezone.utc)
    s = str(v).replace("Z", "+00:00")
    if "." in s:  # normalise 1-9 fractional digits to 6 for fromisoformat
        head, rest = s.split(".", 1)
        i = 0
        while i < len(rest) and rest[i].isdigit():
            i += 1
        s = head + "." + rest[:i][:6].ljust(6, "0") + rest[i:]
    try:
        return dt.datetime.fromisoformat(s)
    except Exception:
        return None

def countdown(t):
    if t is None:
        return "-"
    secs = int((t - now).total_seconds())
    if secs <= 0:
        return "already reset"
    days, r = divmod(secs, 86400); h, r = divmod(r, 3600); m = r // 60
    return f"{days}d {h}h" if days else (f"{h}h {m}m" if h else f"{m}m")

if not isinstance(d, dict):
    print("  (unexpected JSON type)"); sys.exit(0)
print("  top-level keys :", ", ".join(sorted(d.keys())))
if d.get("type") == "error":
    e = d.get("error") or {}
    print(f"  API error      : {e.get('type')}: {str(e.get('message'))[:160]}"); sys.exit(0)
labels = {"five_hour": "5h (current session)", "seven_day": "weekly (all models)",
          "seven_day_sonnet": "weekly (Sonnet)", "seven_day_opus": "weekly (Opus)",
          "seven_day_oauth_apps": "weekly (OAuth apps)"}
for key, label in labels.items():
    w = d.get(key)
    if not isinstance(w, dict) or w.get("utilization") is None:
        continue
    u = float(w["utilization"]); t = parse_ts(w.get("resets_at"))
    when = t.astimezone().strftime("%a %H:%M") if t else "-"
    print(f"  {label:<22} used {u:5.1f}%  left {max(0.0, 100 - u):5.1f}%  resets {when} (in {countdown(t)})")
for row in d.get("limits") or []:
    if not isinstance(row, dict):
        continue
    scope = row.get("scope") if isinstance(row.get("scope"), dict) else {}
    model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
    if model.get("display_name"):
        print(f"  model limit    : {model['display_name']}: used {row.get('percent')}%, resets in {countdown(parse_ts(row.get('resets_at')))}")
x = d.get("extra_usage")
if isinstance(x, dict):
    print(f"  extra usage    : enabled={x.get('is_enabled')}")
PY
)

if [[ "${1:-}" == "--parse-only" ]]; then
  python3 -c "$PY_REPORT" < "${2:?usage: --parse-only <file>}"
  exit 0
fi

# Keychain service name, derived the way Claude Code derives it (spec §2.1).
ACCOUNT="${USER:-$(id -un)}"
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  SUFFIX="$(printf '%s' "$CLAUDE_CONFIG_DIR" | python3 -c 'import sys,unicodedata,hashlib; print(hashlib.sha256(unicodedata.normalize("NFC", sys.stdin.read()).encode()).hexdigest()[:8])')"
  SERVICE="Claude Code-credentials-$SUFFIX"
else
  SERVICE="Claude Code-credentials"
fi
echo "== TokenBar probe: Claude usage =="
echo "config dir       : ${CLAUDE_CONFIG_DIR:-(default, ~/.claude)}"
echo "keychain service : $SERVICE"
echo "keychain account : $ACCOUNT"

ERRF="$(mktemp -t tokenbar-probe)"
BLOB=""
trap 'rm -f "$ERRF"; BLOB=""' EXIT

# 1) Read the credential. A slow read (several seconds) means macOS showed an access dialog.
T0="$(python3 -c 'import time; print(time.time())')"
BLOB="$(/usr/bin/security find-generic-password -a "$ACCOUNT" -w -s "$SERVICE" 2>"$ERRF")"
CODE=$?
T1="$(python3 -c 'import time; print(time.time())')"
echo "keychain read    : exit $CODE after $(python3 -c "print(f'{$T1 - $T0:.2f}')")s"
if [[ $CODE -ne 0 ]]; then
  echo "security stderr  : $(head -c 300 "$ERRF" | tr '\n' ' ')"
  case $CODE in
    44) echo "=> No credential under this service: this config dir is not logged in, or the path string differs." ;;
    36) echo "=> The keychain is locked." ;;
    *)  echo "=> Read failed. If you clicked Deny/Cancel in a dialog, this exit code is exactly what TokenBar needs to know." ;;
  esac
  exit 1
fi

# 2) Describe the credential: key names, scopes and expiry only, never values.
printf '%s' "$BLOB" | python3 -c '
import sys, json, time, binascii
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    try:
        d = json.loads(binascii.unhexlify(raw).decode())
    except Exception:
        print("credential       : not JSON (unexpected format)"); sys.exit(3)
o = d.get("claudeAiOauth") or {}
exp = o.get("expiresAt")
left = exp / 1000 - time.time() if isinstance(exp, (int, float)) else None
def fmt(s):
    s = int(abs(s)); h, r = divmod(s, 3600); return f"{h}h {r // 60}m"
print("credential keys  :", ", ".join(sorted(d.keys())), "(values hidden)")
print("subscription     :", o.get("subscriptionType"))
print("scopes           :", " ".join(o.get("scopes") or []))
print("tokens present   : access =", bool(o.get("accessToken")), "| refresh =", bool(o.get("refreshToken")))
if left is None:
    print("token expiry     : unknown")
elif left > 300:
    print("token expiry     : valid for another", fmt(left))
else:
    print("token expiry     : EXPIRED (or within 5 min):", fmt(left), "ago" if left < 0 else "left")
sys.exit(0 if (o.get("accessToken") and left is not None and left > 300) else 2)
'
META=$?
if [[ $META -eq 2 ]]; then
  echo "=> The token is expired. Use Claude Code once (any message) so it refreshes the token, then run this probe again."
  exit 2
elif [[ $META -ne 0 ]]; then
  exit 3
fi

# 3) Call the usage endpoint. The Authorization header reaches curl on stdin (-H @-).
RESP="$(printf '%s' "$BLOB" | python3 -c '
import sys, json, binascii
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    d = json.loads(binascii.unhexlify(raw).decode())
sys.stdout.write("Authorization: Bearer " + d["claudeAiOauth"]["accessToken"] + "\n")
' | curl -sS --max-time 15 -H @- \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "Content-Type: application/json" \
      -H "User-Agent: TokenBar-probe/0.1" \
      -w $'\n%{http_code}' \
      https://api.anthropic.com/api/oauth/usage)"
CURL_EXIT=$?
BLOB=""
STATUS="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"
echo "usage API        : HTTP $STATUS (curl exit $CURL_EXIT)"
printf '%s' "$BODY" | python3 -c "$PY_REPORT"
echo
echo "Paste everything above back to Claude. It contains no token and no email."
