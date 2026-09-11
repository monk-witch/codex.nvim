#!/usr/bin/env bash

set -euo pipefail

version="$(sed -nE 's/^  current = "([0-9]+\.[0-9]+\.[0-9]+)",$/\1/p' lua/codex/version.lua)"

if [[ -z "$version" ]]; then
  echo "Could not read a semantic version from lua/codex/version.lua" >&2
  exit 1
fi

if ! grep -Fq "**$version " README.md; then
  echo "README.md status does not name $version" >&2
  exit 1
fi

if ! grep -Fq "version = \"v$version\"" README.md; then
  echo "README.md install examples do not pin v$version" >&2
  exit 1
fi

if ! grep -Fq "## [$version]" CHANGELOG.md; then
  echo "CHANGELOG.md has no section for $version" >&2
  exit 1
fi

if ! grep -Fq "local plugin_version = version.current" lua/codex/init.lua; then
  echo "lua/codex/init.lua does not use the central version module" >&2
  exit 1
fi

echo "Release metadata is consistent for $version"
