# ALB 504s for pods on Karpenter nodes

**Area:** networking, autoscaling | **Phase:** 5 (latent since Phase 2) | **Fix:** [#47](https://github.com/charliepoker/robot-shop-gitOps/pull/47)

## Summary
After exposing Grafana and Prometheus on the shared ALB, Grafana returned **504 Gateway Timeout** although its pod was healthy. The AWS Load Balancer Controller never opened the ALB-to-pod path for pods on Karpenter nodes, because those nodes carried two cluster-tagged security groups. The same bug had existed since Phase 2 and was hidden by pod placement.

## Impact
Grafana and Prometheus unreachable through the ALB while they ran on a Karpenter node. The shop kept working only because its `web` pods happened to run on the managed node group. No user traffic was affected; this was found during build-out.

## Detection
A 504 on the Grafana hostname right after the Ingress went live. DNS resolved and TLS terminated, so the failure was between the ALB and the pod. The Prometheus target group showed no healthy targets.

## Root cause
- In IP mode the controller registers pod IPs directly and adds an inbound rule from the ALB's security group to the security group on the pod's network interface. It selects the group tagged `kubernetes.io/cluster/robot-shop` and **requires exactly one**.
- The EKS module applied the `karpenter.sh/discovery` tag through module-level `tags`, so it landed on **both** the node security group and the cluster primary security group.
- The EC2NodeClass selected security groups by that tag alone, so every Karpenter node got both. With two candidates the controller added no rule, health checks to ports 3000 and 9090 timed out (`Target.Timeout`), and requests became 504s.
- Baseline managed nodes carry only the node security group, which is why workloads there were fine.

## Resolution
Added a second condition to the EC2NodeClass selector so only the node security group matches:

```yaml
securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: robot-shop
      Name: robot-shop-node
```

Karpenter marked its existing nodes as drifted and replaced them on its own. Targets went healthy and the 504s stopped.

## What went well
- Reading target-group health first separated "ALB can't reach the pod" from a bad health-check path or listener rule.
- Karpenter's drift handling rolled the fix out with no manual node work.

## Lessons
- A bug can sit unseen for weeks when placement hides it. Check both node types, not just the one that works.
- Tag scope is part of an API contract: a module-level tag meant for one resource silently matched two.

## Open follow-ups
- Fix at the source: apply the discovery tag only to the node security group in the EKS module, so the selector no longer needs a `Name` condition. (Infra repo; not done as of this report.)
