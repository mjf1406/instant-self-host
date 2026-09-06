# Backup and restore

This stack copies InstantDB data to a dedicated Cloudflare R2 bucket. Each snapshot includes:

- a PostgreSQL custom-format dump
- the current MinIO upload bucket
- the dashboard app-backups bucket (`S3_APP_BACKUPS_BUCKET`)
- the Instant server config volume

restic encrypts the snapshot before it leaves the server. If you lose `RESTIC_PASSWORD`, the copies on R2 cannot be opened.

The first-time Portainer workflow is in [README section 9](../README.md#9-backups). This page adds staging, command variants, checks from the verified rollout, credential rotation, and live recovery.

## What you need

- A Cloudflare account that can create R2 buckets and API tokens
- Free disk for staging. Default staging is a Docker volume on the root disk. The root disk on this host had about 350 GB free when this was designed. `/media/vault1` is the larger disk if uploads grow.
- The Instant stack already running, or about to run, on the Ubuntu server

## Commands on this host

Portainer runs the stack. Compose files often live inside the Portainer container, so `/data/compose` may not exist on the Ubuntu host. You do not need that folder.

Find the backup container, then use `sudo docker exec`:

```sh
sudo docker ps -a --filter name=backup
```

Use the **NAMES** column in the commands below. This document writes `CONTAINER_NAME`. On a typical Portainer stack it looks like `instantdb-backup-1`.

Use `sudo docker compose --profile ...` only when you have this repo checked out on the host **and** the same environment file Portainer uses. Those commands are marked as Compose checkout.

## 1. Create a dedicated R2 bucket

1. Open [R2](https://dash.cloudflare.com/) in the Cloudflare dashboard.
2. Create a bucket named `instant-self-host-backups`, or another name you will put in `R2_BUCKET`.
3. Do not reuse the public files hostname or the live MinIO bucket.
4. Copy the account ID from the R2 overview page into `R2_ACCOUNT_ID`.

Leave object lifecycle deletion off. restic removes old snapshots itself.

## 2. Create a scoped R2 token

1. Open **R2** → **Overview** → **Manage API tokens**.
2. Create an **Account API token**. Prefer an account token, not a user token.
3. Permission: **Object Read & Write**. Do not choose Admin.
4. Apply it to this backup bucket only.
5. Copy the Access Key ID and Secret Access Key into a password manager. The secret is shown once.

Put those values in Portainer as `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.

## 3. Create the restic password

Generate a long random password, at least 32 characters, and store it in a password manager that is not only on this server. Set it as `RESTIC_PASSWORD`.

Treat this password as the recovery key. A stolen R2 token without this password cannot read the backups. A lost password cannot be reset. Do not reuse the MinIO or Postgres password.

## 4. Add the 7-day bucket lock

Apply Cloudflare bucket locks to restic's durable prefixes. Leave `locks/` unlocked so restic can coordinate jobs.

In the bucket **Settings** → **Bucket lock**, add 7-day **Age** rules for these prefixes:

| Prefix | Lock |
| --- | --- |
| `data/` | 7 days |
| `index/` | 7 days |
| `snapshots/` | 7 days |
| `keys/` | 7 days |
| `config` | 7 days |

`data/`, `index/`, `snapshots/`, and `keys/` need the trailing slash. `config` does not. Do not lock `locks/`. Do not lock the whole bucket with an empty prefix.

If you prefer Wrangler:

```sh
bunx wrangler r2 bucket lock add instant-self-host-backups --prefix data/ --timeout 7d
bunx wrangler r2 bucket lock add instant-self-host-backups --prefix index/ --timeout 7d
bunx wrangler r2 bucket lock add instant-self-host-backups --prefix snapshots/ --timeout 7d
bunx wrangler r2 bucket lock add instant-self-host-backups --prefix keys/ --timeout 7d
bunx wrangler r2 bucket lock add instant-self-host-backups --prefix config --timeout 7d
```

Keep `RESTIC_KEEP_WITHIN` at `7d` or longer. A shorter keep period will try to delete objects the lock still protects, and prune will fail.

## 5. Choose staging space

The backup job writes a local copy under `/staging` before it uploads to R2.

| Choice | When to use |
| --- | --- |
| Leave `BACKUP_STAGING_SOURCE` empty | Default. Uses the `backup_staging` Docker volume on the root disk. |
| Set an absolute path | Use this when the root disk is too small. Example: `/media/vault1/instant-backup-staging` |

Check size before you change it:

```sh
df -h / /media/vault1
sudo du -sh /var/lib/docker/volumes
```

Reserve about as much space as the current MinIO uploads plus one PostgreSQL dump, with a little extra.

## 6. Add the variables in Portainer

Copy the backup block from [`.env.example`](../.env.example). Replace the `replace-with-...` values.

Leave these empty in the persistent Portainer environment:

- `R2_ENDPOINT` unless you set the account-level endpoint `https://<account-id>.r2.cloudflarestorage.com`. Never put a bucket name in this URL.
- `RESTIC_REPOSITORY`
- `RESTIC_REPOSITORY_PREFIX` unless you intentionally want an extra path inside the bucket. Do not set this to the bucket name.
- `RESTIC_INIT_CONFIRM`
- `RESTORE_TARGET_DB`, `RESTORE_TARGET_BUCKET`, and `RESTORE_CONFIRM`
- `INSTANT_PLATFORM_TOKEN` until you create a personal access token for scheduled dashboard backups
- `APP_BACKUP_APP_IDS` unless you want to limit scheduled dashboard backups to specific apps

Redeploy the stack so Portainer builds the `backup` image from `backup/Dockerfile`. Leave **Re-pull image** off. That image is not on Docker Hub, so a pull fails with `pull access denied`. Instant should still return `{"wal":"ok"}`. The backup container stays unhealthy until the repository exists and the first snapshot succeeds.

## 7. Initialize the repository

Check the account ID, endpoint, and bucket one more time. This command creates a restic repository. It will not run unless you confirm.

```sh
sudo docker logs --tail 50 CONTAINER_NAME
```

The URL should look like:

```text
s3:https://<account-id>.r2.cloudflarestorage.com/instant-self-host-backups
```

If that URL is wrong, fix Portainer and redeploy. Do not initialize.

A path is fixed after initialization. Normally it ends with one bucket name. If an already-initialized deployment shows the bucket name twice, `RESTIC_REPOSITORY_PREFIX` or `R2_ENDPOINT` included the bucket. Keep using that same path. Do not change those variables later unless you plan a repository migration.

```sh
sudo docker exec -e RESTIC_INIT_CONFIRM=yes CONTAINER_NAME /usr/local/bin/init-repo.sh
```

Compose checkout alternative:

```sh
docker compose --profile backup-init run --rm -e RESTIC_INIT_CONFIRM=yes backup-init
```

Success looks like `repository initialized`. If it says the repository already exists, do not init again.

| Message | What it means |
| --- | --- |
| `refusing to initialize` | `RESTIC_INIT_CONFIRM` was not `yes` |
| Access denied / 403 | Token is wrong, or it is not allowed on this bucket |
| No such host / 404 | Account ID or bucket name is wrong |
| Missing environment variable | A required Portainer variable is empty |

Initialization through `docker exec` does **not** start a snapshot. A container that started before the repository existed already skipped its startup backup. The scheduler waits for `BACKUP_CRON` (default `0 */6 * * *` UTC: `00:00`, `06:00`, `12:00`, `18:00`).

## 8. Run the first backup and watch health

Run the first snapshot now:

```sh
sudo docker exec CONTAINER_NAME /usr/local/bin/backup.sh
```

Or restart the container so the entrypoint sees the repository:

```sh
sudo docker restart CONTAINER_NAME
sudo docker logs -f CONTAINER_NAME
```

Compose checkout alternatives:

```sh
docker compose logs -f backup
docker compose exec backup /usr/local/bin/backup.sh
```

A successful first run should show:

1. `staging space ok`
2. MinIO mirror of the upload bucket and the app-backups bucket (0 B is fine when either is empty)
3. `wrote /staging/data/postgres/instant.dump`
4. `wrote /staging/data/server-config/config.tar.gz`
5. `snapshot` saved
6. `running restic metadata check` then `no errors were found`
7. `backup completed`
8. Retention applied (`keep-within=7d weekly=5 monthly=12`) and `keep 1 snapshots` on the first run
9. `running weekly restic data sample check (5%)` then `no errors were found`
10. `weekly maintenance completed`

Then:

```sh
sudo docker ps --filter name=CONTAINER_NAME
```

You want `(healthy)`. Failures stay in the container logs. The service becomes unhealthy if no successful snapshot is newer than `BACKUP_FRESHNESS_SECONDS` (8 hours by default).

List snapshots:

```sh
sudo docker exec CONTAINER_NAME /usr/local/bin/restore.sh list
```

Compose checkout:

```sh
docker compose --profile restore run --rm restore list
```

## 8a. Dashboard app backups

The dashboard Backups page stores per-app snapshots in MinIO bucket `S3_APP_BACKUPS_BUCKET` (default `instant-app-backups`). Instant's built-in nightly scheduler is AWS-only. This stack uses `app-backup.sh` instead.

Set `INSTANT_PLATFORM_TOKEN` to a personal access token from the dashboard account menu, or to the refresh token from `instant-cli login` pointed at this instance. The token must belong to a user who can write every app you want scheduled. The superuser is enough.

| Variable | Default | Purpose |
| --- | --- | --- |
| `APP_BACKUP_CRON` | `0 2 * * *` | UTC schedule. One dashboard backup per app, then an immediate restic upload. |
| `APP_BACKUP_APP_IDS` | empty | Comma-separated app IDs. Empty means every non-deleted app. |
| `INSTANT_SERVER_URL` | `http://server:8888` | Backend URL inside the Docker network. |

A 429 rate-limit response skips that app and continues. Dashboard copies expire after 7 days. The restic copies on R2 follow your existing 7d / 5 weekly / 12 monthly retention.

Run the same flow now:

```sh
sudo docker exec CONTAINER_NAME /usr/local/bin/app-backup.sh
```

`restore.sh live` puts Postgres, the upload bucket, and server config back. It does not replace the dashboard backups bucket. After you extract a restic snapshot, mirror `minio-app-backups` from that snapshot into `S3_APP_BACKUPS_BUCKET` with `mc`. The dashboard lists any copies that have not passed `expires_at`.

## 9. Required restore drill

Do this before you treat backups as complete. The drill restores into temporary names. It does not replace live data.

```sh
sudo docker exec -e RESTORE_CLEANUP=yes CONTAINER_NAME /usr/local/bin/restore.sh drill
```

Compose checkout:

```sh
docker compose --profile restore run --rm \
  -e RESTORE_SNAPSHOT=latest \
  -e RESTORE_CLEANUP=yes \
  restore drill
```

The helper:

1. Restores the latest snapshot into isolated staging
2. Creates a uniquely named PostgreSQL database and opens it
3. Creates a uniquely named MinIO bucket and compares object counts
4. Extracts the server-config archive, including `override.edn` if present
5. Prints `DRILL OK`
6. Removes those temporary targets when `RESTORE_CLEANUP=yes`

A verified empty-upload drill still succeeds. Object counts can be `restored=0 destination=0`. The temporary database should open and contain Instant user tables. Record the `DRILL OK` line. If the drill fails, do not rely on the backups yet.

To inspect targets before cleanup, omit `RESTORE_CLEANUP=yes` and drop them yourself after you have looked.

Do **not** run `restore.sh live` except during a real disaster recovery.

## 10. Live disaster recovery

This replaces live Instant data. Read the whole sequence first.

1. Tell users the site will be down.
2. Stop the write-producing services. Leave PostgreSQL and MinIO up.

   ```sh
   sudo docker stop INSTANT_SERVER_CONTAINER INSTANT_WWW_CONTAINER
   ```

   Compose checkout:

   ```sh
   docker compose stop server www
   ```

3. Preserve the current volumes. Do not delete `backend-db`, `minio_data`, or `server_config` until the restored site is verified.

   ```sh
   sudo docker volume ls
   ```

   If you can, snapshot or copy those volumes on the host first.

4. List snapshots and pick one.

   ```sh
   sudo docker exec CONTAINER_NAME /usr/local/bin/restore.sh list
   ```

5. Restore that snapshot into isolated staging and confirm it looks right.

   ```sh
   sudo docker exec \
     -e RESTORE_SNAPSHOT=replace-with-snapshot-id \
     CONTAINER_NAME /usr/local/bin/restore.sh drill
   ```

6. Replace live data only after that drill succeeds.

   ```sh
   sudo docker exec \
     -e RESTORE_SNAPSHOT=replace-with-snapshot-id \
     -e RESTORE_TARGET_DB=instant \
     -e RESTORE_TARGET_BUCKET=instant-bucket \
     -e RESTORE_CONFIRM=I_UNDERSTAND_THIS_REPLACES_LIVE_DATA \
     CONTAINER_NAME /usr/local/bin/restore.sh live
   ```

   `RESTORE_TARGET_DB` must match `POSTGRES_DB`. `RESTORE_TARGET_BUCKET` must match `S3_BUCKET`. The confirm phrase must match exactly.

7. Start services in dependency order. In Portainer, start `postgres` and `minio`, then `server`, then `www`, `cloudflared`, and `backup`.

   Compose checkout:

   ```sh
   docker compose up -d postgres minio
   docker compose up -d server
   docker compose up -d www cloudflared backup
   ```

8. Verify:

   ```sh
   curl -fsS https://api.example.com/health/system
   ```

   Expect `{"wal":"ok"}`. Open the dashboard and download one known file.

If verification fails, stop `server` and `www` again. Restore an older snapshot, or put the preserved volumes back.

## 11. Rotate credentials

| Secret | What to do |
| --- | --- |
| R2 access key | Create a new scoped token, update Portainer, redeploy, confirm a backup succeeds, then revoke the old token. |
| `RESTIC_PASSWORD` | This password is the repository key. Changing it needs a new repository or a restic key-add workflow. Do not change it casually. |
| MinIO or Postgres passwords | Update Portainer and redeploy. Backups use the same values as the running stack. |

After you rotate R2 keys, keep the same repository path. Do not change `R2_BUCKET`, `R2_ENDPOINT`, or `RESTIC_REPOSITORY_PREFIX` on a repository that already has snapshots.

## 12. Isolated tooling test

This does not touch the live Instant volumes. It starts disposable PostgreSQL, MinIO, and an R2 stand-in. Run it from a machine that has Docker and this repo:

```sh
bash backup/test/run-isolated.sh
```

Use that after you change backup scripts. The required production drill is still the command in section 9 against the real R2 bucket.
