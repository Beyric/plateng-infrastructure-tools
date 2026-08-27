# Secret Exposure History — Full-History Scan of All Four Repositories

| | |
|---|---|
| **Date performed** | 2026-08-27 |
| **Scanner** | `gitleaks` v8.30.1, default rule set (no `.gitleaks.toml` present in either application repo at scan time) |
| **Scope** | Full commit history, all refs (`--log-opts="--all"`), all four repositories |
| **Status** | Read-only investigation. No secret values were printed, logged, or written anywhere in this process — every scan used `--redact`. |
| **Relates to** | Finding ⑯ and Finding ⑰ in [`docs/plans/2026-08-26-phase-0-foundations.md`](plans/2026-08-26-phase-0-foundations.md); corrects/confirms the counts first produced during that plan's Task 2 |

---

## 1. Headline result

Every credential this scan surfaced in `Weysure-API` and `Weysure` history has **already been
rotated** (Paystack, all Supabase keys, the database password, SMTP, `SECRET_KEY`). Nothing
below is a live-risk finding — it is a record of historical exposure of now-dead credentials,
kept so the exposure is documented, the blast radius is bounded, and a future engineer does not
have to re-derive any of this from raw git log. The two platform repositories
(`plateng-infrastructure-tools`, `plateng-gitops`) came back effectively clean, as expected.

| Repository | Findings | Disposition |
|---|---:|---|
| `plateng-infrastructure-tools` | 7 | All `aws-access-token`, all one historical commit, pre-dating the Task 2 fix. Public access-key ID only (not the secret half); key is already slated for deletion under Task 7. Not a live-risk finding. |
| `plateng-gitops` | 0 | Clean. Two-commit repo; nothing to find. |
| `Weysure-API` | 76 | Historical `.env` exposure (Finding ⑯) + hardcoded test-project creds (Finding ⑰) + doc placeholders + expired log tokens. All rotated where real. |
| `Weysure` | 44 | Placeholder API keys in developer docs / developer-portal UI, plus two fake JWTs in a test-only compose file. No real credentials found. |

---

## 2. Methodology

```bash
gitleaks detect --source <repo> \
  --log-opts="--all" \
  --report-format json \
  --report-path <out>.json \
  --redact \
  --no-banner \
  --exit-code 0
```

- **`--log-opts="--all"`**: scans every ref (all local and remote-tracking branches), not just
  the currently checked-out branch. `Weysure-API` carries an extra `origin/supabase` branch;
  this flag guarantees it isn't silently skipped.
- **`--redact`**: replaces `Match` and `Secret` in both stdout and the JSON report with
  `REDACTED`. Verified empirically (see report JSON) before any further inspection.
