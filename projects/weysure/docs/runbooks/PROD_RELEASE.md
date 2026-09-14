# Runbook — production release

There is no manual release step. A merge to `main` in `Weysure-API` or `Weysure` **is** the release:

1. Jenkins (org folder `beyric`) builds `main`: gitleaks → tests (+coverage) → SonarQube gate → Kaniko →
   Trivy (CRITICAL blocks) → push `ecr/<repo>:<git-sha>` → commit the tag to
   `plateng-gitops/projects/weysure/environments/prod/images.yaml` as `beyric-ci[bot]`.
2. Argo CD picks the commit up within 3 min: PreSync migration Job, then rolling update.

**Before merging a release with a migration:** confirm it is expand/contract (old pods run for ~1 min
against the new schema). **After:** `kubectl get app weysure-api -n argocd` Healthy;
`curl https://weysure-api.beyrictech.com/api/v1/health` 200. Bad release →
[DEPLOYMENT_ROLLBACK.md](DEPLOYMENT_ROLLBACK.md).

Watch a build: https://jenkins.beyrictech.com/job/beyric/job/Weysure-API/job/main/
