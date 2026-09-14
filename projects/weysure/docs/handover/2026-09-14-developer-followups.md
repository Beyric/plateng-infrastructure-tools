# Developer follow-ups from the first Kubernetes deployment (Weysure-API)

Found while deploying to production on 2026-09-13/14. Ordered by importance. None blocks the
platform; the first blocks real users.

| # | Priority | What | Evidence | Suggested fix |
|---|---|---|---|---|
| 1 | **High** | KYC documents are written to local disk (`app/api/v1/endpoints/kyc.py:23-46`, `uploads/kyc`) | in Kubernetes the directory is a per-pod emptyDir: uploads vanish on restart (daily, with credential rotation) and are invisible to the other replica | store in private object storage (S3 + presigned URLs, or the existing Cloudinary integration). Platform will provide the bucket + pod-identity role on request |
| 2 | Medium | loguru file sink (`app/core/logger.py:47-55`, `/app/logs`) | needed a writable mount; files are never read by anything in the cluster | log to stdout only (12-factor); the platform collects stdout |
| 3 | Medium | Alembic chain has three roots (`auto_add_message_tables`, `auto_add_notification_table`, baseline) | works only because Alembic merges heads; one more parallel head breaks `upgrade head` | `alembic merge heads`, then a CI check `alembic heads` returns exactly one |
| 4 | Medium | Models and migrations drift (9 differences reported by autogenerate against the baseline) | future autogenerate output will include unrelated changes | one clean-up revision |
| 5 | Low | `Settings()` requires `SERVER_HOST`, `EMAILS_FROM_EMAIL` as valid URL/email even for `alembic` | migration Job must carry them | give them safe defaults or validate lazily |
| 6 | Low | `uploads/` and `logs/` directories created at import time | import side effects make the module unloadable on a read-only fs | create lazily on first use |
| 7 | Low | Dev venv hygiene: `black` was not installed in the Poetry venv; `poetry run black` silently used a Homebrew 26.x | 22 files "would be reformatted" locally while CI (23.12.1) is clean | `poetry install --with dev`; consider `pre-commit` with pinned black |

Migrations rule going forward: **expand/contract** — the previous image runs against the new schema
for about a minute during every rollout; never drop or rename a column in the same release that
stops using it.
