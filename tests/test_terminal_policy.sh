#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

"${CXX:-c++}" -std=c++20 -Wall -Wextra -Wpedantic -Werror \
  "$root/tests/test_terminal_policy.cpp" -o "$test_dir/check"

# Keep the real management command and addon policy in the same isolated environment.
run() {
  env -u XDG_STATE_HOME HOME="$test_dir/home" XDG_RUNTIME_DIR="$test_dir" "$@"
}

for terminal in Alacritty kitty foot ghostty org.wezfurlong.wezterm \
  gnome-terminal org.kde.konsole konsole xterm; do
  run "$test_dir/check" "$terminal" blocked
done
run "$test_dir/check" firefox enabled
run "$test_dir/check" '' enabled

for state in unset empty custom; do
  state_env=(-u XDG_STATE_HOME)
  case "$state" in
    empty) state_env=(XDG_STATE_HOME=) ;;
    custom) state_env=("XDG_STATE_HOME=$test_dir/custom-state") ;;
  esac
  run env "${state_env[@]}" bash "$root/scripts/manage.sh" toggle-terminals
  run env "${state_env[@]}" "$test_dir/check" konsole enabled
  run env "${state_env[@]}" "$test_dir/check" kitty enabled
  run env "${state_env[@]}" bash "$root/scripts/manage.sh" toggle-terminals
  run env "${state_env[@]}" "$test_dir/check" konsole blocked
done
printf 'terminal policy checks passed\n'
