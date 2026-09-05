# Backup and restore

This stack copies InstantDB data to a dedicated Cloudflare R2 bucket. Each snapshot includes:

- a PostgreSQL custom-format dump
- the current MinIO upload bucket
- the Instant server config volume

restic encrypts the snapshot before it leaves the server. If you lose `RESTIC_PASSWORD`, the copies on R2 cannot be opened.

## What you need

- A Cloudflare account that can create R2 buckets and API tokens
- Free disk for staging. Default staging is a Docker volume on the root disk. The root disk on this host had about 350 GB free when this was designed. `/media/vault1` is the larger disk if uploads grow.
- The Instant stack already running, or about to run, on the Ubuntu server

## 1. Create a dedicated R2 bucket

1. Open [R2](https://dash.cloudflare.com/) in the Cloudflare dashboard.
2. Create a bucket named `instant-self-host-backups`, or another name you will put in `R2_BUCKET`.
3. Do not reuse the public files hostname or the live MinIO bucket.
4. Copy the account ID from the R2 overview page into `R2_ACCOUNT_ID`.

Leave object lifecycle deletion off. restic removes old snapshots itself.

## 2. Create a scoped R2 token

1. Open **R2** → **Overview** → **Manage API tokens**.
2. Create an **Account API token**.
3. Permission: **Object Read & Write**.
4. Apply it to this backup bucket only.
5. Copy the Access Key ID and Secret Access Key into a password manager. The secret is shown once.

Put those values in Portainer as `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.

## 3. Create the restic password

Generate a long random password and store it in a password manager that is not only on this server. Set it as `RESTIC_PASSWORD`.

Treat this password as the recovery key. A stolen R2 token without this password cannot read the backups. A lost password cannot be reset.

## 4. Add the 7-day bucket lock

Apply Cloudflare bucket locks to restic's durable prefixes. Leave `locks/` unlocked so restic can coordinate jobs.

In the bucket **Settings** → **Bucket lock**, add 7-day age rules for these prefixes:

| Prefix | Lock |
| --- | --- |
| `data/` | 7 days |
| `index/` | 7 days |
| `snapshots/` | 7 days |
| `keys/` | 7 days |
| `config` | 7 days |

Do not lock `locks/`.

If you prefer Wrangler:

```sh
npx wrangler r2 bucket lock add instant-self-host-backups --prefix data/ --timeout 7d
npx wrangler r2 bucket lock add instant-self-host-backups --prefix index/ --timeout 7d
npx wrangler r2 bucket lock add instant-self-host-backups --prefix snapshots/ --timeout 7d
npx wrangler r2 bucket lock add instant-self-host-backups --prefix keys/ --timeout 7d
npx wrangler r2 bucket lock add instant-self-host-backups --prefix config --timeout 7d
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

Copy the backup block from [`.env.example`](../.env.example). Replace the `replace-with-...` values. Leave `RESTIC_INIT_CONFIRM` empty in the running stack.

Redeploy the stack so Portainer builds the `backup` image from `backup/Dockerfile`. Enable rebuild if the image is missing. The backup container stays unhealthy until the repository exists and the first snapshot succeeds.

## 7. Initialize the repository

Check the account ID, endpoint, and bucket one more time. This command creates a restic repository. It will not run unless you confirm.

On the Ubuntu host, in the stack directory, or with Portainer's command console equivalent:

```sh
docker compose --profile backup-init run --rm -e RESTIC_INIT_CONFIRM=yes backup-init
```

If the names are wrong, fix them and run the command again. The script refuses to create a repository without `RESTIC_INIT_CONFIRM=yes`.

After init succeeds, the backup service runs one snapshot immediately, then on `BACKUP_CRON` (default `0 */6 * * *`, UTC).

## 8. Watch the first backup

```sh
docker compose logs -f backup
docker compose ps backup
```

Portainer should show `backup` as healthy after the first snapshot. Failures stay in the container logs. The service becomes unhealthy if no successful snapshot is newer than `BACKUP_FRESHNESS_SECONDS` (8 hours by default).

Manual extra run:

```sh
docker compose exec backup /usr/local/bin/backup.sh
```

List snapshots:

```sh
docker compose --profile restore run --rm restore list
```

## 9. Required restore drill

Do this before you treat backups as complete. The drill restores into temporary names. It does not replace live data.

```sh
docker compose --profile restore run --rm \
  -e RESTORE_SNAPSHOT=latest \
  -e RESTORE_CLEANUP=yes \
  restore drill
```

The helper:

1. Restores the snapshot into isolated staging
2. Creates a uniquely named PostgreSQL database and checks that it opens
3. Creates a uniquely named MinIO bucket and compares object counts
4. Extracts the server-config archive into a temporary directory
5. Removes those temporary targets when `RESTORE_CLEANUP=yes`

Record the `DRILL OK` line. If the drill fails, do not rely on the backups yet.

To inspect targets before cleanup, omit `RESTORE_CLEANUP=yes` and drop them yourself after you have looked.

## 10. Live disaster recovery

This replaces live Instant data. Read the whole sequence first.

1. Tell users the site will be down.
2. Stop the write-producing services. Leave PostgreSQL and MinIO up.

   ```sh
   docker compose stop server www
   ```

3. Preserve the current volumes. Do not delete `backend-db`, `minio_data`, or `server_config` until the restored site is verified.

   ```sh
   docker volume ls
   ```

   If you can, snapshot or copy those volumes on the host first.

4. List snapshots and pick one.

   ```sh
   docker compose --profile restore run --rm restore list
   ```

5. Restore that snapshot into isolated staging and confirm it looks right.

   ```sh
   docker compose --profile restore run --rm \
     -e RESTORE_SNAPSHOT=replace-with-snapshot-id \
     restore drill
   ```

6. Replace live data only after that drill succeeds.

   ```sh
   docker compose --profile restore run --rm \
     -e RESTORE_SNAPSHOT=replace-with-snapshot-id \
     -e RESTORE_TARGET_DB=instant \
     -e RESTORE_TARGET_BUCKET=instant-bucket \
     -e RESTORE_CONFIRM=I_UNDERSTAND_THIS_REPLACES_LIVE_DATA \
     restore live
   ```

   `RESTORE_TARGET_DB` must match `POSTGRES_DB`. `RESTORE_TARGET_BUCKET` must match `S3_BUCKET`. The confirm phrase must match exactly.

7. Start services in dependency order.

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

## 12. Isolated tooling test

This does not touch the live Instant volumes. It starts disposable PostgreSQL, MinIO, and an R2 stand-in:

```sh
bash backup/test/run-isolated.sh
```

Use that after you change backup scripts. The required production drill is still the command in section 9 against the real R2 bucket.
