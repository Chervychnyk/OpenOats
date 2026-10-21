#!/usr/bin/env bash
set -euo pipefail

# Remove the empty UserDefaults suites the test suite leaves in ~/Library/Preferences.
# Matches only com.openoats.test(s).<...>.<UUID>; the app's own com.openoats.app is never touched.

removed=0
shopt -s nullglob
for plist in "$HOME"/Library/Preferences/com.openoats.test.*.plist "$HOME"/Library/Preferences/com.openoats.tests.*.plist; do
  domain=$(basename "$plist" .plist)
  [[ $domain =~ \.[0-9A-F-]{36}$ ]] || continue
  defaults delete "$domain" 2>/dev/null || true
  rm -f "$plist"
  removed=$((removed + 1))
done
echo "Removed $removed test settings domains"
