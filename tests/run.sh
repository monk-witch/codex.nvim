#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
socket_path="$tmp_dir/app-server.sock"
state_path="$tmp_dir/selection.json"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

chmod +x "$root_dir/tests/fake_codex" "$root_dir/tests/fake_app_server.py"
"$root_dir/tests/fake_app_server.py" "$socket_path" &
server_pid=$!

for _ in $(seq 1 100); do
  if test -S "$socket_path"; then
    break
  fi
  sleep 0.02
done

CODEX_NVIM_TEST_ROOT="$root_dir" \
CODEX_NVIM_TEST_SOCKET="$socket_path" \
CODEX_NVIM_TEST_CODEX="$root_dir/tests/fake_codex" \
CODEX_NVIM_TEST_STATE="$state_path" \
XDG_STATE_HOME="$tmp_dir/state" \
XDG_CACHE_HOME="$tmp_dir/cache" \
nvim --headless -u NONE -i NONE -l "$root_dir/tests/test.lua"

wait "$server_pid"
