#!/bin/sh

log() { printf '%s\n' "$*"; }
error() { log "ERROR: $*" >&2; }
fatal() { error "$*"; exit 1; }

try() { "$@" || fatal "Command failed: $*"; }
try_v() { log "Running command: $*"; try "$@"; }


PROD_DIR=/home/public/david.mandelberg.org/beta
PROD_DB_NAME=wordpress
STAGING_BLOGNAME="Staging Site"
STAGING_BLOGDESCRIPTION="WARNING: Staging site. All changes will be lost."
STAGING_DIR=/home/public/staging.david.mandelberg.org
STAGING_URLBASE=https://staging.david.mandelberg.org
STAGING_DB_NAME=wordpress_staging
STAGING_DB_HOST=davidmandelberg.db
STAGING_DB_USER=wordpress_staging
STAGING_DB_USERHOST=%
STAGING_DB_PASS="$(try hexdump -n 32 -e '1/1 "%02x"' /dev/urandom)" || exit 1
STAGING_DB_CHARSET=utf8mb4
STAGING_DB_COLLATE=utf8mb4_general_ci

# rsync filter rules for which upload files will be copied to staging.
# The current year is included so there's some data to test with.
# Specific dates are included, e.g., for banner images and site icons.
# Other dated uploads are excluded to save space.
UPLOAD_FILTER="
+ /$(try date +%Y)/***
+ /2017/
+ /2017/08/***
- /[0-9][0-9][0-9][0-9]/***
" || exit 1


test -f "${STAGING_DIR}/.staging" || {
  error "The configured staging directory does not exist, or is not"
  error "marked as a staging directory."
  error
  error "If it exists, and you are sure that you want (almost)"
  error "everything in it to be deleted, run the following command:"
  error
  error "  touch \"${STAGING_DIR}/.staging\""
  exit 1
}


# First, make sure the staging site is inaccessible until it's ready
# for use again. This also ensures that `wp config create` below won't
# fail due to an existing config file.
log "Deleting old staging configuration."
try rm -f "${STAGING_DIR}/wp-config.php"


log "Configuring staging database and user."
try mysql <<EOF
drop database if exists $STAGING_DB_NAME;
create database $STAGING_DB_NAME
  character set '$STAGING_DB_CHARSET'
  collate '$STAGING_DB_COLLATE'
  ;
drop user if exists '$STAGING_DB_USER'@'$STAGING_DB_USERHOST';
create user '$STAGING_DB_USER'@'$STAGING_DB_USERHOST'
  identified by '$STAGING_DB_PASS'
  ;
grant all privileges on $STAGING_DB_NAME.*
  to '$STAGING_DB_USER'@'$STAGING_DB_USERHOST';
EOF


log "Copying database."
try mysqldump --single-transaction "$PROD_DB_NAME" |
  try mysql "$STAGING_DB_NAME" ||
  exit 1


log "Copying files, excluding uploads."
try_v rsync \
  -va --del \
  --exclude "/.htaccess" \
  --exclude "/.staging" \
  --exclude "/wp-config.php" \
  --exclude "/wp-content/uploads/**" \
  "${PROD_DIR}/" "${STAGING_DIR}/"

log "Copying uploads."
try_v rsync \
  -va --del --delete-excluded \
  --filter "merge /dev/stdin" \
  "${PROD_DIR}/wp-content/uploads/" "${STAGING_DIR}/wp-content/uploads/" <<EOF
$UPLOAD_FILTER
EOF


log "Configuring staging wordpress."
try_v wp --path="$STAGING_DIR" config create \
  --dbname="$STAGING_DB_NAME" \
  --dbuser="$STAGING_DB_USER" \
  --dbhost="$STAGING_DB_HOST" \
  --dbcharset="$STAGING_DB_CHARSET" \
  --dbcollate="$STAGING_DB_COLLATE" \
  --prompt=dbpass <<EOF
$STAGING_DB_PASS
EOF
try_v wp --path="$STAGING_DIR" option update blog_public 0
try_v wp --path="$STAGING_DIR" option update blogdescription \
  "$STAGING_BLOGDESCRIPTION"
try_v wp --path="$STAGING_DIR" option update blogname "$STAGING_BLOGNAME"
try_v wp --path="$STAGING_DIR" option update home "$STAGING_URLBASE"
try_v wp --path="$STAGING_DIR" option update siteurl "$STAGING_URLBASE"


log "Difference between .htaccess files:"
diff -u "${PROD_DIR}/.htaccess" "${STAGING_DIR}/.htaccess" ||
  test $? -eq 1 || fatal "diff failed"
