---
name: shopware-import-db
description: Use when importing an external SQL dump into the local Shopware MySQL container — e.g. loading a prod/staging/colleague database dump (.sql, .sql.gz, .gz) into the local Docker Shopware database — or when a dump was already imported by hand and the local shop 400s on domain mapping. Backs up any existing data, imports, rewrites sales-channel domains to localhost:8000, and runs the deployment helper.
---

# Shopware: import an external SQL dump locally

A single helper script does the whole flow. Run it; do not improvise mysql/docker commands.

Install (the folder name must match the paths below):
```bash
git clone https://github.com/dnmrk/skill-shopware-import-db.git ~/.claude/skills/shopware-import-db
```

## Steps

1. Get the dump file path from the user (accepts `.sql`, `.sql.gz`, `.gz`). DB name defaults to `shopware` — only pass a different name if the user says so.

2. Run the script from anywhere inside the project:
   ```bash
   bash ~/.claude/skills/shopware-import-db/import-db.sh <dump-file> [db-name]
   ```

3. **If it exits with code 2 (`NEEDS_CONFIRMATION`)** — the target DB already has data. Tell the user how many tables it has and ask whether to drop + recreate. A timestamped backup is taken automatically before anything is dropped. On confirmation, re-run with `--force`:
   ```bash
   bash ~/.claude/skills/shopware-import-db/import-db.sh <dump-file> [db-name] --force
   ```
   If the DB is missing or empty, the script proceeds without asking.

4. Report the script's summary (table count, rewritten domains, backup path). Do not re-run verification commands by hand.

**Dump already imported** (the user loaded it themselves, e.g. a QA/staging dump, and only the domains and finalize are missing; symptom: storefront 400 "Domain Mapping Misconfiguration"): run only the post-import steps. No dump file is needed and nothing is dropped. It refuses to run against a missing or empty DB:
```bash
bash ~/.claude/skills/shopware-import-db/import-db.sh --localize-only [db-name] [--no-finalize]
```

## What the script does

- Locates the compose file by walking up from the current dir (DB service `database`, web service `web`).
- Refuses to wipe a populated DB without `--force`.
- With `--force` on a populated DB: `mysqldump` → `var/db-backups/<db>-<timestamp>.sql.gz`, verifies it is non-empty, then drops + recreates (utf8mb4).
- Imports (streams `gunzip` for compressed dumps), then asserts tables > 0.
- Rewrites `sales_channel_domain.url` per distinct source host, keeping each path, in one transaction. The shortest host (usually the apex) becomes `http://localhost:8000`. Every other host becomes `http://localhost:8000/<first-label>`, e.g. `https://directory.shop.example` → `http://localhost:8000/directory`, with `-2`, `-3` suffixes if labels repeat. `url` is UNIQUE, so mapping every host to the bare `localhost:8000` would collide when two channels sit on different bare hosts. If a rewrite would still clash, nothing is changed and the script stops so you can fix the domains by hand.
- Runs `vendor/bin/shopware-deployment-helper run` (migrations/theme/cache). Pass `--no-finalize` to skip.

## Notes

- Every destructive step is gated on the previous one succeeding (`set -euo pipefail`); a missing file, empty backup, or zero-table import aborts cleanly.
- The DB container must be running (`make up`) — the script checks and errors clearly if not.
