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
# The inline manifests of ResourceDistribution $2, as JSON, from rendered output $1.
mf() { printf '%s' "$1" | yq ea -N -o json "select(.metadata.name == \"$2\") | .spec.sources[0].inline.manifests"; }
expect_fail() { # name, expected message substring, helm template args...
  local name=$1 want=$2; shift 2
  local out
  if out=$(helm template t "$@" 2>&1); then ko "$name" "rendered, expected failure"; return; fi
  if printf '%s' "$out" | grep -qF -- "$want"; then ok "$name"; else ko "$name" "error lacks [$want]: $out"; fi
}

# basic: two control planes, templated values, skipped files
C=$(chart basic)
OUT=$(helm template t "$C" -n grp -f "$FIX/basic/values.yaml" --set manifestsDir=m 2>&1) || ko basic-render "$OUT"
eq basic-only-rds "$(printf '%s' "$OUT" | yq ea -N '.kind' | sort -u)" ResourceDistribution
eq basic-rd-names "$(printf '%s' "$OUT" | yq ea -N '.metadata.name' | paste -sd, -)" "t-ctp-a,t-ctp-b"
eq basic-selector "$(printf '%s' "$OUT" | yq ea -N 'select(.metadata.name == "t-ctp-b") | .spec.controlPlaneSelector.names[0]')" ctp-b
eq basic-source-type "$(printf '%s' "$OUT" | yq ea -N '.spec.sources[0].type' | sort -u)" Inline
eq basic-namespace "$(printf '%s' "$OUT" | yq ea -N '.metadata.namespace' | sort -u | paste -sd, -)" grp
eq basic-skip-dotfile-subdir-md "$(mf "$OUT" t-ctp-a | jq -r 'map(.metadata.name) | join(",")')" "hello,provider-identity"
eq basic-per-cp-value "$(mf "$OUT" t-ctp-b | jq -r '.[1].metadata.annotations["example.com/role-arn"]')" "arn:aws:iam::111111111111:role/ctp-b"
eq basic-controlplane-var "$(mf "$OUT" t-ctp-a | jq -r '.[0].data.controlPlane')" ctp-a
eq basic-special-chars "$(mf "$OUT" t-ctp-a | jq -r '.[0].data.note')" "a: b # not a comment"
eq basic-strategy-default-absent "$(printf '%s' "$OUT" | yq ea -N '.spec.sources[0].strategy' | sort -u)" null
eq basic-deletion-default "$(printf '%s' "$OUT" | yq ea -N '.spec.deletionPolicy' | sort -u)" Orphan
OUT=$(helm template t "$C" -f "$FIX/basic/values.yaml" --set manifestsDir=m --set strategy=ApplyOnce 2>&1)
eq applyonce "$(printf '%s' "$OUT" | yq ea -N '.spec.sources[0].strategy' | sort -u)" ApplyOnce

# parsing: CRLF and trailing spaces, several documents per file, file-name order
C=$(chart crlf)
OUT=$(helm template t "$C" -f "$FIX/single.values.yaml" --set manifestsDir=m 2>&1)
eq crlf-parsed "$(mf "$OUT" t-ctp-a | jq -r '.[0].kind + "/" + .[0].metadata.name')" "ConfigMap/crlf"
C=$(chart multidoc)
OUT=$(helm template t "$C" -f "$FIX/single.values.yaml" --set manifestsDir=m 2>&1)
eq multidoc-order "$(mf "$OUT" t-ctp-a | jq -r 'map(.metadata.name) | join(",")')" "three,one,two"

# an escaped {{ renders a literal {{
C=$(chart escape)
OUT=$(helm template t "$C" -f "$FIX/single.values.yaml" --set manifestsDir=m 2>&1)
eq escape-literal-braces "$(mf "$OUT" t-ctp-a | jq -r '.[0].data.template')" "{{ .observed.composite }}"

# example: examples/aws-s3, two control planes with their own role ARN
OUT=$(helm template t "$(chart)" -f "$ROOT/examples/aws-s3/values.yaml" 2>&1) || ko example-render "$OUT"
eq example-kinds "$(mf "$OUT" t-my-controlplane-1 | jq -r 'map(.kind) | join(",")')" "DeploymentRuntimeConfig,Provider,ClusterProviderConfig,ServiceAccount"
eq example-role-cp1 "$(mf "$OUT" t-my-controlplane-1 | jq -r '.[3].metadata.annotations["eks.amazonaws.com/role-arn"]')" "arn:aws:iam::111111111111:role/my-controlplane-1-providers"
eq example-role-cp2 "$(mf "$OUT" t-my-controlplane-2 | jq -r '.[3].metadata.annotations["eks.amazonaws.com/role-arn"]')" "arn:aws:iam::111111111111:role/my-controlplane-2-providers"
eq example-shared-default "$(mf "$OUT" t-my-controlplane-2 | jq -r '.[1].spec.package')" "xpkg.upbound.io/upbound/provider-aws-s3:v2.7.0"
eq example-int-kept "$(mf "$OUT" t-my-controlplane-1 | jq -r '.[0].spec.deploymentTemplate.spec.replicas | type')" number

eq example-dot-slash-dir "$(helm template t "$(chart)" -f "$ROOT/examples/aws-s3/values.yaml" --set manifestsDir=./examples/aws-s3/manifests 2>&1 | yq ea -N '[select(.kind == "ResourceDistribution")] | length')" 2
expect_fail example-missing-value-names-cp "for control plane my-controlplane-1" "$(chart)" -f "$ROOT/examples/aws-s3/values.yaml" --set defaults.providerPackage=null

# example: examples/azure-storage
OUT=$(helm template t "$(chart)" -f "$ROOT/examples/azure-storage/values.yaml" 2>&1) || ko azure-example-render "$OUT"
eq azure-example-kinds "$(mf "$OUT" t-my-controlplane-2 | jq -r 'map(.kind) | join(",")')" "Provider,ClusterProviderConfig"
eq azure-example-providerconfig "$(mf "$OUT" t-my-controlplane-1 | jq -r '.[1].apiVersion + " " + .[1].spec.credentials.secretRef.name')" "azure.m.upbound.io/v1beta1 azure-secret"

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
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: big}\ndata: {x: %s}\n' "$(head -c 300000 /dev/zero | tr '\0' 'x')" > "$C/m/50-big.yaml"
expect_fail fail-size "maxManifestBytes" "$C" -f "$FIX/basic/values.yaml" --set manifestsDir=m
expect_fail fail-empty-folder "-f examples/aws-s3/values.yaml" "$(chart empty)" -f "$FIX/single.values.yaml" --set manifestsDir=m
expect_fail fail-default-folder-empty "no *.yaml or *.yml files in manifests" "$(chart)" -f "$FIX/single.values.yaml"
expect_fail fail-no-name "10-noname.yaml (control plane ctp-a), document 2: every manifest needs apiVersion, kind and metadata.name" "$(chart noname)" -f "$FIX/single.values.yaml" --set manifestsDir=m
expect_fail fail-bad-yaml "10-bad.yaml (control plane ctp-a), document 1" "$(chart badyaml)" -f "$FIX/single.values.yaml" --set manifestsDir=m
expect_fail fail-comments-only "hold no manifests for control plane ctp-a" "$(chart comments)" -f "$FIX/single.values.yaml" --set manifestsDir=m
C=$(chart basic)
for i in $(seq 1 101); do printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: c%d}\n' "$i"; done > "$C/m/30-many.yaml"
expect_fail fail-over-100 "at most 100" "$C" -f "$FIX/basic/values.yaml" --set manifestsDir=m

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
