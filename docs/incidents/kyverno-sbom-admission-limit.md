# Kyverno blocking Argo CD syncs on large SBOM attestations

**Area:** supply-chain enforcement | **Phase:** 4 | **Fix:** [#40](https://github.com/charliepoker/robot-shop-gitOps/pull/40), [#41](https://github.com/charliepoker/robot-shop-gitOps/pull/41), [#42](https://github.com/charliepoker/robot-shop-gitOps/pull/42)

## Summary
Argo CD reported a ComparisonError for the whole `robot-shop` app. The cause was Kyverno failing admission on `ratings` and `shipping` with "context size limit exceeded" while verifying their SBOM attestations. A first fix did nothing, because Kyverno silently ignored a per-rule failure action. Splitting one policy into two fixed it.

## Impact
Argo CD could not diff or sync the `robot-shop` app. That blocked the database-credential fix for `ratings` and `shipping` from deploying. No user-facing impact.

## Detection
Argo CD showed ComparisonError on the app. The same failure repeated for `shipping` after `ratings` was addressed.

## Root cause
1. `ratings`' full CycloneDX SBOM is about 2.9 MB, above Kyverno's roughly 2 MiB admission processing limit. Verifying the attestation therefore failed. That is a capacity limit, not evidence the image was untrusted.
2. The first fix (#40) set only the SBOM rule to `Audit` inside a policy that stayed `Enforce`. Kyverno drops a per-rule `validationFailureAction` on a `verifyImages` rule, confirmed by `status.autogen.rules` showing it unset after apply. So `shipping` hit the same error.

## Resolution
- #41: split the combined policy into two `ClusterPolicy` resources. Signature verification stays `Enforce`; SBOM attestation verification is `Audit` (violations still land in PolicyReports).
- #42: Kyverno rejects `mutateDigest: true` on an `Audit` policy, so that setting was corrected for the SBOM policy.

## What went well
- Checking the policy's applied status showed the setting was being dropped, instead of assuming the manifest was in effect.
- Signature enforcement was never loosened to unblock the deploy.

## Lessons
- Verify what the controller applied, not what you wrote.
- Separate a security control's hard requirement (valid signature) from a nice-to-have that has a capacity ceiling (SBOM content).

## Open follow-ups
- **Trade-off accepted:** SBOM attestations are audited, not enforced, at admission.
- Investigate whether the limit is configurable in this Kyverno version, or whether a smaller attested SBOM (leaner base image, fewer packages) would fit under it and allow enforcement again.
