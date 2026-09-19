#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s /path/to/Operator.app\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
APP_PATH=$1
APP_BINARY="$APP_PATH/Operator"
FRAMEWORKS_PATH="$APP_PATH/Frameworks"
OTOOL=${OTOOL:-/usr/bin/otool}
FILE=${FILE:-/usr/bin/file}

[ -d "$APP_PATH" ] || {
    printf 'ERROR: app bundle is missing: %s\n' "$APP_PATH" >&2
    exit 2
}
[ -f "$APP_BINARY" ] || {
    printf 'ERROR: app executable is missing: %s\n' "$APP_BINARY" >&2
    exit 2
}

check_binary() {
    binary=$1
    if dependencies=$("$OTOOL" -L "$binary" 2>&1); then
        :
    else
        status=$?
        printf 'ERROR: otool failed for %s (exit %s): %s\n' "$binary" "$status" "$dependencies" >&2
        exit 1
    fi

    printf '%s\n' "$dependencies" | awk 'NR > 1 { print $1 }' | while IFS= read -r dependency; do
        case "$dependency" in
            @rpath/*.framework/*)
                relative_path=${dependency#@rpath/}
                expected_path="$FRAMEWORKS_PATH/$relative_path"
                [ -e "$expected_path" ] || {
                    printf 'ERROR: missing embedded framework: %s required by %s (expected %s)\n' \
                        "$dependency" "$binary" "$expected_path" >&2
                    exit 1
                }
                ;;
        esac
    done
}

check_binary "$APP_BINARY"

# UTM loads the guest's emulator by name, so it may not appear in otool output.
# Earlier build stages may not have embedded the guest yet.
if [ -e "$APP_PATH/Operator.utm" ]; then
    guest_config="$APP_PATH/Operator.utm/config.plist"
    if guest_architecture=$(/usr/bin/plutil -extract System.Architecture raw -expect string -o - "$guest_config" 2>/dev/null); then
        :
    else
        printf 'ERROR: cannot read guest architecture: %s\n' "$guest_config" >&2
        exit 1
    fi
    case "$guest_architecture" in
        ''|*[!A-Za-z0-9_-]*)
            printf 'ERROR: invalid guest architecture in %s\n' "$guest_config" >&2
            exit 1
            ;;
    esac
    guest_engine="qemu-$guest_architecture-softmmu"
    guest_binary="$FRAMEWORKS_PATH/$guest_engine.framework/$guest_engine"
    [ -f "$guest_binary" ] || {
        printf 'ERROR: missing guest emulator: %s (expected %s)\n' "$guest_engine" "$guest_binary" >&2
        exit 1
    }
    printf 'PASS: guest emulator: %s\n' "$guest_engine"
fi

if [ -d "$FRAMEWORKS_PATH" ]; then
    framework_files=$(mktemp "${TMPDIR:-/tmp}/operator-framework-files.XXXXXX")
    trap 'rm -f "$framework_files"' EXIT HUP INT TERM
    find "$FRAMEWORKS_PATH" -type f -path '*.framework/*' -print >"$framework_files"
    while IFS= read -r framework_file; do
        [ -n "$framework_file" ] || continue
        if file_description=$("$FILE" -b "$framework_file" 2>&1); then
            :
        else
            status=$?
            printf 'ERROR: file inspection failed for %s (exit %s): %s\n' "$framework_file" "$status" "$file_description" >&2
            exit 1
        fi
        case "$file_description" in
            *Mach-O*) check_binary "$framework_file" ;;
        esac
    done <"$framework_files"
fi

printf 'PASS: embedded @rpath framework dependencies: %s\n' "$APP_PATH"
