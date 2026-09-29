# Networking notes

*[← back to the README](../README.md)*

## WEKA runs `hostNetwork: true`, so NetworkPolicy does not apply

The `WekaClient` container uses the host network namespace. Its traffic never
traverses the CNI's pod network, which means **Kubernetes NetworkPolicy has no
visibility into it and cannot allow or deny any of it.** Security groups are
the only enforcement point for WEKA traffic in this design.

The practical consequences:

- A default-deny NetworkPolicy in the namespace will not break WEKA. It also
  will not protect it. Do not treat one as evidence the data path is governed.
- Conversely, if WEKA traffic is being dropped, the CNI and NetworkPolicy are
  the wrong places to look. Go to the security group.
- Because the client is on the host network, its ports are bound on the **node**
  and can collide with anything else on the host. That is why
  `net.ipv4.ip_local_reserved_ports` is set in the node user data.

## The port matrix — cloud and bare metal differ

Every range below needs **both TCP and UDP**, and needs to be open in **both
directions** (backend↔client, not just client→backend). Self-referencing
security group rules give you the bidirectionality for free.

| Traffic | Cloud deployment | Bare metal deployment |
|---|---|---|
| Management / REST API | `14000` TCP | `14000` TCP |
| Drives containers | `14000–14059` | `14000–14059` |
| Compute containers | `15000–15059` | **`14300–14359`** |
| Frontend containers | `16000–16059` | **`14200–14259`** |

This repo opens the union, `14000–16059`, on both protocols. That is
deliberately blunt for readability; `security-groups.tf` carries a
commented-out block with the narrow per-role rules for anything that has to
pass a security review.

The bare-metal layout packs everything into the `14000–14999` band, so **a rule
set copied from a bare-metal runbook will not match a cloud cluster, and vice
versa.** Before you commit to a range, check what your containers actually
bound:

```bash
weka cluster container   # shows each container's role and ports
```

## UDP is the data path — TCP-only is the classic failure

TCP carries cluster management, the REST API on 14000, and the join handshake.
**UDP carries the data.**

Open TCP only and everything you look at during setup works. The client joins.
`weka status` is green. `weka cluster container` lists your client. The CSI
plugin provisions a PVC and the pod mounts it. And then I/O runs at a small
fraction of the expected throughput, with no error anywhere.

"Joins fine, then performs terribly" is almost always this.

## DPDK without shared networking needs one static IP per WEKA core

WEKA's DPDK data path takes a network interface away from the kernel and drives
it from userspace. In that mode, **each WEKA core needs its own IP address** on
the data-path interface — they are not sharing a kernel socket, so they cannot
share an address.

Sizing consequence: `coresNum: 4` per client node means four secondary IPs per
node *on top of* the node's primary address and every pod IP the VPC CNI hands
out. On an `m6i.8xlarge` you have plenty of ENI and per-ENI IP capacity, but
the **subnet** is the constraint that bites: this is a large part of why
`network.tf` allocates `/20` per private subnet rather than the `/24` a small
cluster would appear to need.

WEKA's *shared networking* (UDP) mode avoids per-core IPs at some throughput
cost. This repo uses the DPDK path, which is what the WEKA module's
`install_cluster_dpdk` and `clients_use_dpdk` defaults give you.

## MTU: at least 4k, and consistent everywhere

Set the data-path MTU to **at least 4000** and make it **identical** on every
interface in the path — backends, clients, and anything in between.

Inconsistency is worse than a uniformly small MTU. A mismatch produces
fragmentation or silent black-holing of large frames, and the symptom is
maddening: small operations succeed, metadata works, `ping` works, and large
reads or writes hang or time out. AWS ENIs support 9001-byte jumbo frames
within a VPC, so there is no reason to run the data path below 4k here — but
check that nothing in your path has quietly been left at 1500.

## Turn pause frames off on data-plane interfaces

Ethernet pause frames (802.3x flow control) let a congested receiver tell the
sender to stop transmitting *everything* on the link. On a WEKA data-plane
interface this is actively harmful: one slow consumer stalls the whole link,
including traffic for unrelated healthy peers, and WEKA's own congestion
handling — which is designed for this and works at the right granularity —
never gets the chance to act.

The failure mode looks like intermittent, correlated latency spikes across
several clients at once with no single obvious culprit. Disable pause frames
(`ethtool -A <iface> rx off tx off` on bare metal; on AWS this is not exposed,
which is one fewer thing to get wrong here — but it matters the moment you move
this design onto your own hardware).

---

---

*[← back to the README](../README.md)*
