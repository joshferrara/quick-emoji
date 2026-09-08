#!/usr/bin/env bash
set -euo pipefail

action=${1:-}

state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/quick-emoji
cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/quick-emoji
share_dir=${XDG_DATA_HOME:-$HOME/.local/share}/quick-emoji
fcitx_share=${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5
fcitx_lib=$HOME/.local/lib/fcitx5
fcitx_config=${XDG_CONFIG_HOME:-$HOME/.config}/fcitx5/conf/classicui.conf
theme_dir=$fcitx_share/themes/quick-emoji
addon_config=$fcitx_share/addon/quickemoji.conf
addon_library=$fcitx_lib/quickemoji.so
cleanup_service=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/quick-emoji-cleanup.service
cleanup_path=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/quick-emoji-cleanup.path
fcitx_dropin_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omarchy-fcitx5.service.d
fcitx_dropin=$fcitx_dropin_dir/quick-emoji.conf

lock_path=${XDG_RUNTIME_DIR:-/tmp}/quick-emoji-${UID}.lock
exec 9>"$lock_path"
flock 9

notify_error() {
  local message=$1
  command -v notify-send >/dev/null 2>&1 &&
    notify-send --urgency=critical "Quick Emoji couldn't start" "$message" || true
  printf 'quick-emoji: %s\n' "$message" >&2
}

qt_to_rgba() {
  local value=${1:-}
  value=${value#\#}
  case ${#value} in
    8) printf '#%s%s' "${value:2:6}" "${value:0:2}" ;;
    6) printf '#%sff' "$value" ;;
    *) printf '#000000ff' ;;
  esac
}

qt_to_rgb() {
  local value
  value=$(qt_to_rgba "${1:-}")
  printf '%s' "${value:0:7}"
}

