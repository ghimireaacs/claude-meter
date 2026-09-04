#!/usr/bin/env bash
# Install claude-meter: the CLI on PATH, the plugin as a Noctalia plugin source.
#
# Nothing is copied — the CLI is symlinked and the plugin source points at this
# checkout, so editing a file here is all it takes to change what runs.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="${HOME}/.local/bin"
source_name="claude-meter"
plugin_id="ghimireaacs/claude-meter"

mkdir -p "$bin_dir"
ln -sf "${repo}/bin/claude-meter" "${bin_dir}/claude-meter"
echo "linked ${bin_dir}/claude-meter"

case ":${PATH}:" in
  *":${bin_dir}:"*) ;;
  *) echo "warning: ${bin_dir} is not on PATH; add it before enabling the plugin" ;;
esac

if ! command -v noctalia >/dev/null 2>&1; then
  echo "noctalia not found — CLI installed, plugin skipped"
  exit 0
fi

# `source add` is rejected when the name is already registered, so a re-run
# replaces the entry rather than failing on it.
if noctalia msg plugins source list 2>/dev/null | grep -q "^${source_name} "; then
  noctalia msg plugins source remove "$source_name" >/dev/null
fi
noctalia msg plugins source add "$source_name" path "${repo}/plugins"
noctalia msg plugins enable "$plugin_id"

echo
echo "Installed. Add the widget in Settings > Bar > (section) > Claude Meter,"
echo "or run: noctalia msg settings-open-plugin ${plugin_id}"
