# AGENTS.md — opencode-tracker

Omarchy shell bar-widget plugin (Quickshell QML + bash). No build, test suite, or CI in repo; `qmllint` works for QML syntax.

Plugin ID is `io.github.thespd.opencode-tracker` — `manifest.json` `id`, `Panel.qml` `moduleName`, and `ipcTarget` must all stay identical.

## Layout

- `manifest.json` — plugin manifest (`schemaVersion: 1`, `kinds: ["bar-widget"]`, entry `Panel.qml`). Keep `allowMultiple: false`, `defaultSection: right`, `refreshIntervalSec` within 60–3600.
- `Panel.qml` — bar widget UI. Depends on `qs.Commons` / `qs.Ui` (`Panel`, `WidgetButton`, `KeyboardPanel`, …) provided by omarchy-shell at runtime — not in this repo, so `qmllint` only checks syntax, not those imports.
- `Service.qml` — runs `collector.sh` via `Process` on a timer (`triggeredOnStart: true`), parses stdout as one JSON doc via `Model.parseCollector`. A 30s watchdog `Timer` resets a hung collector — don't remove it.
- `Model.js` — formatting/normalization helpers shared by QML. First line must stay `.pragma library`.
- `collector.sh` — emits one compact JSON doc `{status, providers, go, recentDays, updatedAt}` to stdout. Deps: `sqlite3`, `jq`, `curl` (all standard on Omarchy).

## Verify (no test suite)

```bash
bash -n collector.sh
qmllint Panel.qml Service.qml
./collector.sh | jq .              # works with missing DB/auth; check .status/.go.status
# The install dir is a symlink to this repo, so edits go live on rescan (no copy step):
ls -la ~/.config/omarchy/plugins/ | grep opencode-tracker  # must show `-> /home/thespd/Work/opencode-tracker`
omarchy-shell shell rescanPlugins  # re-discovers plugins; if the open panel still shows old UI, `omarchy restart shell` (rescan doesn't always reload a running panel component)
```

`Model.js` cannot be `require()`d directly — `.pragma library` is a syntax error in Node. Test logic via:

```bash
mkdir -p /tmp/opencode && tail -n +2 Model.js > /tmp/opencode/Model.test.js
node -e "const M=require('/tmp/opencode/Model.test.js'); console.log(M.tokenCount(1500))"
```

## Collector rules

- OpenCode DB (`~/.local/share/opencode/opencode.db`) is read-only: always `sqlite3 -readonly "file:$DB?mode=ro"`. `time_created` is **milliseconds**; 7d / 30d cutoffs are computed in ms.
- Auth override for tests: `OPENCODE_AUTH_JSON=/dev/null ./collector.sh`. Missing `opencode-go` key → `{"status":"No API key"}`, not an error. DB override: `OPENCODE_DB=/tmp/test.db ./collector.sh`.
- `recentDays` always covers exactly the last 7 local calendar days (zero-filled via a `days` CTE + `LEFT JOIN`); day grouping uses sqlite `'localtime'` to match `Model.dayLabel`'s local `Date`. Panel must not hardcode a 7-day divisor — use `dayCount`.
- Never print, log, or pass the Go key via argv. Auth goes only to `https://opencode.ai/zen/go/v1/usage` via curl `--header @<600-perm file>`; keep the `GO_MAX_BYTES` (256 KiB) ceiling, `chmod 600` + `trap` cleanup, and `jq -e` shape check before trusting the response.
- Keep all `jq` output compact (`-c` / `-cn`): `Service.qml` parses stdout as a single JSON document.
- Dep failures (`jq`/`sqlite3` missing) exit 1 with stderr; `Service.qml` shows stderr truncated to 180 chars on nonzero exit — errors to stderr, data to stdout.
- `set -uo pipefail` is on; the `curl | head -c` section intentionally disables/re-enables `pipefail` and reads `PIPESTATUS[0]` — don't "simplify" it.

## Panel rules

- Providers render dynamically from `service.providers` (grouped by DB `providerID`) — no hardcoded list. Unknown IDs fall back to the raw string in `Model.label`; add pretty names to `PROVIDER_LABELS`.
- Each provider card shows only the top 3 models by weekly tokens (`topN`) with a "Show N more" expander (`showAllModels`) — never render the full list inline.
- The share bar keeps a 2.5% minimum fill for nonzero share so low-volume providers stay visible — don't "simplify" it to raw `share`.

## Model.js contract

- `normalizeWindow` expects API `percent` on a 0–100 scale (divides by 100); `percent()` takes the normalized 0–1 value — never feed raw API numbers to `percent()` (clamps to 100%).
- `parseCollector` requires top-level `status:"ok"` plus a `providers` array, else the widget shows "Could not parse OpenCode usage". Non-ok `go.status` values (`No API key`, `curl missing`, …) are display strings surfaced as `Go: <status>`, not failures.
