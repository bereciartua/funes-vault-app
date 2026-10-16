#!/bin/sh
# Fails if app or package sources could log user content
# (spec/plans/project-setup.md#conventions):
#   - print, debugPrint, dump or NSLog anywhere in Apps/ or Packages/*/Sources;
#   - `privacy: .public` on a line without a `// log-safe: <reason>` comment.
# Tests are not checked.
set -eu
cd "$(dirname "$0")/.."

dirs=$(ls -d Apps Packages/*/Sources 2>/dev/null || true)
[ -n "$dirs" ] || { echo "check_log_privacy: nothing to check"; exit 0; }

status=0
if grep -rnE --include='*.swift' '(^|[^A-Za-z0-9_.])(print|debugPrint|dump|NSLog)\(' $dirs; then
    echo "error: use Logger instead of print/debugPrint/dump/NSLog (above)." >&2
    status=1
fi
if grep -rnE --include='*.swift' 'privacy:[[:space:]]*\.public' $dirs | grep -v '// log-safe:'; then
    echo "error: \`privacy: .public\` needs a \`// log-safe: <reason>\` comment on the same line (above)." >&2
    status=1
fi
[ "$status" -eq 0 ] && echo "check_log_privacy: ok"
exit "$status"
