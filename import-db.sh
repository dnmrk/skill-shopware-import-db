#!/usr/bin/env bash
#
# shopware-import-db — import an external SQL dump into the local Shopware MySQL
# container, then make the shop usable locally.
#
# Flow:
#   1. Validate the dump file (.sql, .sql.gz, .gz).
#   2. Inspect the target DB: missing -> create; empty -> proceed;
#      populated -> refuse unless --force.
#   3. With --force on a populated DB: mysqldump backup -> var/db-backups/ first.
#   4. Import the dump.
#   5. Rewrite sales_channel_domain.url hosts (keep path): shortest host ->
#      http://localhost:8000, each other host -> http://localhost:8000/<first-label>.
#   6. Run vendor/bin/shopware-deployment-helper run (migrations/theme/cache).
#
# --localize-only skips 1-4 for a dump that is already imported: steps 5-6 only.
#
# Usage:
#   import-db.sh <dump-file> [db-name] [--force] [--no-finalize]
#   import-db.sh --localize-only [db-name] [--no-finalize]
#
# Defaults: db-name=shopware. Exits 2 when --force is required (agent should
# ask the user, then re-run with --force).

set -euo pipefail

DB_SERVICE="database"
WEB_SERVICE="web"
LOCAL_URL="http://localhost:8000"
MYSQL_ROOT_PW="root"

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# ---- parse args ------------------------------------------------------------
POS1=""
POS2=""
NPOS=0
FORCE=0
FINALIZE=1
LOCALIZE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force)         FORCE=1 ;;
    --no-finalize)   FINALIZE=0 ;;
    --localize-only) LOCALIZE_ONLY=1 ;;
    -*)              die "unknown flag: $arg" ;;
    *)
      NPOS=$((NPOS + 1))
      if [[ "$NPOS" -eq 1 ]]; then POS1="$arg"
      elif [[ "$NPOS" -eq 2 ]]; then POS2="$arg"
      else die "too many arguments: $arg"; fi
      ;;
  esac
done

if [[ "$LOCALIZE_ONLY" -eq 1 ]]; then
  [[ "$NPOS" -le 1 ]] || die "--localize-only takes no dump file. Usage: import-db.sh --localize-only [db-name]"
  [[ "$FORCE" -eq 0 ]] || die "--force has nothing to do with --localize-only (no data is dropped)."
  FILE=""
  DB="${POS1:-shopware}"
else
  FILE="$POS1"
  DB="${POS2:-shopware}"
  [[ -n "$FILE" ]] || die "no dump file given. Usage: import-db.sh <dump-file> [db-name] [--force]"
  [[ -f "$FILE" ]] || die "dump file not found: $FILE"
  case "$FILE" in
    *.sql|*.sql.gz|*.gz) ;;
    *) die "unsupported file type: $FILE (expected .sql, .sql.gz or .gz)" ;;
  esac
fi

# ---- locate project root (dir containing the compose file) -----------------
COMPOSE_FILE=""
dir="$PWD"
while [[ "$dir" != "/" ]]; do
  for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    if [[ -f "$dir/$f" ]]; then COMPOSE_FILE="$dir/$f"; PROJECT_ROOT="$dir"; break 2; fi
  done
  dir="$(dirname "$dir")"
done
[[ -n "$COMPOSE_FILE" ]] || die "no compose file found from $PWD upward — run inside the project."
cd "$PROJECT_ROOT"
info "project root: $PROJECT_ROOT"

# mysql/mysqldump runners (MYSQL_PWD avoids the insecure-password warning)
DC=(docker compose)
mysql_q()   { "${DC[@]}" exec -T -e MYSQL_PWD="$MYSQL_ROOT_PW" "$DB_SERVICE" mysql -uroot -N -B "$@"; }
mysql_db()  { "${DC[@]}" exec -T -e MYSQL_PWD="$MYSQL_ROOT_PW" "$DB_SERVICE" mysql -uroot "$DB" "$@"; }

# ---- ensure the DB container is up ----------------------------------------
"${DC[@]}" ps --status running --services 2>/dev/null | grep -qx "$DB_SERVICE" \
  || die "'$DB_SERVICE' service is not running — start it with 'make up' first."

# ---- inspect target DB -----------------------------------------------------
EXISTS="$(mysql_q -e "SHOW DATABASES LIKE '$DB';" | head -n1 || true)"
TABLES=0
if [[ -n "$EXISTS" ]]; then
  TABLES="$(mysql_q -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB';" | head -n1)"
fi
info "database '$DB': exists=$([[ -n "$EXISTS" ]] && echo yes || echo no), tables=$TABLES"

if [[ "$LOCALIZE_ONLY" -eq 1 ]]; then
  [[ -n "$EXISTS" && "$TABLES" -gt 0 ]] || die "database '$DB' is missing or empty — nothing to localize. Import a dump first."
  info "--localize-only: skipping backup and import"