- **Full history, not `--diff-filter=A`.** The original Finding ⑯ investigation used
  `git log --diff-filter=A -- .env`, which reports only the commit that *added* the path and is
  blind to every later modification. That undercounted the exposure as "one commit." The
  correct method — used here and by gitleaks' own history walk — is `git log --all --oneline --
  <path>`, which finds every commit that touched the file. Re-run below to confirm the figure
  independently of gitleaks:

```bash
cd ~/Documents/dev/weysure/Weysure-API && git log --all --oneline --date=short --pretty=format:'%h %ad %s' -- .env
```

  Result: **9 commits**, `52f89f2` (2025-07-07) through `6b2e901` (2026-03-25) — confirmed, not
  8, not 1. `.env.example` was touched separately in 5 commits, most recently `46f73c4`
  (2026-04-02), and never carried the raw values `.env` did.
- Findings were then broken down programmatically by rule ID, file, commit, and date from the
  redacted JSON report — no manual reading of diffs, no value ever left the report file.

---

## 3. `plateng-infrastructure-tools`

7 findings, rule `aws-access-token`, all in `projects/weysure/docs/plans/2026-08-26-phase-0-foundations.md`
at a single historical commit `dcdb527d` (2026-08-27, pre-dating the same day's Task 2 fix
commit `02f4860`). This matches Task 2's own progress notes: the 7 access-key-ID literals are
the public half of the `s_user` IAM keypair (not the secret access key), inserted as a canary
during that task's work and immediately replaced with a runtime lookup once the config gap that
allowed it was found. The `s_user` key is already scheduled for deletion under Task 7 (replacing
static AWS keys with IAM Identity Center SSO). A working-tree scan (HEAD only, no history) was
already confirmed clean by Task 2's controller; this scan confirms the *history* still carries
the pre-fix version, which is expected and not actionable — you cannot un-write a git commit
without rewriting history, and rewriting this repository's history has never been proposed or
required.

**Outstanding:** none. Delete the `s_user` access key on schedule (Task 7); no rotation needed
for a value that was never a live secret.

## 4. `plateng-gitops`

0 findings. 2 commits total, both scanned. Confirms the repository is clean, as expected for a
GitOps repo scaffolded from scratch under Task 5 with a secrets-detection pre-commit hook
already in place.

## 5. `Weysure-API` — 76 findings

| Rule | Count |
|---|---:|
| `generic-api-key` | 40 |
| `curl-auth-header` | 23 |
| `jwt` | 10 |
| `stripe-access-token` | 2 |
| `private-key` | 1 |

Matches the previous scan's counts exactly (40/23/10/2/1). No discrepancy requiring
investigation.

**`stripe-access-token` is a mislabel — these are Paystack keys.** Paystack secret keys use the
same `sk_test_`/`sk_live_` prefix convention as Stripe, and gitleaks' `stripe-access-token` rule
matches on prefix, not issuer. Both findings are in `.env`, at commits `c2ee677` (2025-08-02) and
`79b054a` (2026-02-13). These are Paystack secret keys — the one credential in this repository
capable of moving money — already rotated first, per the rotation runbook's stated order of
operations.

**Affected files:**

| File | Findings | Nature |
|---|---:|---|
| `logs/waysure_api.log` | 17 | Request-logged tokens, rule `generic-api-key` (see note below) |
| `DEVELOPER_API_GUIDE.md` | 12 | Documentation placeholders (`pk_test_your_key`, `{your_jwt_token}`) |
| `TESTING_GUIDE.md` | 10 | Documentation placeholders |
| `.env` | 7 | **Real, historical.** Finding ⑯. |
| `QUICK_START_GUIDE.md` | 6 | Documentation placeholders |
| `CORRECT_ESCROW_FLOW_IMPLEMENTATION.md` | 5 | Documentation placeholders |
| `app/schemas/admin.py` | 5 | Pydantic `Field(example=...)` values |
| `.env.example` | 4 | Template placeholders |
| `.github/workflows/ci.yml` | 2 | Finding ⑰ — hardcoded test-project Supabase creds, commit `da07574` |
| `tests/conftest.py` | 2 | Finding ⑰ — same, as `os.environ.setdefault` defaults |
| `PUBLIC_API_IMPLEMENTATION.md` | 2 | Documentation placeholders |
| `.github/workflows/DEPLOYMENT.md` | 1 | Triaged, not an exposure — see §7 |
| `tests/ws_test.py`, `tests/test_end_to_end.py`, `app/schemas/dispute.py` | 1 each | Test/schema fixtures |

**Date range of exposure (whole-repo, all findings):** 2025-05-31 to 2026-04-02.
**Date range of the `.env` exposure specifically (Finding ⑯):** 2025-07-07 (`52f89f2`, first
added) to 2026-03-25 (`6b2e901`, removed from `HEAD`) — **9 commits**, every intermediate
version still fully readable in history:

```
52f89f2  2025-07-07  feat: Auth flow enhanced                              (first added)
a5d6f2e  2025-07-09  feat: Logic up to Escrow creation
12c4e2a  2025-07-12  feat: Dispute and email service implemented
c2ee677  2025-08-02  feat: Add profile image upload …                     (Paystack key present)
ba19687  2025-12-16  feat: Refactor DEVELOPER_API_GUIDE.md …
955257b  2026-01-03  feat: Add admin payout accounts endpoint …
79b054a  2026-02-13  feat: add rate limiting, environment-specific keys … (Paystack key present)
ac3bf73  2026-03-25  feat(admin): add environment-based filtering …
6b2e901  2026-03-25  chore: remove .env file for security reasons          (removed from HEAD)
```

**Correction to note:** the working assumption going into this scan (per the Task 6 brief) was
that the 17 `logs/waysure_api.log` findings were rule `jwt`. Gitleaks actually classifies all 17
as `generic-api-key`. This does not change the disposition — they are still request-logged
tokens from a narrow window on 2025-05-31 (commits `3f7cdb57`, `638433a9`), the earliest activity
in the repository's history, and long expired regardless of rule label — but the rule ID is
corrected here for accuracy.

**Credentials rotated in response (per Adebayo, provider consoles, already complete):**

| Credential | Source | Status |
|---|---|---|
| `PAYSTACK_SECRET_KEY` (mislabeled `stripe-access-token`) | `.env` | Rotated — first, per runbook order (moves money) |
| `SUPABASE_SERVICE_ROLE_KEY` | `.env` | Rotated |
| `SUPABASE_JWT_SECRET` | `.env` | Rotated |
| `SUPABASE_WEBHOOK_SECRET` | `.env` | Rotated |
| `SUPABASE_ANON_KEY` | `.env` | Rotated (rotates with the JWT secret) |
| `DATABASE_URL` password | `.env` | Rotated |
| `SMTP_PASSWORD` | `.env` | Rotated |
| `SECRET_KEY` | `.env` | Rotated — last, per runbook order (invalidates all sessions) |
| Supabase test-project keys (Finding ⑰) | `ci.yml`, `conftest.py` | Rotated |

**Outstanding:** no live credential remains unrotated. The residual item is purely
*informational* — these values remain permanently readable in git history at the commits above
unless that history is rewritten (§8). See §9 for one process gap unrelated to secret exposure
itself.

## 6. `Weysure` — 44 findings

| Rule | Count |
|---|---:|
| `curl-auth-header` | 27 |
| `generic-api-key` | 15 |
| `jwt` | 2 |

Matches the previous scan's counts exactly (27/15/2). No discrepancy requiring investigation.

**Affected files** — all developer-facing documentation or developer-portal UI, plus one test
fixture:

| File | Findings | Nature |
|---|---:|---|
| `DEVELOPER_API_GUIDE.md` | 11 | Root-level doc, placeholder keys |
| `public/DEVELOPER_API_GUIDE.md` | 11 | Same guide, published copy |
| `components/developer/quick-start-guide.tsx` | 6 | Developer-portal UI, example strings |
| `components/developer/api-documentation.tsx` | 3 | Developer-portal UI |
| `components/developer/developer-dashboard.tsx` | 3 | Developer-portal UI |
| `components/developer/api-keys-management.tsx` | 3 | Developer-portal UI |
| `components/developer/developer-dispute-management.tsx` | 3 | Developer-portal UI |
| `docker-compose.test.yml` | 2 | Test-only compose file (rule `jwt`) — see below |
| `components/developer/webhooks-management.tsx` | 2 | Developer-portal UI |

**Date range:** 2025-06-28 to 2026-04-01.

**Independent spot-check performed:** pulled the referenced lines from `DEVELOPER_API_GUIDE.md`
at commit `ba19687` and confirmed the pattern is literal placeholder text
(`X-API-Key: pk_test_your_key`, `Authorization: Bearer {your_jwt_token}`), and pulled
`docker-compose.test.yml` at commit `0c4c4a7` and confirmed `SUPABASE_URL=https://test.supabase.co`
with `PAYSTACK_SECRET_KEY=sk_test_fake` alongside the two `jwt`-rule matches — a test-only
fixture pointed at the same non-production Supabase project as Finding ⑰, not a real credential.

