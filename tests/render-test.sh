#!/usr/bin/env bash
# Renders the chart against the fixtures in tests/fixtures and checks the
# output and the render-time failures. Needs helm, yq (mikefarah v4) and jq.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIX="$ROOT/tests/fixtures"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

# A fresh copy of the chart, without tests/, with one fixture's manifests in m/.
chart() {
  local c="$WORK/chart-$RANDOM"
  mkdir -p "$c"
  (cd "$ROOT" && tar --exclude=./.git --exclude=./.superpowers --exclude=./tests -cf - .) | tar -xf - -C "$c"
  if [ -n "${1:-}" ]; then cp -R "$FIX/$1/manifests" "$c/m"; fi
  echo "$c"
}
ok() { echo "PASS $1"; pass=$((pass + 1)); }
ko() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
eq() { if [ "$2" == "$3" ]; then ok "$1"; else ko "$1" "got [$2], want [$3]"; fi; }
# The data value of key $3 in ConfigMap $2, exactly, from rendered output $1.
data() { printf '%s' "$1" | yq ea -N -o json "select(.kind == \"ConfigMap\" and .metadata.name == \"$2\")" | jq -j --arg k "$3" '.data[$k]'; }
expect_fail() { # name, expected message substring, helm template args...
  local name=$1 want=$2; shift 2
  local out
  if out=$(helm template t "$@" 2>&1); then ko "$name" "rendered, expected failure"; return; fi
  if printf '%s' "$out" | grep -qF -- "$want"; then ok "$name"; else ko "$name" "error lacks [$want]: $out"; fi
}

# basic: two control planes, templated values, skipped files
C=$(chart basic)
OUT=$(helm template t "$C" -n grp -f "$FIX/basic/values.yaml" --set manifestsDir=m 2>&1) || ko basic-render "$OUT"
eq basic-configmaps "$(printf '%s' "$OUT" | yq ea -N '[select(.kind == "ConfigMap")] | length')" 2
eq basic-rd-names "$(printf '%s' "$OUT" | yq ea -N 'select(.kind == "ResourceDistribution") | .metadata.name' | paste -sd, -)" "t-ctp-a,t-ctp-b"
eq basic-selector "$(printf '%s' "$OUT" | yq ea -N 'select(.kind == "ResourceDistribution" and .metadata.name == "t-ctp-b") | .spec.controlPlaneSelector.names[0]')" ctp-b
eq basic-manifestref "$(printf '%s' "$OUT" | yq ea -N 'select(.kind == "ResourceDistribution" and .metadata.name == "t-ctp-a") | .spec.manifestRefs[0].name')" t-ctp-a
eq basic-namespace "$(printf '%s' "$OUT" | yq ea -N '.metadata.namespace' | sort -u | paste -sd, -)" grp
eq basic-keys-skip-dotfile-subdir-md "$(printf '%s' "$OUT" | yq ea -N 'select(.kind == "ConfigMap" and .metadata.name == "t-ctp-a") | .data | keys | join(",")')" "10-cm.yaml,20-sa.yaml"
eq basic-per-cp-value "$(data "$OUT" t-ctp-b 20-sa.yaml | yq '.metadata.annotations["example.com/role-arn"]')" "arn:aws:iam::111111111111:role/ctp-b"
eq basic-controlplane-var "$(data "$OUT" t-ctp-a 10-cm.yaml | yq '.data.controlPlane')" ctp-a
eq basic-special-chars "$(data "$OUT" t-ctp-a 10-cm.yaml | yq '.data.note')" "a: b # not a comment"
eq basic-strategy-default-absent "$(printf '%s' "$OUT" | yq ea -N 'select(.kind == "ResourceDistribution") | .spec.manifestRefs[0].strategy' | sort -u)" null
eq basic-deletion-default "$(printf '%s' "$OUT" | yq ea -N 'select(.kind == "ResourceDistribution") | .spec.deletionPolicy' | sort -u)" Orphan
OUT=$(helm template t "$C" -f "$FIX/basic/values.yaml" --set manifestsDir=m --set strategy=ApplyOnce 2>&1)
eq applyonce "$(printf '%s' "$OUT" | yq ea -N 'select(.kind == "ResourceDistribution") | .spec.manifestRefs[0].strategy' | sort -u)" ApplyOnce

# exact bytes: CRLF and trailing spaces, multi-document files
C=$(chart crlf)
OUT=$(helm template t "$C" -f "$FIX/single.values.yaml" --set manifestsDir=m 2>&1)
data "$OUT" t-ctp-a 10-crlf.yaml > "$WORK/crlf.out"
if cmp -s "$WORK/crlf.out" "$FIX/crlf/manifests/10-crlf.yaml"; then ok crlf-byte-exact; else ko crlf-byte-exact "bytes differ"; fi
C=$(chart multidoc)
OUT=$(helm template t "$C" -f "$FIX/single.values.yaml" --set manifestsDir=m 2>&1)
data "$OUT" t-ctp-a 10-multi.yaml > "$WORK/multi.out"
if cmp -s "$WORK/multi.out" "$FIX/multidoc/manifests/10-multi.yaml"; then ok multidoc-byte-exact; else ko multidoc-byte-exact "bytes differ"; fi

# an escaped {{ renders a literal {{
C=$(chart escape)
OUT=$(helm template t "$C" -f "$FIX/single.values.yaml" --set manifestsDir=m 2>&1)
eq escape-literal-braces "$(data "$OUT" t-ctp-a 10-esc.yaml | yq '.data.template')" "{{ .observed.composite }}"

# render-time failures
C=$(chart basic)
expect_fail fail-no-controlplanes "controlPlanes is empty" "$C" --set manifestsDir=m
printf 'controlPlanes:\n  - name: x\n  - name: x\n' > "$WORK/dup.yaml"
expect_fail fail-duplicate-name "listed twice" "$C" -f "$WORK/dup.yaml" --set manifestsDir=m --set defaults.roleArn=r
printf 'controlPlanes:\n  - values: {}\n' > "$WORK/noname.yaml"
expect_fail fail-missing-name "needs a name" "$C" -f "$WORK/noname.yaml" --set manifestsDir=m
printf 'controlPlanes:\n  - name: %s\n' "$(printf 'a%.0s' $(seq 1 62))" > "$WORK/long.yaml"
expect_fail fail-name-too-long "longer than 63" "$C" -f "$WORK/long.yaml" --set manifestsDir=m --set defaults.roleArn=r
printf 'controlPlanes:\n  - name: ctp-a\n    values: {roleArn: r}\n  - name: ctp-b\n' > "$WORK/missing.yaml"
expect_fail fail-missing-value-names-cp "roleArn is required for control plane ctp-b" "$C" -f "$WORK/missing.yaml" --set manifestsDir=m
head -c 300000 /dev/zero | tr '\0' 'x' | sed 's/^/# /' > "$C/m/50-big.yaml"
expect_fail fail-size "maxManifestBytes" "$C" -f "$FIX/basic/values.yaml" --set manifestsDir=m
expect_fail fail-empty-folder "set manifestsDir=examples/aws-s3" "$(chart empty)" -f "$FIX/single.values.yaml" --set manifestsDir=m
expect_fail fail-default-folder-empty "no *.yaml or *.yml files in manifests" "$(chart)" -f "$FIX/single.values.yaml"
expect_fail fail-bad-key "not a valid ConfigMap key" "$(chart badkey)" -f "$FIX/single.values.yaml" --set manifestsDir=m

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