else
  if [[ -n "$EXISTS" && "$TABLES" -gt 0 && "$FORCE" -ne 1 ]]; then
    printf '\n'
    printf "NEEDS_CONFIRMATION: database '%s' already has %s tables.\n" "$DB" "$TABLES" >&2
    printf "Re-run with --force to back it up and drop+recreate before import.\n" >&2
    exit 2
  fi

  # ---- backup + drop/recreate (only when wiping a populated DB) ------------
  if [[ -n "$EXISTS" && "$TABLES" -gt 0 ]]; then
    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$PROJECT_ROOT/var/db-backups"
    BACKUP="$BACKUP_DIR/${DB}-${TS}.sql.gz"
    mkdir -p "$BACKUP_DIR"
    info "backing up '$DB' -> $BACKUP"
    "${DC[@]}" exec -T -e MYSQL_PWD="$MYSQL_ROOT_PW" "$DB_SERVICE" \
      mysqldump -uroot --single-transaction --quick --no-tablespaces "$DB" \
      | gzip > "$BACKUP"
    [[ -s "$BACKUP" ]] || die "backup is empty — aborting before any destructive step."
    info "backup size: $(du -h "$BACKUP" | cut -f1)"
  fi

  if [[ -n "$EXISTS" ]]; then
    info "dropping and recreating '$DB'"
    mysql_q -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  else
    info "creating database '$DB'"
    mysql_q -e "CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  fi

  # ---- import --------------------------------------------------------------
  info "importing $FILE into '$DB' (this can take a while)..."
  case "$FILE" in
    *.gz) gunzip -c "$FILE" | mysql_db ;;
    *)    mysql_db < "$FILE" ;;
  esac
  NEW_TABLES="$(mysql_q -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB';" | head -n1)"
  [[ "$NEW_TABLES" -gt 0 ]] || die "import produced 0 tables — something went wrong."
  info "import complete: $NEW_TABLES tables"
fi

# ---- rewrite sales channel domains ----------------------------------------
if [[ "$(mysql_q -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB' AND table_name='sales_channel_domain';" | head -n1)" -gt 0 ]]; then
  # One local base per source host: url is UNIQUE, so two bare-host channels can't both become $LOCAL_URL.
  # Shortest host (usually the apex) -> $LOCAL_URL; every other host -> $LOCAL_URL/<its first label>.
  HOSTS="$(mysql_q -e "SELECT DISTINCT REGEXP_SUBSTR(url, '^https?://[^/]+') h FROM \`$DB\`.sales_channel_domain ORDER BY CHAR_LENGTH(h), h;")"
  SQL="START TRANSACTION;"
  USED=" "
  FIRST=1
  while read -r origin; do
    [[ -n "$origin" ]] || continue
    # Hosts come from the dump and are spliced into SQL below — refuse anything that isn't a plain host[:port].
    [[ "$origin" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || die "unexpected host in sales_channel_domain: $origin — no domains were changed; fix it by hand."
    if [[ "$FIRST" -eq 1 ]]; then
      target="$LOCAL_URL"; FIRST=0
    else
      label="${origin#*://}"; label="${label%%.*}"; label="${label%%:*}"
      slug="$label"; n=2
      while [[ "$USED" == *" $slug "* ]]; do slug="$label-$n"; n=$((n + 1)); done
      USED+="$slug "
      target="$LOCAL_URL/$slug"
    fi
    info "rewriting $origin -> $target"
    SQL+="UPDATE sales_channel_domain SET url = CONCAT('$target', SUBSTRING(url, CHAR_LENGTH('$origin') + 1)) WHERE REGEXP_SUBSTR(url, '^https?://[^/]+') = '$origin';"
  done <<< "$HOSTS"
  SQL+="COMMIT;"
  # A unique-index clash aborts the mysql client before COMMIT, so the rewrite is all-or-nothing.
  mysql_db -e "$SQL" || die "domain rewrite failed (likely a url clash) — no domains were changed; fix sales_channel_domain by hand."
  info "domains now:"
  mysql_q -e "SELECT url FROM \`$DB\`.sales_channel_domain;" | sed 's/^/    /'
else
  info "no sales_channel_domain table — skipping URL rewrite"
fi

# ---- finalize --------------------------------------------------------------
if [[ "$FINALIZE" -eq 1 ]]; then
  info "running shopware-deployment-helper..."
  "${DC[@]}" exec -T "$WEB_SERVICE" vendor/bin/shopware-deployment-helper run
else
  info "skipping finalize (--no-finalize) — remember to run migrations/theme yourself"
fi

info "DONE. '$DB' localized for $LOCAL_URL"
