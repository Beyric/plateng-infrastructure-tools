# Security toolchain — install conventions

Records how the Phase 0 security toolchain (`gitleaks`, `pre-commit`, `tflint`) is installed
on a dev machine, and one deliberate deviation from the obvious path so nobody re-discovers
it the hard way.

## Currently installed versions

Captured on the machine that shipped Task 2 (2026-08-27):

| Tool | Version | Install method |
|---|---|---|
| `gitleaks` | `8.30.1` | `brew install gitleaks` |
| `pre-commit` | `4.6.2` | `brew install pre-commit` |
| `tflint` | `0.64.0` (+ `ruleset.terraform` `0.15.0-bundled`) | checksum-verified GitHub release binary — **not** Homebrew, see below |

Re-check with:

```bash
gitleaks version && pre-commit --version && tflint --version
```

## `gitleaks` and `pre-commit`

Standard Homebrew formulae, install normally:

```bash
brew install gitleaks pre-commit
```

## `tflint` — do NOT try `brew install tflint`

**`tflint` has been removed from `homebrew-core`, and its own tap
(`terraform-linters/homebrew-tflint`) no longer exists either** (confirmed 404 on GitHub as
of 2026-08-27). `brew install tflint` fails with "No available formula", and
`brew tap terraform-linters/tflint` fails trying to clone a tap repo that's gone. This is an
upstream change, not a local misconfiguration — the `tflint` project itself is alive and
actively maintained, it just isn't distributed via Homebrew any more.

**Install instead from a checksum-verified GitHub release binary.** Do not pipe an install
script through `bash` — download the release archive and the project's own published
`checksums.txt`, and verify the hash matches before extracting anything.

```bash
# 1. Find the latest release tag and the right asset for your platform
curl -s https://api.github.com/repos/terraform-linters/tflint/releases/latest \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('tag:', d['tag_name'])
for a in d['assets']:
    if 'darwin' in a['name'].lower() or 'checksum' in a['name'].lower():
        print(a['name'], a['browser_download_url'])
"

# 2. Download the binary for your architecture (arm64 shown) and the checksums file
curl -sL -o tflint_darwin_arm64.zip \
  https://github.com/terraform-linters/tflint/releases/download/<tag>/tflint_darwin_arm64.zip
curl -sL -o checksums.txt \
  https://github.com/terraform-linters/tflint/releases/download/<tag>/checksums.txt

# 3. Verify the SHA-256 before touching the archive
grep darwin_arm64 checksums.txt
shasum -a 256 tflint_darwin_arm64.zip
# the two hashes must match exactly — do not proceed if they don't

# 4. Extract and install onto PATH (same directory Homebrew already uses)
unzip -o tflint_darwin_arm64.zip -d tflint_extract
chmod +x tflint_extract/tflint
mv tflint_extract/tflint /opt/homebrew/bin/tflint
xattr -d com.apple.quarantine /opt/homebrew/bin/tflint 2>/dev/null

# 5. Clean up and verify
rm -rf tflint_darwin_arm64.zip checksums.txt tflint_extract
tflint --version
```

For `amd64` Macs, substitute `tflint_darwin_amd64.zip` in steps 2-3.

After installing, initialise the AWS ruleset plugin used by `.tflint.hcl`:

```bash
tflint --init
```

## Operational notes

- **Risk of this approach:** a checksum match only proves the archive wasn't corrupted or
  tampered with *in transit from GitHub* — it does not independently verify the release was
  built from clean source. This is the same trust model as `brew install` (which also just
  fetches and verifies a bottle) minus Homebrew's additional audit trail. Acceptable for a
  local dev tool; would warrant more (e.g. `go install` from pinned source, or a signed
  provenance check) for anything running in CI or against production credentials.
- **Rollback:** `rm /opt/homebrew/bin/tflint` removes it cleanly — no package manager state
  to clean up since it wasn't installed via `brew`.
- **Re-check this doc** the next time `tflint` is installed somewhere new. If Homebrew
  restores the formula or tap, prefer `brew install tflint` again and delete this workaround
  section — Homebrew's tap update/audit trail is preferable to a manual release download when
  available.
