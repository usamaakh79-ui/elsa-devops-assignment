# Part 4 — GitLab CI → GitHub Actions migration notes

Source: [`ci/legacy.gitlab-ci.yml`](ci/legacy.gitlab-ci.yml) · Result: [`.github/workflows/ci.yml`](.github/workflows/ci.yml)

```
quality (unit tests + Semgrep gate + gate self-test)
   └─► build (build → Trivy gate → [main] push multi-arch :<sha> → cosign sign)
          └─► gitops-bump ([main] commit new tag to charts/quote-api/values.yaml → ArgoCD syncs)
                 └─► e2e ([main] docker compose up -d && ./scripts/run-all.sh on a clean runner)
```

## What changed and why

| Legacy (GitLab) | Problem | Now (GitHub Actions) |
|---|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` hard-coded in `variables:` | Long-lived credentials in Git = leaked the moment the repo is cloned/forked, can't be rotated without a commit, visible in every job log env. (They are AWS doc example values, but the *practice* is the incident.) | **Removed.** No job needs AWS. For a real AWS deploy: GitHub OIDC → `sts:AssumeRoleWithWebIdentity` into a role scoped to `repo:<org>/<repo>:ref:refs/heads/main`, 1-hour creds, no stored secret. I also redacted the values in the committed copy of the legacy file so no secret scanner trips on this repo. |
| `sonar_check` … `allow_failure: true`, only on `master`, scanner 4.6 | A scan that can never fail is decoration; running it only after merge means findings land in master first. | **Semgrep** (`p/python`, `p/dockerfile`, `p/github-actions`, `p/secrets`), runs on **every PR and push**, `--error` → any finding fails the job. A **gate self-test** step scans a deliberately vulnerable canary file and fails the pipeline if Semgrep *doesn't* fail — proves the gate bites, and catches someone quietly adding `continue-on-error`. |
| `npm test \|\| echo "tests flaky, continuing"` | Swallows every test failure; the "flaky" label becomes permanent. | Tests are a hard gate. A genuinely flaky test gets fixed or quarantined *explicitly* (skip with an issue link), never masked in the pipeline. |
| `node:16` | EOL runtime (Sept 2023). | Python 3.13 (service language here), via a SHA-pinned `actions/setup-python`. |
| `docker build -t $IMAGE:latest` + push `latest` only | Unreproducible; can't roll back; can't tell what's running; `kubectl set image :latest` doesn't even trigger a rollout if the tag is unchanged. | Immutable tag = **git SHA** (plus a convenience `latest`). Multi-arch (amd64 + arm64) so Apple Silicon reviewers run natively. OCI labels link image → commit. |
| `docker:20.10-dind` service | Privileged DinD, old Docker. | Runner's native Docker + buildx. |
| — | No image scanning, no provenance. | **Trivy** fails on fixable HIGH/CRITICAL *before* push (the image is built, scanned, then pushed). **cosign keyless** signs the pushed digest using the workflow's OIDC identity — no signing key to manage. |
| `docker login -p "$CI_REGISTRY_PASSWORD"` | Password on the command line (process list / logs). | `GITHUB_TOKEN` via `--password-stdin`, `packages: write` granted only to the build job. |
| `deploy_prod`: `echo "$KUBECONFIG_CONTENT" > /tmp/kubeconfig` + `kubectl set image`, `when: manual` | Cluster-admin kubeconfig stored as a CI variable; imperative, drift-prone deploys; no audit trail of *what* is deployed except the job log. | **GitOps.** CI never touches the cluster. `gitops-bump` commits the new SHA to `charts/quote-api/values.yaml`; ArgoCD (pull-based, in-cluster) syncs it. Git history *is* the deploy log; rollback = `git revert`. The manual approval moves to where it belongs: PR review on main (or a GitHub Environment with required reviewers for prod). |
| `only: [master]` everywhere | Nothing validated before merge. | Quality + build/scan on every PR; push/sign/bump/e2e only on `main`. |
| `bitnami/kubectl:1.24` | Unsupported version; and Bitnami retired its free public image catalog in 2025 (moved to `bitnamilegacy`), so this job would break regardless. | Gone (see GitOps). |
| Implicit `permissions` | GitLab job token has broad project rights. | Workflow default `contents: read`; each job adds only what it needs. |
| Floating action tags | — | All `uses:` pinned to **commit SHAs** (Semgrep's `github-actions-mutable-action-tag` rule actually caught my first draft using `@v4`). Only first-party `actions/*`; other tools are pinned CLI/container versions instead of third-party actions. |

**Added that GitLab never had:** an `e2e` job that runs the reviewer's exact Golden Rule (`docker compose up -d && ./scripts/run-all.sh`) on a clean runner after every merge, so "works on my machine" is continuously tested.

## Exceptions I made to my own gate (and why)

- `toolbox/Dockerfile` runs as root, suppressed with an inline `# nosemgrep` + justification: the toolbox drives the
  host Docker socket (root-equivalent anyway); a non-root `USER` would be cosmetic and would break on hosts whose
  socket GID differs. It's a local dev container, never deployed. Every suppression is inline and reviewable in the
  PR diff — no blanket rule disables.
- `charts/` is in `.semgrepignore` because Helm templates aren't parseable YAML until rendered.

## Migrating GitLab CI variables/secrets for a real project

1. **Inventory**: export project + group-level variables (`GET /projects/:id/variables`, `/groups/:id/variables`) with
   their flags (protected, masked, environment scope). Classify each: *config* vs *secret*, and *who consumes it*.
2. **Delete what shouldn't exist** instead of copying it:
   - cloud keys (AWS/GCP) → **OIDC federation** (GitHub OIDC provider + IAM role trust on `repo:org/repo:environment:prod`);
   - registry passwords → `GITHUB_TOKEN` for GHCR, OIDC for ECR;
   - kubeconfigs → nothing (GitOps; ArgoCD runs in-cluster with its own RBAC).
3. **Map the rest by scope:**
   - non-secret config → GitHub **Variables** (`vars.*`), repo- or org-level;
   - secrets → GitHub **Secrets**; GitLab "protected" + "environment scope" → GitHub **Environments** (`staging`,
     `production`) with branch-protection rules and required reviewers, so prod secrets are only readable by jobs
     targeting that environment from `main`;
   - group-level → **org-level** secrets restricted to selected repositories.
   - Runtime application secrets don't belong in CI at all → AWS Secrets Manager + External Secrets Operator (see OPS-ANSWERS Q4).
4. **Move without exposure:** script it with `gh secret set NAME --env production < value-from-vault` piped from the
   source of truth (Vault/1Password/Secrets Manager) — never paste into chat, tickets or terminals with history.
5. **Rotate everything that ever lived in GitLab** after cutover (assume previous exposure, especially anything that
   was unmasked or echoed in logs, like the legacy `$KUBECONFIG_CONTENT`).
6. **Guardrails:** GitHub secret scanning + push protection on the org; Semgrep `p/secrets` (already in this
   pipeline) on every PR; disable GitLab pipelines and revoke the GitLab tokens after a parallel-run period.

## Things I deliberately did not do

- SonarQube CE self-hosted: heavier (JVM + Postgres in compose) for the same gating outcome on ~100 lines of Python. Semgrep runs in seconds with zero infrastructure.
- Branch protection / required status checks: repository settings, not code — I'd require `quality`, `build` on `main`.
- Image signature *verification* in-cluster (Kyverno/Sigstore policy-controller): the natural next step after signing; out of scope for a local k3d cluster.
