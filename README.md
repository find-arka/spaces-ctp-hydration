# spaces-ctp-hydration

A Helm chart that hydrates Upbound Spaces control planes: it installs the objects a control plane needs before any workload, such as `DeploymentRuntimeConfig`s, `Provider`s, provider configs and `ServiceAccount`s.

You keep each object as a manifest file in a folder. For every control plane you list, the chart renders the folder with that control plane's values and creates a ConfigMap plus a `ResourceDistribution` in the Space. Spaces then applies the files inside that control plane and reports the result.

> Reference only. This repo shows one way to use the alpha `ResourceDistribution` API (`spaces.upbound.io/v1alpha1`). It was tested on a Spaces `1.19.0-rc.0.182.g1ace58e19` dev build. Clone it and adapt it. It is not maintained or supported.

```
 manifests/ (your files)          Space (host cluster), namespace = Spaces group
   10-drc.yaml                    ┌──────────────────────────────────────────────────┐
   20-provider.yaml  helm upgrade │ ConfigMap + ResourceDistribution  <release>-ctp-a │──► ctp-a
   40-sa.yaml        ──────────►  │ ConfigMap + ResourceDistribution  <release>-ctp-b │──► ctp-b
 values.yaml           --install  └──────────────────────────────────────────────────┘
   defaults: {...}                  each ConfigMap = the folder rendered with
   controlPlanes: [ctp-a, ctp-b]    defaults + that control plane's values
```

## Try the example

`examples/aws-s3` installs a two-replica `DeploymentRuntimeConfig`, `provider-aws-s3` using it, an AWS `ClusterProviderConfig`, and a `ServiceAccount` with a per-control-plane role ARN. It targets two control planes, `my-controlplane-1` and `my-controlplane-2`, in group `default`.

Run the chart against the Space (host cluster), in the namespace (group) of the control planes:

```bash
git clone https://github.com/find-arka/spaces-ctp-hydration.git
cd spaces-ctp-hydration
helm template hydrate . -n default -f examples/aws-s3/values.yaml        # preview
helm upgrade --install hydrate . -n default -f examples/aws-s3/values.yaml
```

Verify:

```bash
kubectl -n default get rd -l app.kubernetes.io/instance=hydrate           # PROVISIONED 1/1 each
kubectl -n default get rdb -l spaces.upbound.io/resource-distribution=hydrate-my-controlplane-1 -o yaml | yq '.items[].status'
```

## Use your own manifests

1. Put your files in `manifests/`. Write them by hand, or generate them with any tool.
2. List your control planes and their values in a values file:

   ```yaml
   defaults:
     providerPackage: xpkg.upbound.io/upbound/provider-aws-s3:v2.7.0
   controlPlanes:
     - name: team-a
       values:
         roleArn: arn:aws:iam::111111111111:role/team-a
   ```

3. `helm upgrade --install <release> . -n <group> -f <values file>`

Each file is a Helm template. It sees:
- `.Values`: the control plane's `values` merged over `defaults`
- `.ControlPlane`: the control plane's name
- `.Release` and `.Chart`

Use `required` for values that must be set, and put `.ControlPlane` in the message so the error names the control plane:

```yaml
eks.amazonaws.com/role-arn: {{ required (printf "roleArn is required for control plane %s" .ControlPlane) .Values.roleArn | quote }}
```

### Rules

- **Files:** `*.yaml` and `*.yml` directly in the folder. Subfolders and files starting with `.` are skipped. A file may hold several documents separated by `---`.
- **Order:** the file name is the ConfigMap key. Spaces applies keys in byte-wise lexicographic order, so use number prefixes of the same width (`10-`, `20-`, `30-`); `9-` sorts after `10-`. The order does not make a file wait for an earlier one to succeed. A manifest whose CRD does not exist yet is retried until it does.
- **Templating:** a literal `{{` in a manifest, for example in a go-templating composition, must be written as `{{ "{{" }}`.
- **Size:** the rendered files per control plane must fit in `maxManifestBytes`. The default is 256 KiB, the limit for client-side `kubectl apply`. Helm 4 applies server-side, and so does Argo CD with `ServerSideApply=true`. With either, you can raise it to about `900000`, since a ConfigMap holds 1 MiB.
- **Credentials:** none. ConfigMaps are not secret. Create Secrets in the control plane another way, for example with Spaces Shared Secrets.

## Values

| Key | Default | Meaning |
|---|---|---|
| `manifestsDir` | `manifests` | Folder, relative to the chart root, whose files are distributed. Helm can only read files inside the chart, so it must be inside this repo |
| `defaults` | `{}` | Values shared by every control plane |
| `controlPlanes` | `[]` | `{name, values}` per control plane. Each gets a ConfigMap and a ResourceDistribution named `<release>-<name>` (at most 63 characters) |
| `deletionPolicy` | `Orphan` | `Orphan` keeps applied objects when a file, a control plane entry or the release is removed. `Delete` removes them |
| `strategy` | `""` | Empty uses the server default, `Reconcile`: objects are kept applied and drift is reverted. `ApplyOnce` creates objects once and never updates them |
| `maxManifestBytes` | `262144` | Render-time size limit per control plane |

The chart fails at render time, with a message, on:
- an empty folder or an empty `controlPlanes`
- a missing or duplicate control plane name
- a name over 63 characters
- a file name that is not a valid ConfigMap key
- a missing `required` value
- output over `maxManifestBytes`

## Running it from a pipeline

- **Argo CD:** `argocd/application.yaml` syncs the chart from git to the Space. `argocd/health-check.yaml` makes Argo CD report a ResourceDistribution as Healthy only once every control plane applied it. Both are borrowed from an Upbound engineering example and have **not been tested in this repo yet**. Argo CD renders the chart with `helm template`, so the manifest files must be committed.
- **Azure DevOps or any CI:** generate the files into `manifests/`, then run `helm upgrade --install`.

## Things to know

- `Ready` on a ResourceDistribution means the manifests were applied, not that the providers are healthy. Check inside the control plane.
- Removing a control plane from `controlPlanes` deletes its ConfigMap and ResourceDistribution. Its objects stay or go according to `deletionPolicy`.
- An object can be managed by one distribution only. Don't target the same objects from two releases.
- See the walkthrough and the behaviors observed during testing in the [ResourceDistribution gist](https://gist.github.com/find-arka/f9ef871d1c8ebcf14aba8f04071e928c).
