# node-exporter pods Pending on full nodes

**Area:** observability, scheduling | **Phase:** 5 | **Fix:** [#45](https://github.com/charliepoker/robot-shop-gitOps/pull/45)

## Summary
After deploying kube-prometheus-stack, two of the four node-exporter DaemonSet pods stayed `Pending`. The nodes they were pinned to had hit their pod limit, and nothing outranked the pods already there, so the scheduler could not make room. Giving node-exporter the `system-node-critical` priority class fixed it.

## Impact
Host metrics were missing for two of four nodes. No workload impact.

## Detection
Spotted while checking the monitoring pods before capturing evidence: every other pod was `Running`, but two node-exporter pods showed no node assigned.

## Root cause
The scheduler's events were explicit:

```
0/4 nodes are available: 1 Too many pods, 3 node(s) didn't satisfy plugin(s) [NodeAffinity].
preemption: ... 1 No preemption victims found for incoming pod
```

- A DaemonSet pins each pod to one specific node. The "NodeAffinity" lines are expected; "Too many pods" is the real one.
- The baseline nodes are `t3.medium`, which allows 17 pods each with the default VPC CNI. Platform tools filled them (Argo CD, Karpenter, cert-manager, External Secrets, Kyverno, Velero and others).
- Karpenter could not help: a DaemonSet pod cannot move to a different node, so new capacity does not solve a full pinned node.
- Preemption found no victims because every pod had priority 0 and node-exporter had no higher priority.
- Note: I did not capture the per-node pod counts to confirm 17 on each full node. The diagnosis rests on the scheduler events and on the fix working.

## Resolution
Set `priorityClassName: system-node-critical` on node-exporter in the `kube-prometheus-stack` values. The scheduler can now evict one lower-priority pod per full node; the evicted pod reschedules, and Karpenter adds capacity if nothing else fits. All four node-exporter pods became `Running`.

## What went well
- Reading the scheduler events (not the symptom) pointed straight at pod density rather than at taints or ports.

## Lessons
- Node-level agents should outrank ordinary workloads, and Karpenter cannot fix capacity problems for DaemonSets.
- Pod density is a hard per-instance ceiling that CPU and memory metrics will not show.

## Open follow-ups
- Consider VPC CNI prefix delegation to raise the per-node pod limit without larger instances (cost phase).
- Size the baseline node group for the platform tools plus observability, not the tools alone.