qt_alpha() {
  local value=${1:-}
  value=${value#\#}
  if [[ ${#value} == 8 ]]; then
    awk -v hex="${value:0:2}" 'BEGIN {
      digits="0123456789abcdef"; hex=tolower(hex)
      hi=index(digits,substr(hex,1,1))-1; lo=index(digits,substr(hex,2,1))-1
      printf "%.3f", (hi*16+lo)/255
    }'
  else
    printf '1'
  fi
}

reload_theme() {
  # Classic UI caches SVG theme assets for the lifetime of the process.
  # fcitx5-remote -r reloads configuration but leaves those images cached, so
  # restart Omarchy's supervised service to make color and geometry changes
  # visible. Fall back to the remote reload on systems without that unit.
  if systemctl --user cat omarchy-fcitx5.service >/dev/null 2>&1; then
    systemctl --user restart omarchy-fcitx5.service
  elif command -v fcitx5-remote >/dev/null 2>&1; then
    fcitx5-remote -r >/dev/null 2>&1 || true
  fi
}

stop_fcitx() {
  if systemctl --user cat omarchy-fcitx5.service >/dev/null 2>&1; then
    systemctl --user stop omarchy-fcitx5.service
  fi
}

start_fcitx() {
  if systemctl --user cat omarchy-fcitx5.service >/dev/null 2>&1; then
    systemctl --user start omarchy-fcitx5.service
  else
    command -v fcitx5-remote >/dev/null 2>&1 && fcitx5-remote -r >/dev/null 2>&1 || true
  fi
}

verify_fcitx_addon() {
  systemctl --user cat omarchy-fcitx5.service >/dev/null 2>&1 || return 0

  local main_pid
  for _ in {1..20}; do
    main_pid=$(systemctl --user show omarchy-fcitx5.service \
      --property=MainPID --value 2>/dev/null || true)
    if [[ $main_pid =~ ^[1-9][0-9]*$ ]] &&
      grep -Fq '/quickemoji.so' "/proc/$main_pid/maps" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done

  notify_error 'Fcitx5 started, but did not load the Quick Emoji addon. Check: journalctl --user -u omarchy-fcitx5.service -n 100'
  return 1
}

write_theme() {
  local background=${1:-#1a1b26}
  local foreground=${2:-#c0caf5}
  local border=${3:-#414868}
  local selected_background=${4:-#292e42}
  local selected_text=${5:-#7aa2f7}
  local font_family=${6:-sans-serif}
  local corner_radius=${7:-0}
  local border_color=${8:-$border}
  local border_width=${9:-1}
  local font_size=${10:-12}
  local background_rgba foreground_rgba border_rgba selected_rgba selected_text_rgba
  local background_rgb border_rgb selected_rgb background_alpha border_alpha selected_alpha
  local border_inset panel_size highlight_radius

  [[ $corner_radius =~ ^[0-9]+([.][0-9]+)?$ ]] || corner_radius=0
  [[ $border_width =~ ^[0-9]+([.][0-9]+)?$ ]] || border_width=1
  [[ $font_size =~ ^[0-9]+([.][0-9]+)?$ ]] || font_size=12
  border=$border_color
  border_inset=$(awk -v width="$border_width" 'BEGIN { printf "%.3f", width / 2 }')
  panel_size=$(awk -v width="$border_width" 'BEGIN { printf "%.3f", 48 - width }')
  highlight_radius=$(awk -v n="$corner_radius" 'BEGIN { if (n > 4) n -= 4; printf "%.3f", n }')

  background_rgba=$(qt_to_rgba "$background")
  foreground_rgba=$(qt_to_rgba "$foreground")
  border_rgba=$(qt_to_rgba "$border")
  selected_rgba=$(qt_to_rgba "$selected_background")
  selected_text_rgba=$(qt_to_rgba "$selected_text")
  background_rgb=$(qt_to_rgb "$background")
  border_rgb=$(qt_to_rgb "$border")
  selected_rgb=$(qt_to_rgb "$selected_background")
  background_alpha=$(qt_alpha "$background")
  border_alpha=$(qt_alpha "$border")
  selected_alpha=$(qt_alpha "$selected_background")

  mkdir -p "$theme_dir" "$(dirname "$fcitx_config")"

  sed \
    -e "s|@BACKGROUND@|$background_rgb|g" \
    -e "s|@BACKGROUND_ALPHA@|$background_alpha|g" \
    -e "s|@BORDER@|$border_rgb|g" \
    -e "s|@BORDER_ALPHA@|$border_alpha|g" \
    -e "s|@BORDER_WIDTH@|$border_width|g" \
    -e "s|@BORDER_INSET@|$border_inset|g" \
    -e "s|@PANEL_SIZE@|$panel_size|g" \
    -e "s|@CORNER_RADIUS@|$corner_radius|g" \
    "$share_dir/panel.svg.in" >"$theme_dir/panel.svg"

  sed \
    -e "s|@SELECTED@|$selected_rgb|g" \
    -e "s|@SELECTED_ALPHA@|$selected_alpha|g" \
    -e "s|@CORNER_RADIUS@|$highlight_radius|g" \
    "$share_dir/highlight.svg.in" >"$theme_dir/highlight.svg"

  sed \
    -e "s|@BACKGROUND@|$background_rgba|g" \
    -e "s|@FOREGROUND@|$foreground_rgba|g" \
    -e "s|@BORDER@|$border_rgba|g" \
    -e "s|@SELECTED@|$selected_rgba|g" \
    -e "s|@SELECTED_TEXT@|$selected_text_rgba|g" \
    "$share_dir/theme.conf.in" >"$theme_dir/theme.conf"

  printf '%s\n' \
    'Vertical Candidate List=True' \
    'WheelForPaging=True' \
    "Font=$font_family $font_size" \
    "MenuFont=$font_family $font_size" \
    'Theme=quick-emoji' \
    'DarkTheme=quick-emoji' \
    >"$fcitx_config"
}

install_cleanup_watch() {
  mkdir -p "$(dirname "$cleanup_service")"
  cp "$0" "$share_dir/manage.sh"
  chmod +x "$share_dir/manage.sh"

  printf '%s\n' \
    '[Unit]' \
    'Description=Clean Quick Emoji files after its Omarchy plugin is removed' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=$share_dir/manage.sh cleanup" \
    >"$cleanup_service"

  printf '%s\n' \
    '[Unit]' \
    'Description=Watch for Quick Emoji plugin removal' \
    '' \
    '[Path]' \
    "PathChanged=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins" \
    'Unit=quick-emoji-cleanup.service' \
    '' \
    '[Install]' \
    'WantedBy=default.target' \
    >"$cleanup_path"

  systemctl --user daemon-reload
  systemctl --user enable --now quick-emoji-cleanup.path >/dev/null 2>&1
}

write_fcitx_dropin() {
  local system_addon_dir
  system_addon_dir=$(pkg-config --variable=libdir Fcitx5Core)/fcitx5
  mkdir -p "$fcitx_dropin_dir"
  printf '%s\n' \
    '[Service]' \
    "Environment=\"FCITX_ADDON_DIRS=$fcitx_lib:$system_addon_dir\"" \
    >"$fcitx_dropin"
}

deactivate() {
  # Fcitx writes its in-memory configuration when it exits. Stop it before
  # restoring the user's file so that stale values cannot overwrite it.
  stop_fcitx
  systemctl --user disable --now quick-emoji-cleanup.path >/dev/null 2>&1 || true
  rm -f "$addon_config" "$addon_library" "$cleanup_service" "$cleanup_path" "$fcitx_dropin"
  rmdir "$fcitx_dropin_dir" 2>/dev/null || true
  rm -rf "$theme_dir"

  if [[ -f $state_dir/classicui.conf.before ]]; then
    mkdir -p "$(dirname "$fcitx_config")"
    cp "$state_dir/classicui.conf.before" "$fcitx_config"
  elif [[ -f $state_dir/classicui.conf.absent ]]; then
    rm -f "$fcitx_config"
  fi

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  start_fcitx
  rm -rf "$cache_dir" "$share_dir" "$state_dir"
}

case "$action" in
  install)
    source_dir=${2:?missing plugin source directory}
    shift 2

    [[ $(uname -s) == Linux ]] || {
      notify_error 'This plugin requires Omarchy Linux.'
      exit 1
    }
    compiler=${CXX:-c++}
    missing_packages=()
    command -v pkg-config >/dev/null 2>&1 || missing_packages+=(pkgconf)
    if ! command -v fcitx5 >/dev/null 2>&1 ||
      ! command -v pkg-config >/dev/null 2>&1 ||
      ! pkg-config --exists Fcitx5Core; then
      missing_packages+=(fcitx5)
    fi
    command -v "$compiler" >/dev/null 2>&1 || missing_packages+=(base-devel)
    if (( ${#missing_packages[@]} > 0 )); then
      notify_error "Missing standard Omarchy packages: ${missing_packages[*]}. Run: omarchy pkg add ${missing_packages[*]}"
      exit 1
    fi

    mkdir -p "$state_dir" "$cache_dir" "$share_dir" "$fcitx_lib" "$(dirname "$addon_config")"
    printf '%s\n' "$source_dir" >"$state_dir/source-dir"

    if [[ ! -f $state_dir/classicui.conf.before && ! -f $state_dir/classicui.conf.absent ]]; then
      if [[ -f $fcitx_config ]]; then
        cp "$fcitx_config" "$state_dir/classicui.conf.before"
      else
        : >"$state_dir/classicui.conf.absent"
      fi
    fi

    cp "$source_dir/data/emojis.tsv" "$share_dir/emojis.tsv"
    cp "$source_dir/fcitx/theme.conf.in" "$share_dir/theme.conf.in"
    cp "$source_dir/fcitx/panel.svg.in" "$share_dir/panel.svg.in"
    cp "$source_dir/fcitx/highlight.svg.in" "$share_dir/highlight.svg.in"
    cp "$source_dir/fcitx/quickemoji.conf" "$addon_config"

    build_key=$(cat "$source_dir/src/quickemoji.cpp" "$source_dir/src/terminalpolicy.h" | sha256sum | cut -d' ' -f1)-$(pkg-config --modversion Fcitx5Core)
    old_build_key=$(cat "$cache_dir/build-key" 2>/dev/null || true)
    if [[ $build_key != "$old_build_key" || ! -f $cache_dir/quickemoji.so ]]; then
      read -r -a compile_flags <<<"$(pkg-config --cflags Fcitx5Core)"
      read -r -a link_flags <<<"$(pkg-config --libs Fcitx5Core)"
      if ! "$compiler" -std=c++20 -O2 -fPIC -shared \
        "${compile_flags[@]}" "$source_dir/src/quickemoji.cpp" \
        -o "$cache_dir/quickemoji.so.new" "${link_flags[@]}"; then
        notify_error 'The Fcitx5 integration failed to compile. See the Omarchy shell log for details.'
        exit 1
      fi
      mv "$cache_dir/quickemoji.so.new" "$cache_dir/quickemoji.so"
      printf '%s\n' "$build_key" >"$cache_dir/build-key"
    fi
    # Replace the library atomically. Overwriting a shared object in place can
    # corrupt the pages mapped by the running Fcitx process and crash it while
    # the service is stopping.
    install -m 755 "$cache_dir/quickemoji.so" "$addon_library.new"
    mv -f "$addon_library.new" "$addon_library"

    # Stop before changing classicui.conf; Fcitx persists its old in-memory
    # values on exit and would otherwise overwrite the generated config.
    stop_fcitx
    write_fcitx_dropin
    write_theme "$@"
    install_cleanup_watch
    start_fcitx
    verify_fcitx_addon
    ;;

  theme)
    source_dir=${2:?missing plugin source directory}
    shift 2
    [[ -f $addon_library ]] || exit 0
    write_theme "$@"
    reload_theme
    ;;

  deactivate)
    deactivate
    ;;

  deactivate-if-disabled)
    # A service object is also destroyed during shell restarts and hot reloads.
    # Give the registry time to settle, then remove the addon only when Quattro
    # explicitly reports this plugin as disabled (or no longer installed).
    sleep 1
    plugin_list=$(omarchy plugin list --json 2>/dev/null) || exit 0
    if ! jq -e '
      any(.[]; .id == "io.github.joshferrara.quick-emoji" and .enabled == true)
    ' <<<"$plugin_list" >/dev/null; then
      deactivate
    fi
    ;;

  toggle-terminals)
    flag="$state_dir/terminals-enabled"
    if [[ -f "$flag" ]]; then
      rm -f "$flag"
      printf 'Emoji picker disabled in terminals\n'
    else
      mkdir -p "$state_dir"
      touch "$flag"
      printf 'Emoji picker enabled in terminals\n'
    fi
    ;;

  cleanup)
    source_dir=$(cat "$state_dir/source-dir" 2>/dev/null || true)
    if [[ -z $source_dir || ! -f $source_dir/manifest.json ]]; then
      deactivate
    fi
    ;;

  *)
    printf 'Usage: %s {install|theme|deactivate|deactivate-if-disabled|toggle-terminals|cleanup}\n' "$0" >&2
    exit 2
    ;;
esac
