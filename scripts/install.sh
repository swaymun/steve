#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$HOME/Applications/Steve.app"
signing_identity=-
bin_dir=
replace_running=false

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [options]

Options:
  --destination PATH       Install app bundle (default: ~/Applications/Steve.app)
  --signing-identity NAME  Sign with an explicitly selected existing identity
  --ad-hoc                 Use ad hoc signing (default)
  --bin-dir DIR            Install an optional `steve` command wrapper
  --replace-running        Stop a running Steve process before replacement
  -h, --help               Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination)
      [ "$#" -ge 2 ] || { echo "--destination requires a path" >&2; exit 2; }
      destination=$2
      shift 2
      ;;
    --signing-identity)
      [ "$#" -ge 2 ] || { echo "--signing-identity requires a name" >&2; exit 2; }
      signing_identity=$2
      shift 2
      ;;
    --ad-hoc)
      signing_identity=-
      shift
      ;;
    --bin-dir)
      [ "$#" -ge 2 ] || { echo "--bin-dir requires a path" >&2; exit 2; }
      bin_dir=$2
      shift 2
      ;;
    --replace-running)
      replace_running=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$destination" in
  /*.app) ;;
  *) echo "destination must be an absolute .app path" >&2; exit 2 ;;
esac

if [ -n "$bin_dir" ]; then
  case "$bin_dir" in
    /*) ;;
    *) echo "--bin-dir must be an absolute path" >&2; exit 2 ;;
  esac
fi

APPLE_SIGNING_IDENTITY="$signing_identity" "$repo_dir/scripts/build-native.sh"
source_app="$repo_dir/artifacts/native/Steve.app"
[ -d "$source_app" ] || { echo "build did not produce $source_app" >&2; exit 1; }

destination_parent=$(dirname "$destination")
destination_name=$(basename "$destination")
mkdir -p "$destination_parent"
stage="$destination_parent/.${destination_name}.installing.$$"
backup=
wrapper_stage=
wrapper_backup=

cleanup() {
  rm -rf "$stage"
  if [ -n "$wrapper_stage" ]; then rm -f "$wrapper_stage"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ditto "$source_app" "$stage"
codesign --verify --deep --strict "$stage"

if [ -e "$destination" ]; then
  installed_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$destination/Contents/Info.plist" 2>/dev/null || true)
  if [ "$installed_identifier" != com.swaymun.steve ]; then
    echo "refusing to replace a bundle that is not com.swaymun.steve: $destination" >&2
    exit 1
  fi
fi

if [ -n "$bin_dir" ]; then
  mkdir -p "$bin_dir"
  wrapper="$bin_dir/steve"
  wrapper_stage="$bin_dir/.steve.installing.$$"
  escaped_destination=$(printf '%s' "$destination" | sed "s/'/'\\\\''/g")
  printf "#!/bin/sh\nexec '%s/Contents/MacOS/Steve' \"\$@\"\n" "$escaped_destination" > "$wrapper_stage"
  chmod 755 "$wrapper_stage"
fi

destination_pids() {
  executable="$destination/Contents/MacOS/Steve"
  for pid in $(pgrep -x Steve 2>/dev/null || true); do
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    case "$command" in
      "$executable"|"$executable "*) printf '%s\n' "$pid" ;;
    esac
  done
}

running_pids=$(destination_pids)
if [ -n "$running_pids" ]; then
  if [ "$replace_running" != true ]; then
    echo "Steve is running from $destination; quit it or pass --replace-running" >&2
    exit 1
  fi

  osascript -e 'tell application id "com.swaymun.steve" to quit' >/dev/null 2>&1 || true
  attempts=0
  while [ -n "$(destination_pids)" ] && [ "$attempts" -lt 10 ]; do
    attempts=$((attempts + 1))
    sleep 1
  done

  running_pids=$(destination_pids)
  if [ -n "$running_pids" ]; then
    for pid in $running_pids; do kill "$pid"; done
    attempts=0
    while [ -n "$(destination_pids)" ] && [ "$attempts" -lt 10 ]; do
      attempts=$((attempts + 1))
      sleep 1
    done
  fi

  if [ -n "$(destination_pids)" ]; then
    echo "Steve did not quit; destination was not replaced" >&2
    exit 1
  fi
fi

if [ -e "$destination" ]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup="$destination_parent/${destination_name}.backup-$stamp-$$"
  mv "$destination" "$backup"
fi

if ! mv "$stage" "$destination"; then
  if [ -n "$backup" ] && [ ! -e "$destination" ]; then
    mv "$backup" "$destination"
  fi
  exit 1
fi

if ! codesign --verify --deep --strict "$destination" || ! "$destination/Contents/MacOS/Steve" --help >/dev/null 2>&1; then
  echo "installed app verification failed" >&2
  if [ -n "$backup" ]; then
    failed="$destination_parent/${destination_name}.failed-${stamp:-$(date -u +%Y%m%dT%H%M%SZ)}-$$"
    mv "$destination" "$failed"
    mv "$backup" "$destination"
    backup=
    echo "Restored previous app; failed bundle retained at: $failed" >&2
  fi
  exit 1
fi

if [ -n "$backup" ]; then
  rm -r -- "$backup"
  echo "Removed verified-install rollback: $backup"
  backup=
fi

if [ -n "$bin_dir" ]; then
  if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    stamp=${stamp:-$(date -u +%Y%m%dT%H%M%SZ)}
    wrapper_backup="$wrapper.backup-$stamp-$$"
    mv "$wrapper" "$wrapper_backup"
  fi
  mv "$wrapper_stage" "$wrapper"
  wrapper_stage=
  echo "Installed command wrapper: $wrapper"
  if [ -n "$wrapper_backup" ]; then
    echo "Previous command wrapper backup: $wrapper_backup"
  fi
fi

echo "Installed app: $destination"
printf "Launch Steve:\n  open '%s'\n" "$destination"
printf "Run setup:\n  '%s/Contents/MacOS/Steve' setup --json\n" "$destination"
echo "For unattended checks, add --non-interactive and handle needs_user_action results."
