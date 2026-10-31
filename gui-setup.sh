#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backend=$(cat "$script_dir/gui-backend" 2>/dev/null || printf 'qt')
action=${1:-install}

export KOCR_SOURCE_DIR=$script_dir
export KOCR_INSTALL_GUI=1
export KOCR_GUI_BACKEND=$backend
exec bash "$script_dir/script.sh" "$action"
