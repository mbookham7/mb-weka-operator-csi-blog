# Node preparation, and why editing a comment can roll your fleet

*[← back to the README](../README.md)*

`node-userdata.tf` is described elsewhere in this repo as the most important
file in it. This page covers two things: why the node preparation has to
happen in user data at all, and the rule that governs how that file is
commented.

## Why any of this is in user data

Everything the file does configures the node **before the kubelet starts**,
and none of it can be done afterwards from a manifest. That is the entire
reason it is not a privileged DaemonSet.

| | Why it cannot wait |
|---|---|
| **HugePages** | A DaemonSet can write `vm.nr_hugepages`, but the kernel can only satisfy a large hugepage request while physical memory is still unfragmented — i.e. at boot. Ask an hour into a node's life and you get a partial allocation, or none. Worse, the kubelet only reports `hugepages-2Mi` as allocatable if the pages exist when it makes its first node status update. Set them later and the WekaClient pod stays Pending on a resource the node genuinely has. |
| **CPU manager** | `cpuManagerPolicy` and `reservedSystemCPUs` are kubelet configuration, read once at kubelet startup. Changing the policy also requires deleting `/var/lib/kubelet/cpu_manager_state`, because the kubelet refuses to start when the persisted policy disagrees with its configuration. Not something a pod can do to the kubelet running it. |
| **Kernel headers** | The WEKA driver is compiled against the running kernel. Installing headers is ordinary package work, but doing it before the kubelet starts means the driver build cannot race the client pod that needs it. |

## Payload vs commentary

The two heredocs in `node-userdata.tf` are **not source code**. They are
strings that become the launch template's user data, and every byte inside
them — comments included — is part of that string.

So a comment written *inside* a heredoc is not documentation. It is payload:

```
edit a comment inside <<-SCRIPT or <<-NODECONFIG
  -> the rendered user data changes
    -> Terraform creates a new launch template version
      -> the module moves the LT default version, because
         update_launch_template_default_version defaults to true
        -> aws_eks_node_group.launch_template.version changes
          -> EKS ROLLS EVERY NODE IN THE GROUP
```

Every node in that group is a WEKA client.
[`10-poddisruptionbudgets.yaml`](node-group.md#disruption-pacing-a-node-group-roll)
restrains that roll — but only once its selector is filled in, since the
client pod labels come from the operator at runtime rather than from the
chart. A typo fix should not be able to cycle
the storage clients of a live cluster — and before the split, it could. One 37-line comment added to the sysctl block grew the
rendered script from 3302 to 5332 bytes.

**The rule:**

- Reasoning, arithmetic, provenance, war stories → Terraform `#` comments
  *outside* the heredocs, where they cost nothing and change nothing.
- *Inside* a heredoc → only what someone SSH'd into a node needs in order not
  to break it, kept short, plus a pointer back to the file.

Interpolated values (`${...}`) are a different matter: those *should* churn
the user data, because a changed core count or `maxPods` is a real
configuration change the nodes need replacing to pick up.

The split cut the rendered payload from 9955 to 2624 bytes — 73% — with
behaviour byte-identical once comments and blanks are stripped.

## Changing a real value: what actually happens

A running node never re-reads its user data; the script executes once, at
first boot. But you do **not** have to trigger the replacement yourself:
because the module updates the launch template default version and the node
group references it, `terraform apply` hands EKS a new LT version and EKS
performs a rolling node-group update on its own.

Plan accordingly. **`terraform plan` showing a launch-template change means
every node in the group is about to be replaced**, one at a time. Whether
anything paces that depends on the PodDisruptionBudgets having a real
selector — see [The client node group](node-group.md). If you want that to be
an explicit decision rather than a side effect, set
`update_launch_template_default_version = false` on the node group in
`eks.tf` and move the version forward deliberately.

---

*[← back to the README](../README.md)*
