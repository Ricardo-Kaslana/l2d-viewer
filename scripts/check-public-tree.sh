#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0
report() {
  echo "public-tree check failed: $*" >&2
  fail=1
}

forbidden_paths="$(
  git ls-files |
    grep -Ei '(\.moc3$|\.motion3\.json$|\.model3\.json$|\.so$|\.dll$|\.jks$|\.keystore$|(^|/)key\.properties$|(^|/)local\.properties$)' ||
    true
)"
if [ -n "$forbidden_paths" ]; then
  report "forbidden asset/build/secret paths"
  echo "$forbidden_paths" >&2
fi

private_refs="$(
  git grep -nI -E \
    'abeikelongbi|AzurLane|dev\.local|\.codegraph|\.superpowers|\.claude|C:\\Users|D:\\Development|/Users/|/home/' \
    -- ':!scripts/check-public-tree.sh' ':!third_party/mocari/**' ||
    true
)"
if [ -n "$private_refs" ]; then
  report "private/proprietary references"
  echo "$private_refs" >&2
fi

for internal_dir in docs/archive docs/superpowers; do
  if git ls-files "$internal_dir" | grep -q .; then
    report "internal directory is still tracked: $internal_dir"
  fi
done

for required in \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  third_party/mocari/LICENSE \
  third_party/mocari/UPSTREAM.md \
  .github/workflows/ci.yml \
  app/android/gradlew \
  app/android/gradlew.bat \
  app/android/gradle/wrapper/gradle-wrapper.jar; do
  if ! git ls-files --error-unmatch "$required" >/dev/null 2>&1; then
    report "required file is not tracked: $required"
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "public-tree check passed"
