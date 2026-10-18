#!/bin/sh
set -eu

# Checks the version before a release. The Xcode project is the one source of it: the
# project-level MARKETING_VERSION is x.y.z and CURRENT_PROJECT_VERSION a whole number higher
# than in the newest earlier v* tag (both targets inherit them, so the app and funes-mcp always
# agree); a tag, if given, is v<x.y.z>; CHANGELOG.md has a "## [x.y.z]" section for the release
# notes; and server.json, the MCP Registry entry, has the same version.
#
# Usage: sh scripts/check_version.sh [TAG]
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_file=FunesVault.xcodeproj/project.pbxproj

fail() { printf 'check_version: %s\n' "$*" >&2; exit 1; }

# The single value of a build setting in a project file read from stdin; fails when the
# configurations disagree or a target overrides it.
setting() {
    values=$(sed -n "s/^[[:space:]]*$1 = \"\{0,1\}\([^\";]*\)\"\{0,1\};$/\1/p" | sort -u)
    [ -n "$values" ] || fail "$project_file has no $1"
    [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 1 ] \
        || fail "$project_file has more than one $1: $(printf '%s ' $values)"
    printf '%s\n' "$values"
}
version=$(setting MARKETING_VERSION < "$project_dir/$project_file")
build=$(setting CURRENT_PROJECT_VERSION < "$project_dir/$project_file")

printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' \
    || fail "MARKETING_VERSION \"$version\" isn't x.y.z"
case "$build" in
    ''|*[!0-9]*) fail "CURRENT_PROJECT_VERSION \"$build\" isn't a whole number" ;;
esac
if [ "$#" -gt 0 ] && [ "$1" != "v$version" ]; then
    fail "tag $1 doesn't match the project: expected v$version"
fi

previous=$(git -C "$project_dir" tag --list 'v*' --sort=-v:refname | grep -vx "v$version" | head -n 1 || true)
if [ -n "$previous" ]; then
    previous_build=$(git -C "$project_dir" show "$previous:$project_file" | setting CURRENT_PROJECT_VERSION)
    [ "$build" -gt "$previous_build" ] \
        || fail "CURRENT_PROJECT_VERSION $build isn't higher than $previous's $previous_build"
fi

grep -q "^## \[$version\]" "$project_dir/CHANGELOG.md" \
    || fail "CHANGELOG.md has no \"## [$version]\" section"
if [ -f "$project_dir/server.json" ]; then
    registry_version=$(plutil -extract version raw -o - "$project_dir/server.json" 2>/dev/null || true)
    [ "$registry_version" = "$version" ] \
        || fail "server.json has version \"$registry_version\", expected $version"
fi
printf 'check_version: %s (%s) passed%s\n' "$version" "$build" "${previous:+, after $previous}"
