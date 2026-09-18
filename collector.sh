#!/usr/bin/bash
# OpenCode usage collector: emits one compact JSON doc to stdout.
#
# Supply-chain hardening (marketplace review):
# - Absolute tool paths only; nothing is resolved through PATH, so a
#   shadowed binary cannot intercept the collector. Service.qml additionally
#   launches this script with a pinned minimal PATH and --noprofile --norc.
# - Closed environment: only HOME (+TZ for sqlite localtime) and the
#   documented OPENCODE_* test overrides are honored; anything else is
#   ignored. Override paths must be absolute without parent traversal.
# - Bounded output: SQL row caps plus a final stdout byte ceiling, so a
#   huge database cannot blow up the QML-side buffer.
# - Whole-tree teardown: when started via setsid (Service.qml) with
#   COLLECTOR_PG_LEADER=1, TERM/INT/HUP stops the entire process group, so
#   curl/sqlite3 grandchildren cannot outlive the widget watchdog.
set -uo pipefail

readonly JQ=/usr/bin/jq
readonly SQLITE3=/usr/bin/sqlite3
readonly CURL=/usr/bin/curl
readonly DATE=/usr/bin/date
readonly MKTEMP=/usr/bin/mktemp
readonly HEAD=/usr/bin/head
readonly WC=/usr/bin/wc
readonly CHMOD=/usr/bin/chmod
readonly RM=/usr/bin/rm
readonly KILL=/usr/bin/kill

if [[ ! -x $JQ ]]; then echo "collector.sh: jq not found" >&2; exit 1; fi
if [[ ! -x $SQLITE3 ]]; then echo "collector.sh: sqlite3 not found" >&2; exit 1; fi

# Belt and braces for direct runs; the real boundary is Service.qml's
# cleared environment (BASH_ENV is read at startup, so unset only protects
# children we spawn from here on).
export PATH="/usr/bin:/bin"
unset BASH_ENV ENV

: "${HOME:?collector.sh: HOME is not set}"
readonly DATA_ROOT="$HOME/.local/share/opencode"
readonly GO_URL=https://opencode.ai/zen/go/v1/usage
AUTH_JSON="${OPENCODE_AUTH_JSON:-$DATA_ROOT/auth.json}"
DB="${OPENCODE_DB:-$DATA_ROOT/opencode.db}"

