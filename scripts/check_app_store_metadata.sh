#!/bin/sh
set -eu

# Checks the App Store texts in spec/release/app-store/<locale>/ against App Store Connect's
# limits, so they paste in as they are: name and subtitle 30 characters, promotional text 170,
# description 4,000, keywords 100 bytes with no space after a comma, and https URLs.
#
# Usage: sh scripts/check_app_store_metadata.sh
cd "$(dirname "$0")/.."
status=0
fail() { printf 'check_app_store_metadata: %s\n' "$*" >&2; status=1; }
chars() { python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n")))' < "$1"; }
bytes() { printf '%s' "$(cat "$1")" | wc -c | tr -d ' '; }
for dir in spec/release/app-store/*/; do
    [ -f "$dir/name.txt" ] || continue
    for limit in name:30 subtitle:30 promotional-text:170 description:4000; do
        file="$dir/${limit%%:*}.txt"
        [ -s "$file" ] || { fail "$file is missing or empty"; continue; }
        [ "$(chars "$file")" -le "${limit#*:}" ] || fail "$file is over ${limit#*:} characters ($(chars "$file"))"
    done
    keywords="$dir/keywords.txt"
    [ "$(bytes "$keywords")" -le 100 ] || fail "$keywords is over 100 bytes ($(bytes "$keywords"))"
    ! grep -q ', ' "$keywords" || fail "$keywords has a space after a comma, which wastes a byte"
    for url in support-url privacy-url marketing-url; do
        grep -Eqx 'https://[^ ]+' "$dir/$url.txt" || fail "$dir/$url.txt isn't one https URL"
    done
done
exit "$status"
