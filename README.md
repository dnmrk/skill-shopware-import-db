# shopware-import-db

A [Claude Code](https://claude.com/claude-code) skill (and standalone script) that imports an external SQL dump into a local Docker Shopware 6 database and makes the shop usable locally.

It backs up any existing data, imports the dump, rewrites `sales_channel_domain` URLs to your local host, and runs `shopware-deployment-helper`.

## Install

```bash
git clone https://github.com/dnmrk/skill-shopware-import-db.git ~/.claude/skills/shopware-import-db
```

The folder name must be `shopware-import-db`. `SKILL.md` calls the script by that path.

## Usage

**With Claude Code**, from inside your Shopware project, ask something like *"import ~/Downloads/prod.sql.gz"*. The skill also handles *"I imported the dump by hand and the shop 400s on domain mapping"*.

**Standalone**, from anywhere inside the project:

```bash
# Import a dump (.sql, .sql.gz, .gz) into the `shopware` DB
bash ~/.claude/skills/shopware-import-db/import-db.sh dump.sql.gz

# Target DB already has data: back it up, drop, recreate, import
bash ~/.claude/skills/shopware-import-db/import-db.sh dump.sql.gz shopware --force

# Dump already imported by hand: only rewrite domains + finalize
bash ~/.claude/skills/shopware-import-db/import-db.sh --localize-only

# Project runs on its own local host instead of localhost:8000
bash ~/.claude/skills/shopware-import-db/import-db.sh dump.sql.gz --base-url=https://shop.local
```

| Argument | Meaning |
|---|---|
| `<dump-file>` | `.sql`, `.sql.gz` or `.gz`. Not allowed with `--localize-only`. |
| `[db-name]` | Target database. Default `shopware`. |
| `--force` | Allow wiping a populated DB (backed up first). |
| `--localize-only` | Skip import; only rewrite domains and finalize. Refuses a missing or empty DB. |
| `--base-url=URL` | Local base URL, `scheme://host[:port]`, no path. Default `http://localhost:8000`. |
| `--no-finalize` | Skip `shopware-deployment-helper run`. |

Exit codes: `0` success, `1` error, `2` the target DB has data and `--force` is needed.

## What it does

1. Finds the compose file by walking up from the current directory and checks the `database` service is running.
2. If the target DB is populated, refuses without `--force`. With `--force`, it writes `var/db-backups/<db>-<timestamp>.sql.gz`, aborts if the backup is empty, then drops and recreates the DB (utf8mb4).
3. Imports the dump (gzip is streamed) and asserts at least one table exists.
4. Rewrites `sales_channel_domain.url` per source host, keeping paths, in one transaction:

   | Before | After (default base) |
   |---|---|
   | `https://shop.example` | `http://localhost:8000` |
   | `https://shop.example/en` | `http://localhost:8000/en` |
   | `https://directory.shop.example` | `http://localhost:8000/directory` |
   | `https://directory.shop.example/de` | `http://localhost:8000/directory/de` |

   The shortest host gets the base URL and every other host gets `<base>/<first-label>` (with `-2`, `-3` on repeats), because `url` is unique and two bare hosts can't share the base. If a rewrite would still clash, or a host isn't a plain `host[:port]`, nothing is changed and the script stops. Re-running is safe.
5. Runs `vendor/bin/shopware-deployment-helper run` in the `web` service (migrations, theme, cache).

## Requirements and assumptions

- Docker Compose with a MySQL 8+ or MariaDB 10.0.5+ service named `database` (root password `root`) and a PHP service named `web` with `shopware-deployment-helper` installed. If yours differ, edit `DB_SERVICE`, `WEB_SERVICE` and `MYSQL_ROOT_PW` at the top of `import-db.sh`.
- Bash 3.2+ (works with macOS `/bin/bash`).
- Everything runs locally against your containers. Nothing connects to a remote host.

## License

[MIT](LICENSE)