# Overrides (used by tests) must be absolute paths without parent traversal;
# /dev/null is allowed so tests can simulate "no auth file".
valid_override_path() {
  local p=$1
  [[ -n $p ]] || return 1
  [[ $p == /dev/null ]] && return 0
  [[ $p == /* ]] || return 1
  [[ $p != *".."* ]] || return 1
  return 0
}
if [[ -n "${OPENCODE_AUTH_JSON:-}" ]]; then
  valid_override_path "$AUTH_JSON" || { echo "collector.sh: refused auth path" >&2; exit 1; }
fi
if [[ -n "${OPENCODE_DB:-}" ]]; then
  valid_override_path "$DB" || { echo "collector.sh: refused db path" >&2; exit 1; }
fi

# Whole-tree teardown. Only armed when our launcher confirms we lead our own
# process group (setsid + COLLECTOR_PG_LEADER=1); otherwise killing group $$
# could hit an unrelated foreground group, so direct test runs skip this.
# The handler removes temp files first, then SIGKILLs the group: KILL cannot
# be trapped or pended, so unlike a self-directed TERM this cannot re-trigger
# its own handler and loop — leader and curl/sqlite3 grandchildren all die.
if [[ "${COLLECTOR_PG_LEADER:-}" == "1" ]]; then
  trap 'rm -f "${tmpf:-}" "${hdrf:-}" 2>/dev/null; "$KILL" -KILL -- -$$ 2>/dev/null' TERM INT HUP
fi

CUTOFF=$(( $("$DATE" +%s)*1000-604800000 ))
MONTH_CUTOFF=$(( $("$DATE" +%s)*1000-30*86400000 ))

GO_MAX_BYTES=262144
# Producer-side bounds: top-N SQL caps keep output representative for heavy
# users; the final byte ceiling below fails closed as a backstop.
PROVIDER_ROW_LIMIT=128
MODEL_ROW_LIMIT=1000
COLLECTOR_MAX_BYTES=262144

collect_go() {
  local k out code size
  k=$("$JQ" -r '.["opencode-go"].key // empty' "$AUTH_JSON" 2>/dev/null) || true
  [[ -n $k ]] || { echo '{"status":"No API key"}'; return; }
  [[ -x $CURL ]] || { echo '{"status":"curl missing"}'; return; }
  tmpf=$("$MKTEMP") || { echo '{"status":"network error"}'; return; }
  hdrf=$("$MKTEMP") || { "$RM" -f "$tmpf"; echo '{"status":"network error"}'; return; }
  "$CHMOD" 600 "$tmpf" "$hdrf" 2>/dev/null
  trap '"$RM" -f "$tmpf" "$hdrf"' EXIT
  printf 'Authorization: Bearer %s\n' "$k" >"$hdrf"
  set +o pipefail
  "$CURL" -sS -m 10 -w $'\n%{http_code}' --header @"$hdrf" "$GO_URL" 2>/dev/null \
    | "$HEAD" -c $((GO_MAX_BYTES+1)) >"$tmpf"
  curl_stat=${PIPESTATUS[0]}
  set -o pipefail
  "$RM" -f "$hdrf" # bearer token no longer needed; trap remains as backstop
  size=$("$WC" -c <"$tmpf")
  if (( size > GO_MAX_BYTES )); then
    echo '{"status":"response too large"}'
    return
  fi
  if [[ $curl_stat != 0 ]]; then
    echo '{"status":"network error"}'
    return
  fi
  out=$(<"$tmpf")
  "$RM" -f "$tmpf"
  code=${out##*$'\n'}; out=${out%$'\n'*}
  [[ $code == 200 ]] || { "$JQ" -cn --arg s "HTTP $code" '{status:$s}'; return; }
  "$JQ" -e '.usage.rolling and .usage.weekly and .usage.monthly' >/dev/null 2>&1 <<<"$out" || { echo '{"status":"bad response"}'; return; }
  "$JQ" -c '{status:"ok",rolling:.usage.rolling,weekly:.usage.weekly,monthly:.usage.monthly}' <<<"$out"
}

provider_rows() {
  [[ -r $DB ]] || return
  "$SQLITE3" -readonly "file:$DB?mode=ro" \
    "SELECT json_extract(data,'\$.providerID'),
            ROUND(SUM(CASE WHEN time_created > $MONTH_CUTOFF THEN COALESCE(json_extract(data,'\$.tokens.total'),0) ELSE 0 END)),
            ROUND(SUM(CASE WHEN time_created > $CUTOFF THEN COALESCE(json_extract(data,'\$.tokens.total'),0) ELSE 0 END)),
            ROUND(SUM(CASE WHEN time_created > $MONTH_CUTOFF THEN COALESCE(json_extract(data,'\$.cost'),0) ELSE 0 END),4),
            ROUND(SUM(CASE WHEN time_created > $CUTOFF THEN COALESCE(json_extract(data,'\$.cost'),0) ELSE 0 END),4)
     FROM message
     WHERE json_extract(data,'\$.providerID') IS NOT NULL
       AND json_extract(data,'\$.providerID') != ''
     GROUP BY 1 ORDER BY 5 DESC LIMIT $PROVIDER_ROW_LIMIT;" 2>/dev/null || true
}

model_rows() {
  [[ -r $DB ]] || return
  "$SQLITE3" -readonly "file:$DB?mode=ro" \
    "SELECT json_extract(data,'\$.providerID'),
            COALESCE(json_extract(data,'\$.modelID'),'?'),
            date(time_created/1000,'unixepoch','localtime'),
            ROUND(SUM(COALESCE(json_extract(data,'\$.tokens.total'),0))),
            ROUND(SUM(COALESCE(json_extract(data,'\$.cost'),0)),4)
     FROM message
     WHERE time_created > $CUTOFF
       AND json_extract(data,'\$.providerID') IS NOT NULL
       AND json_extract(data,'\$.providerID') != ''
     GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT $MODEL_ROW_LIMIT;" 2>/dev/null || true
}

providers='[]'
while IFS='|' read -r pid mo wk mc wc; do
  [[ -n $pid ]] || continue
  providers=$("$JQ" -c --arg id "$pid" --argjson mo "${mo:-0}" --argjson wk "${wk:-0}" \
    --argjson mc "${mc:-0}" --argjson wc "${wc:-0}" \
    '. + [{pid:$id,tokensWeek:$wk,tokensMonth:$mo,costWeek:$wc,costMonth:$mc,hasKey:false}]' <<<"$providers")
done < <(provider_rows)

keys_json='[]'
while IFS= read -r k; do
  [[ -n $k ]] || continue
  keys_json=$("$JQ" -c --arg k "$k" '. + [$k]' <<<"$keys_json")
done < <("$JQ" -r 'to_entries[] | select(.value.key) | .key' "$AUTH_JSON" 2>/dev/null)

rows='[]'
while IFS='|' read -r pid mid d t c; do
  [[ -n $pid ]] || continue
  rows=$("$JQ" -c --arg p "$pid" --arg m "$mid" --arg d "$d" \
    --argjson t "${t:-0}" --argjson c "${c:-0}" \
    '. + [{provider:$p,model:$m,date:$d,tokens:$t,cost:$c}]' <<<"$rows")
done < <(model_rows)

models_map=$("$JQ" -c '
  group_by(.provider) | map(
    { key: .[0].provider
    , value: { modelList: (
        group_by(.model) | map(
          { modelName: .[0].model
          , tokensWeek: (map(.tokens) | add // 0)
          , costWeek: (map(.cost) | add // 0)
          , daily: (map({date: .date, tokens: .tokens, cost: .cost}) | sort_by(.date))
          }
        )
      )
    }
    }
  ) | from_entries
' <<<"$rows")

providers=$("$JQ" -c --argjson keys "$keys_json" 'map(.hasKey = (.pid as $id | any($keys[]; . == $id)))' <<<"$providers")
providers=$("$JQ" -c --argjson models "$models_map" \
  'map(.modelList = ($models[.pid].modelList // []))' <<<"$providers")

gojson=$(collect_go)

recent='[]'
if [[ -r $DB ]]; then
  while IFS='|' read -r d t c; do
    [[ -n $d ]] || continue
    recent=$("$JQ" -c --arg d "$d" --argjson t "${t:-0}" --argjson c "${c:-0}" \
      '. + [{date:$d,tokens:$t,cost:$c}]' <<<"$recent")
  done < <("$SQLITE3" -readonly "file:$DB?mode=ro" \
    "WITH RECURSIVE days(d) AS (
       SELECT date('now','localtime','-6 days')
       UNION ALL
       SELECT date(d,'+1 day') FROM days WHERE d < date('now','localtime')
     )
     SELECT days.d,
       ROUND(COALESCE(SUM(COALESCE(json_extract(message.data,'\$.tokens.total'),0)),0)),
       ROUND(COALESCE(SUM(COALESCE(json_extract(message.data,'\$.cost'),0)),0),4)
     FROM days LEFT JOIN message
       ON date(message.time_created/1000,'unixepoch','localtime') = days.d
     GROUP BY days.d ORDER BY 1;" 2>/dev/null || true)
else
  # No database yet (fresh install): same 7-day shape, all zeros.
  for i in 6 5 4 3 2 1 0; do
    d=$("$DATE" -d "-$i days" +%F)
    recent=$("$JQ" -c --arg d "$d" '. + [{date:$d,tokens:0,cost:0}]' <<<"$recent")
  done
fi

final=$("$JQ" -cn --argjson providers "$providers" --argjson go "$gojson" \
  --argjson recentDays "$recent" \
  '{status:"ok",providers:$providers,go:$go,recentDays:$recentDays,updatedAt:(now|todateiso8601)}')
size=$(printf '%s' "$final" | "$WC" -c)
if (( size > COLLECTOR_MAX_BYTES )); then
  echo "collector.sh: output exceeds $COLLECTOR_MAX_BYTES bytes" >&2
  exit 1
fi
printf '%s\n' "$final"
