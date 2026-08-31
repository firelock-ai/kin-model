#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Firelock, LLC

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="${root}/scripts/check-actions-cache-policy.sh"
fixtures="$(mktemp -d)"
trap 'rm -rf "${fixtures}"' EXIT

make_case() {
  local name="$1"
  local case_root="${fixtures}/${name}"
  local workflow_root="${case_root}/.github/workflows"
  local action_root="${case_root}/.github/actions"
  mkdir -p "${workflow_root}" "${action_root}"
  cp "${root}"/.github/workflows/*.yml "${workflow_root}/"
  cp -R "${root}/.github/actions/." "${action_root}/"
  printf '%s\n' "${workflow_root}"
}

expect_rejection() {
  local name="$1"
  local workflow_root="$2"
  local expected="$3"
  local output
  if output="$("${check}" "${workflow_root}" 2>&1)"; then
    echo "FAIL: ${name} falsifier was accepted" >&2
    exit 1
  fi
  if ! grep -Fq "${expected}" <<<"${output}"; then
    echo "FAIL: ${name} failed for the wrong reason" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  echo "OK: ${name} rejected"
}

"${check}" "${root}/.github/workflows"

case_root="$(make_case target-output)"
perl -0pi -e 's#(~/.cargo/git\n)#$1            target\n#' "${case_root}/ci.yml"
expect_rejection target-output "${case_root}" "target output is forbidden"

case_root="$(make_case dynamic-key)"
perl -0pi -e 's/cargo-sources-v1/cargo-sources-\$\{\{ github.sha \}\}/' "${case_root}/ci.yml"
expect_rejection dynamic-key "${case_root}" "cache keys must not expand"

case_root="$(make_case hash-key)"
perl -0pi -e 's/cargo-sources-v1/cargo-sources-\$\{\{ hashFiles("Cargo.lock") \}\}/' "${case_root}/ci.yml"
expect_rejection hash-key "${case_root}" "cache keys must not expand"

case_root="$(make_case non-main-save)"
perl -0pi -e "s/        if: github.ref == .*steps.fetch-dependencies.outcome == 'success'/        if: always()/" "${case_root}/cache-seed.yml"
expect_rejection non-main-save "${case_root}" "cache save must require main, a cache miss, and a successful fetch"

case_root="$(make_case failed-fetch-save)"
perl -0pi -e "s/ && steps.fetch-dependencies.outcome == 'success'//" "${case_root}/cache-seed.yml"
expect_rejection failed-fetch-save "${case_root}" "cache save must require main, a cache miss, and a successful fetch"

case_root="$(make_case unbound-fetch-step)"
perl -0pi -e 's/id: fetch-dependencies/id: unbound-fetch/' "${case_root}/cache-seed.yml"
expect_rejection unbound-fetch-step "${case_root}" "cache save must follow the non-gating fetch-dependencies cargo fetch step"

case_root="$(make_case pr-save)"
perl -0pi -e 's#actions/cache/restore\@v4#actions/cache/save\@v4#' "${case_root}/kin-db-compat.yml"
expect_rejection pr-save "${case_root}" "cache save must require main, a cache miss, and a successful fetch"

case_root="$(make_case monolithic-action)"
perl -0pi -e 's#actions/cache/restore\@v4#actions/cache\@v4#' "${case_root}/ci.yml"
expect_rejection monolithic-action "${case_root}" "use actions/cache/restore@v4 or actions/cache/save@v4"

case_root="$(make_case uppercase-monolithic-action)"
perl -0pi -e 's#actions/cache/restore\@v4#Actions/cache\@v4#' "${case_root}/ci.yml"
expect_rejection uppercase-monolithic-action "${case_root}" "use actions/cache/restore@v4 or actions/cache/save@v4"

case_root="$(make_case escaped-monolithic-action)"
perl -0pi -e 's#uses: actions/cache/restore\@v4#uses: "actions/\\u0063ache\@v4"#' "${case_root}/ci.yml"
expect_rejection escaped-monolithic-action "${case_root}" "use actions/cache/restore@v4 or actions/cache/save@v4"

case_root="$(make_case conditional-restore)"
perl -0pi -e "s/(      - name: Restore cargo sources\n)/\$1        if: github.event_name == 'pull_request'\n/" "${case_root}/ci.yml"
expect_rejection conditional-restore "${case_root}" "cache restore must run on every workflow ref"

case_root="$(make_case lookup-only-restore)"
perl -0pi -e 's/(          key: \$\{\{ runner\.os \}\}-cargo-sources-v1\n)/$1          lookup-only: true\n/' "${case_root}/ci.yml"
expect_rejection lookup-only-restore "${case_root}" "restore inputs must be exactly"

case_root="$(make_case fail-on-cache-miss)"
perl -0pi -e 's/(          key: \$\{\{ runner\.os \}\}-cargo-sources-v1\n)/$1          fail-on-cache-miss: true\n/' "${case_root}/ci.yml"
expect_rejection fail-on-cache-miss "${case_root}" "restore inputs must be exactly"

case_root="$(make_case setup-action-cache)"
perl -0pi -e 's!(      - name: Check Actions cache policy)!      - name: Hidden setup cache\n        uses: actions/setup-node\@v4\n        with:\n          cache: npm\n\n$1!' "${case_root}/ci.yml"
expect_rejection setup-action-cache "${case_root}" "unaudited cache input(s)"

case_root="$(make_case setup-node-default-cache)"
perl -0pi -e 's!(      - name: Check Actions cache policy)!      - name: Hidden default package manager cache\n        uses: actions/setup-node\@v6\n\n$1!' "${case_root}/ci.yml"
expect_rejection setup-node-default-cache "${case_root}" "actions/setup-node must explicitly set package-manager-cache: false"

case_root="$(make_case setup-node-cache-disabled)"
perl -0pi -e 's!(      - name: Check Actions cache policy)!      - name: Node without Actions cache\n        uses: actions/setup-node\@v6\n        with:\n          package-manager-cache: false\n\n$1!' "${case_root}/ci.yml"
"${check}" "${case_root}" >/dev/null
echo "OK: setup-node explicit cache opt-out accepted"

case_root="$(make_case setup-go-default-cache)"
perl -0pi -e 's!(      - name: Check Actions cache policy)!      - name: Hidden default Go cache\n        uses: actions/setup-go\@v6\n\n$1!' "${case_root}/ci.yml"
expect_rejection setup-go-default-cache "${case_root}" "actions/setup-go must explicitly set cache: false"

case_root="$(make_case setup-go-cache-disabled)"
perl -0pi -e 's!(      - name: Check Actions cache policy)!      - name: Go without Actions cache\n        uses: actions/setup-go\@v6\n        with:\n          cache: false\n\n$1!' "${case_root}/ci.yml"
"${check}" "${case_root}" >/dev/null
echo "OK: setup-go explicit cache opt-out accepted"

while IFS='|' read -r fixture action; do
  case_root="$(make_case "unapproved-${fixture}")"
  UNAPPROVED_ACTION="${action}" perl -0pi -e '
    s!(      - name: Check Actions cache policy)!      - name: Hidden default cache action\n        uses: $ENV{UNAPPROVED_ACTION}\n\n$1!
  ' "${case_root}/ci.yml"
  expect_rejection "unapproved-${fixture}" "${case_root}" "unapproved action identity ${action}"
done <<'CASES'
setup-gradle|gradle/actions/setup-gradle@v4
setup-uv|astral-sh/setup-uv@v6
setup-buildx|docker/setup-buildx-action@v3
setup-qemu|docker/setup-qemu-action@v3
setup-rust-toolchain|actions-rust-lang/setup-rust-toolchain@v1
mise-action|jdx/mise-action@v3
setup-bun|oven-sh/setup-bun@v2
setup-zig|mlugg/setup-zig@v2
ccache-action|hendrikmuhs/ccache-action@v1
CASES

case_root="$(make_case buildx-gha-cache)"
perl -0pi -e 's!(      - name: Check Actions cache policy)!      - name: Hidden build cache\n        run: docker buildx build --cache-to type=gha .\n\n$1!' "${case_root}/ci.yml"
expect_rejection buildx-gha-cache "${case_root}" "unaudited GitHub Actions cache backend in run step"

case_root="$(make_case late-restore)"
perl -0pi -e 's#(      - name: Restore cargo sources\n)#      - name: Cargo work before restore\n        run: cargo fetch\n\n$1#' "${case_root}/ci.yml"
expect_rejection late-restore "${case_root}" "cache restore must precede every run step"

case_root="$(make_case early-save)"
perl -0pi -e '
  if (s#\n(      - name: Save cargo sources on main\n.*?          key: \$\{\{ steps\.cargo-sources\.outputs\.cache-primary-key \}\}\n)#$save = $1; "\n"#se) {
    s#(      - name: Fetch dependencies\n.*?        run: cargo fetch\n)#$save\n$1#s;
  }
' "${case_root}/cache-seed.yml"
expect_rejection early-save "${case_root}" "cache save must be the last declared job step"

case_root="$(make_case duplicate-condition-key)"
perl -0pi -e "s/(      - name: Restore cargo sources\n)/\$1        if: true\n        if: false\n/" "${case_root}/ci.yml"
expect_rejection duplicate-condition-key "${case_root}" "duplicate YAML mapping key"

case_root="$(make_case missing-policy-enforcement)"
perl -0pi -e 's!\n      - name: Check Actions cache policy\n        run: \|\n          \./scripts/check-actions-cache-policy\.sh\n          \./scripts/test-actions-cache-policy\.sh\n!!' "${case_root}/ci.yml"
expect_rejection missing-policy-enforcement "${case_root}" "expected exactly one unconditional fail-closed Actions cache policy invocation; found 0"

case_root="$(make_case soft-policy-enforcement)"
perl -0pi -e 's/(      - name: Check Actions cache policy\n)/$1        continue-on-error: true\n/' "${case_root}/ci.yml"
expect_rejection soft-policy-enforcement "${case_root}" "Actions cache policy enforcement must be unconditional and fail closed"

case_root="$(make_case trailing-soft-policy-enforcement)"
perl -0pi -e 's!(          \./scripts/test-actions-cache-policy\.sh\n)!$1        continue-on-error: true\n!' "${case_root}/ci.yml"
expect_rejection trailing-soft-policy-enforcement "${case_root}" "Actions cache policy enforcement must be unconditional and fail closed"

case_root="$(make_case conditional-policy-enforcement)"
perl -0pi -e "s/(      - name: Check Actions cache policy\n)/\$1        if: runner.os == 'Linux'\n/" "${case_root}/ci.yml"
expect_rejection conditional-policy-enforcement "${case_root}" "Actions cache policy enforcement must be unconditional and fail closed"

case_root="$(make_case unexpected-workflow-cache)"
cat >"${case_root}/rogue.yml" <<'YAML'
name: Rogue
on: workflow_dispatch
jobs:
  rogue:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@v4
        id: cargo-sources
        with:
          path: |
            ~/.cargo/registry
            ~/.cargo/git
          key: ${{ runner.os }}-cargo-sources-v1
          restore-keys: ${{ runner.os }}-cargo-sources-
YAML
expect_rejection unexpected-workflow-cache "${case_root}" "rogue.yml: unexpected cache action"

case_root="$(make_case unapproved-reusable-workflow)"
perl -0pi -e 's/cargo-dependency-wave\.yml\@v0\.1\.32/cargo-dependency-wave.yml\@v9/' "${case_root}/kin-dependency-wave.yml"
expect_rejection unapproved-reusable-workflow "${case_root}" "unapproved reusable workflow identity"

case_root="$(make_case third-party-rust-cache)"
perl -0pi -e 's#uses: actions/cache/restore\@v4#uses: Swatinem/rust-cache\@v2#' "${case_root}/ci.yml"
expect_rejection third-party-rust-cache "${case_root}" "unaudited cache-capable action"

case_root="$(make_case composite-cache-action)"
perl -0pi -e 's!\z!\n    - name: Hidden target cache\n      uses: Actions/cache\@v4\n      with:\n        path: target\n        key: hidden-target\n!' "${case_root}/../actions/rust-toolchain/action.yml"
expect_rejection composite-cache-action "${case_root}" "repo-local composite actions must not invoke or configure cache-capable action"

case_root="$(make_case composite-third-party-cache)"
perl -0pi -e 's!\z!\n    - name: Hidden rust cache\n      uses: Swatinem/rust-cache\@v2\n!' "${case_root}/../actions/rust-toolchain/action.yml"
expect_rejection composite-third-party-cache "${case_root}" "repo-local composite actions must not invoke or configure cache-capable action"

echo "OK: all Actions cache policy falsifiers were rejected."
