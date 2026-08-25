#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
built_app="$project_dir/build/FloatKit.app"
installed_app="/Applications/FloatKit.app"
legacy_app="/Applications/WindowTools.app"
launch=1

if [ "${1:-}" = "--no-launch" ]; then
	launch=0
elif [ "$#" -ne 0 ]; then
	echo "usage: $0 [--no-launch]" >&2
	exit 2
fi

stop_app() {
	app_name=$1
	/usr/bin/pkill -x "$app_name" 2>/dev/null || true
}

trash_legacy_app() {
	[ -d "$legacy_app" ] || return 0

	trash_dir="$HOME/.Trash"
	destination="$trash_dir/WindowTools.app"
	/bin/mkdir -p "$trash_dir"
	if [ -e "$destination" ]; then
		destination="$trash_dir/WindowTools-$(date +%Y%m%d-%H%M%S).app"
	fi

	/bin/mv "$legacy_app" "$destination"
	echo "Moved legacy WindowTools to $destination"
}

"$project_dir/build-app.sh"

stop_app FloatKit
stop_app WindowTools
trash_legacy_app

/usr/bin/ditto "$built_app" "$installed_app"
echo "Installed $installed_app"

if [ "$launch" -eq 1 ]; then
	/usr/bin/open "$installed_app"
fi
