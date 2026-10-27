# spaces-ctp-hydration

A Helm chart that hydrates Upbound Spaces control planes with what they need before any workload: `DeploymentRuntimeConfig`s, `Provider`s, provider configs, `ServiceAccount`s and anything else you write as a manifest.

Each manifest is a file in a folder. For every control plane you list, the chart renders the folder with that control plane's values into one `ResourceDistribution` in the Space, with the manifests inline, and Spaces applies them inside that control plane.

> Reference only, not maintained or supported. Clone it and adapt it. Tested with the alpha `ResourceDistribution` API (`spaces.upbound.io/v1alpha1`) on a Spaces `1.19.0-rc.0.217.gdf4dfaa02` dev build. Earlier builds took the manifests from a ConfigMap; this chart no longer renders one.

```
 manifests/ (your files)          Space (host cluster), namespace = Spaces group
   10-drc.yaml                    ┌──────────────────────────────────────┐
   20-provider.yaml  helm upgrade │ ResourceDistribution  <release>-ctp-a │──► ctp-a
   40-sa.yaml        ──────────►  │ ResourceDistribution  <release>-ctp-b │──► ctp-b
 values.yaml           --install  └──────────────────────────────────────┘
   defaults: {...}                  each one holds the folder rendered with
   controlPlanes: [ctp-a, ctp-b]    defaults + that control plane's values
```

## Use your own manifests

```bash
git clone https://github.com/find-arka/spaces-ctp-hydration.git
cd spaces-ctp-hydration
```

1. Put your files in `manifests/`. Generate them with your automation pipeline.
2. List your control planes and their values in a values file:

   ```yaml
   defaults:
     providerPackage: xpkg.upbound.io/upbound/provider-aws-s3:v2.7.0
   controlPlanes:
     - name: team-a
       values:
         roleArn: arn:aws:iam::111111111111:role/team-a
   ```

3. Run the chart against the Space (host cluster), in the namespace (group) of the control planes: `helm upgrade --install <release> . -n <group> -f <values file>`

Each file is a Helm template. `.Values` holds the control plane's `values` merged over `defaults`, and `.ControlPlane` is its name. Put `.ControlPlane` in `required` messages so an error names the control plane:

```yaml
eks.amazonaws.com/role-arn: {{ required (printf "roleArn is required for control plane %s" .ControlPlane) .Values.roleArn | quote }}
```

Rules for the files:

- Only `*.yaml` and `*.yml` directly in the folder count. Subfolders and files starting with `.` are skipped. A file may hold several documents separated by `---`. Each document needs `apiVersion`, `kind` and `metadata.name`, and the chart fails on one without them.
- The file name sets the order. The chart lists the documents in byte-wise file-name order, then in order within each file, and Spaces applies them in that order. Use number prefixes of the same width (`10-`, `20-`); `9-` sorts after `10-`. A manifest does not wait for an earlier one to succeed. A manifest whose CRD doesn't exist yet is retried until it does.
- The chart parses each document and writes it back as YAML, so comments and formatting are not kept.
- Write a literal `{{`, for example in a go-templating composition, as `{{ "{{" }}`.
- Don't put credentials in the files. The manifests are stored in plain text in the ResourceDistribution. Use Spaces Shared Secrets or create the Secret in the control plane.

## Try the example

`examples/aws-s3` installs a two-replica `DeploymentRuntimeConfig`, `provider-aws-s3` using it, an AWS `ClusterProviderConfig`, and a `ServiceAccount` with a different role ARN per control plane. It targets `my-controlplane-1` and `my-controlplane-2` in group `default`.

`examples/azure-storage` does the same for Azure: `provider-azure-storage` and a `ClusterProviderConfig` that reads a service principal from `crossplane-system/azure-secret`, which you create in each control plane first. Use it with `-f examples/azure-storage/values.yaml`.

The examples template a few fields (`providerPackage`, `providerReplicas`, `roleArn`) to show the pattern. They don't expose every `DeploymentRuntimeConfig` or provider field, and the chart has no per-kind values. Write whatever your control planes need into the manifest files, as plain YAML or with your own values.

```bash
helm template hydrate . -n default -f examples/aws-s3/values.yaml        # preview
helm upgrade --install hydrate . -n default -f examples/aws-s3/values.yaml
kubectl -n default get rd -l app.kubernetes.io/instance=hydrate           # PROVISIONED 1/1 each
kubectl -n default get rdb -l spaces.upbound.io/resource-distribution=hydrate-my-controlplane-1 -o yaml | yq '.items[].status'
```

## Values

| Key | Default | Meaning |
|---|---|---|
| `manifestsDir` | `manifests` | Folder of files to distribute, relative to the chart root. Helm only reads files inside the chart |
| `defaults` | `{}` | Values shared by every control plane |
| `controlPlanes` | `[]` | `{name, values}` per control plane. Each gets a ResourceDistribution named `<release>-<name>`, at most 63 characters |
| `deletionPolicy` | `Orphan` | `Orphan` keeps applied objects when a file, a control plane entry or the release is removed. `Delete` removes them, except `ApplyOnce` objects |
| `strategy` | `""` | Empty means `Reconcile`: objects stay applied and drift is reverted. `ApplyOnce` creates objects once and never updates them |
| `maxManifestBytes` | `262144` | Size limit for the rendered manifests per control plane. 256 KiB is the limit for client-side `kubectl apply`, which Argo CD uses by default. With server-side apply (Helm 4 by default, or Argo CD with `ServerSideApply=true`) the limit is etcd's object size, about 1.5 MiB |

The chart stops with an error on:
- an empty folder or `controlPlanes` list
- a missing or duplicate name, or a name over 63 characters
- a document that isn't valid YAML or lacks `apiVersion`, `kind` or `metadata.name`, naming the file and document
- files with no manifests, or more than 100 manifests (one source's limit)
- a missing `required` value
- output over `maxManifestBytes`

## Running it from a pipeline

From Azure DevOps or any CI, generate the files into `manifests/` and run `helm upgrade --install`.

For Argo CD, `argocd/application.yaml` syncs the chart from git to the Space, and `argocd/health-check.yaml` reports a ResourceDistribution as Healthy once every control plane applied it. Both are borrowed from an Upbound engineering example and **have not been tested in this repo yet**. Argo CD renders the chart from git, so commit the generated files.

## Things to know

- `Ready` on a ResourceDistribution means the manifests were applied. Check provider health inside the control plane.
- A name that matches no control plane, such as a typo, also shows `Ready`, with `PROVISIONED 0/0`. Check for `1/1`.
- Template errors point at `templates/hydration.yaml`. The message, or the file content quoted in it, shows which file failed.
- Removing a control plane from `controlPlanes` deletes its ResourceDistribution. Its objects follow `deletionPolicy`.
- An object can belong to one distribution only, so don't target the same objects from two releases.

The [ResourceDistribution gist](https://gist.github.com/find-arka/f9ef871d1c8ebcf14aba8f04071e928c) has a full walkthrough and the behaviors observed in testing.