**Credentials rotated in response:** none required. Every finding in this repository is either a
documentation placeholder or a test fixture using a fake/test-project value; none is a real
production credential.

**Outstanding:** none.

## 7. Confirmed NOT exposures (re-verified, not re-litigated)

- **`.github/workflows/DEPLOYMENT.md:207`** (`private-key`, `Weysure-API`, commit `0cd8567e`).
  Re-pulled the file at that commit: the line is a truncated documentation example —
  `VPS_SSH_KEY = -----BEGIN [REDACTED]-----` followed by `[REDACTED]...` and the closing
  `-----END OPENSSH PRIVATE KEY-----` marker, inside a rendered directory-tree diagram of GitHub
  Actions secrets. There is no key material, real or fake, in the file. Confirmed, not an
  exposure.
- **The 44 `Weysure` findings** — confirmed above: developer-facing documentation and
  developer-portal UI components, all placeholder values.
- **`logs/waysure_api.log`** (`Weysure-API`, 17 findings) — request-logged tokens from a single
  short window on 2025-05-31, the earliest activity in the repository's history, long expired.
  Rule label corrected from the brief's assumption of `jwt` to the actual `generic-api-key` (§5).

## 8. History-rewrite recommendation

**Recommendation: do not rewrite `Weysure-API` history at this time.** Document the exposure
(this file) and move on. Revisit only if one of the trigger conditions below becomes true.

