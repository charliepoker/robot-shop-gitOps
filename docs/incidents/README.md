# Incident reports

Blameless write-ups of real problems hit while building this platform. Each one records what broke, how it was diagnosed, the root cause, the fix, and what stays open.

| Report | Area | Fixed in |
|---|---|---|
| [ALB 504s on Karpenter nodes](alb-504-karpenter-security-groups.md) | Networking / autoscaling | [#47](https://github.com/charliepoker/robot-shop-gitOps/pull/47) |
| [Kyverno blocking syncs on large SBOMs](kyverno-sbom-admission-limit.md) | Supply-chain enforcement | [#40](https://github.com/charliepoker/robot-shop-gitOps/pull/40), [#41](https://github.com/charliepoker/robot-shop-gitOps/pull/41), [#42](https://github.com/charliepoker/robot-shop-gitOps/pull/42) |
| [node-exporter Pending on full nodes](node-exporter-pending-pod-limit.md) | Observability / scheduling | [#45](https://github.com/charliepoker/robot-shop-gitOps/pull/45) |

These are lab incidents on a personal project, not production outages, so none of them carries user-impact or MTTR figures.
