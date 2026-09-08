#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

jq -e '
  .schemaVersion == 1 and
  .id == "io.github.joshferrara.quick-emoji" and
  (.kinds == ["service"]) and
  .entryPoints.service == "Service.qml"
' "$root/manifest.json" >/dev/null

[[ $(wc -l <"$root/data/emojis.tsv") -ge 1800 ]]
awk -F '\t' 'NF != 4 || $1 == "" || $2 == "" { exit 1 }' "$root/data/emojis.tsv"

lookup() {
  local alias=$1 expected=$2
  awk -F '\t' -v alias="$alias" -v expected="$expected" '
    BEGIN { found = 0 }
    {
      count = split($3, aliases, ",")
      for (i = 1; i <= count; i++) {
        if (aliases[i] == alias && $1 == expected) found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$root/data/emojis.tsv"
}

lookup wave 👋
lookup thumbsup 👍
lookup heart ❤️
lookup tada 🎉
lookup rocket 🚀

bash -n "$root/scripts/manage.sh"
shellcheck "$root/scripts/manage.sh" "$root/tests/test_repository.sh" "$root/tests/test_terminal_policy.sh"
grep -F 'FCITX_ADDON_DIRS=' "$root/scripts/manage.sh" >/dev/null
grep -F 'mv -f' "$root/scripts/manage.sh" | grep -F 'addon_library.new' >/dev/null
grep -F 'verify_fcitx_addon' "$root/scripts/manage.sh" >/dev/null
grep -F 'systemctl --user restart omarchy-fcitx5.service' "$root/scripts/manage.sh" >/dev/null
grep -F 'Missing standard Omarchy packages:' "$root/scripts/manage.sh" >/dev/null
grep -F 'Style.cornerRadius' "$root/Service.qml" >/dev/null
grep -F 'Style.font.body' "$root/Service.qml" >/dev/null
grep -F 'Border.surfaceSpec' "$root/Service.qml" >/dev/null
grep -F '@BORDER_WIDTH@' "$root/fcitx/panel.svg.in" >/dev/null
grep -F '@CORNER_RADIUS@' "$root/fcitx/panel.svg.in" >/dev/null

echo "repository checks passed"