**Weighing it:**

| For rewriting (`git filter-repo --path .env --invert-paths`) | Against rewriting |
|---|---|
| Removes the `.env` blobs from every future clone going forward | Every credential in those blobs is already rotated — rewriting purges *disclosed* data, it does not reduce live risk. The exposure already happened; rewriting cannot un-happen it. |
| Reduces the chance of an *accidental* future disclosure (e.g. someone greps an old clone) | Rewriting invalidates every existing clone (all local checkouts must be re-fetched or re-cloned) and every open PR (SHAs change under it) |
| Satisfies a "no secrets in history, period" hygiene bar some compliance regimes expect | GitHub retains unreferenced objects for a retention window regardless — a force-push does not guarantee the old blobs are gone from GitHub's infrastructure immediately, so the operation buys less certainty than it appears to |
| — | Both repositories are **private**, single-collaborator. The realistic threat model (a third party browsing history) does not currently exist. |
| — | `Weysure-API` has 34 commits of real, referenced development history. `git filter-repo` rewrites every commit after the earliest touched one — the entire history's SHAs change, not just the `.env` commits — which is a much bigger blast radius than the specific risk being addressed. |
| — | Rewriting is irreversible via this session's guardrails and out of scope for this task regardless (this task is read-only investigation plus one documentation commit). |

**Conditions under which the opposite answer would be right:**

1. **The repository stops being private** — going open-source, adding external contributors, or
   being acquired/audited by a party who will inspect history. At that point the exposure moves
   from "theoretical, single-owner" to "readable by people you don't control," and rewriting
   becomes containment, not hygiene.
2. **A compliance or customer-security-review requirement explicitly demands it** (e.g. a SOC 2
   auditor or an enterprise customer's security questionnaire asks for a clean history, not just
   rotated credentials). Some frameworks treat "was ever committed" as a finding regardless of
   rotation status.
3. **A credential surfaces that was *not* rotated** — this scan and Task 3's rotation pass found
   none, but if one turned up, rewriting would still be secondary to rotating it, per the
   runbook's own stated priority order.
4. **The repository is about to be handed to a new owner or forked** as a template, where a
   clean starting history matters more than preserving this project's specific development
   record.

None of these currently apply. If Adebayo wants it done anyway as pure hygiene, the command is
already documented in `docs/plans/2026-08-26-phase-0-foundations.md` under Task 3's "History
rewriting" section — but it should be scheduled for a moment with no open PRs, and every clone
(including any CI checkout caches) re-established afterward.

## 9. Residual gaps unrelated to secret exposure

Two items from the plan's Task 3 do not appear to have been completed, independent of the
rotation itself (which is confirmed done):

- `projects/weysure/docs/runbooks/SECRET_ROTATION.md` — the directory exists but is empty; the
  rotation runbook the plan specified for Task 3 Step 2 was not found on disk.
- Findings ⑮ and ⑯ do not appear in the findings table in
  `projects/weysure/docs/specs/2026-08-26-weysure-platform-design.md` (Task 3 Step 5).

Flagging for visibility; out of scope to fix as part of this task, which is a read-only scan plus
this one document.

---

## Appendix — raw scan commands (reproducible, no values printed)

```bash
for repo in plateng-infrastructure-tools plateng-gitops Weysure-API Weysure; do
  gitleaks detect --source "<path-to-$repo>" \
    --log-opts="--all" \
    --report-format json \
    --report-path "<out>/$repo.json" \
    --redact --no-banner --exit-code 0
done
```

Results: `plateng-infrastructure-tools` 7, `plateng-gitops` 0, `Weysure-API` 76, `Weysure` 44 —
totalling 127 findings across all four repositories, of which exactly one class (Finding ⑯'s
`.env` contents plus Finding ⑰'s test-project literals) was ever a real credential, and all of
those are rotated.
