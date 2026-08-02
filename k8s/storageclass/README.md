# OpenEBS Local PV HostPath

Install the OpenEBS Local PV HostPath provisioner and the `openebs-hostpath` StorageClass without Helm:

```sh
./k8s/storageclass/install-openebs-hostpath.sh
```

The script supports macOS (for example OrbStack or Docker Desktop Kubernetes) and Linux. It uses the current `kubectl` context, installs OpenEBS's lightweight Local PV manifest, removes its unused NDM DaemonSet, waits for the HostPath provisioner, and applies the StorageClass YAML in this directory. NDM is needed for device-backed Local PVs, not HostPath; removing it prevents `/run/udev` mount failures on desktop Kubernetes nodes.

Configure it per environment with environment variables:

```sh
LOCALPV_BASE_PATH=/mnt/openebs/local \
STORAGE_CLASS_NAME=openebs-hostpath-prod \
IS_DEFAULT_STORAGE_CLASS=false \
./k8s/storageclass/install-openebs-hostpath.sh
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `LOCALPV_BASE_PATH` | `/var/openebs/local` | Absolute path on each Kubernetes node where local volumes are stored. |
| `STORAGE_CLASS_NAME` | `openebs-hostpath` | Name of the created StorageClass. |
| `IS_DEFAULT_STORAGE_CLASS` | `false` | Set to `true` only when this should be the cluster default. |
| `WAIT_TIMEOUT` | `180s` | Time to wait for the provisioner Deployment. |
| `OPENEBS_MANIFEST_URL` | OpenEBS lightweight manifest | Override for a vetted, pinned manifest URL when an environment requires version pinning. |

Local PV volumes are tied to the node where the consuming Pod is scheduled. They are appropriate for single-node local/test clusters and workloads designed for node-local storage; use a cloud-provider storage class for workloads that need cross-node storage availability.
