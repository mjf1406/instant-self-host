# InstantDB on Portainer

Self-host InstantDB on a home Ubuntu server. Portainer runs the stack. A Cloudflare Tunnel publishes it. No ports are opened on your LAN.

Replace `example.com` with your domain. This stack needs three hostnames:

| Hostname | Service |
| --- | --- |
| `https://dash.example.com` | Dashboard |
| `https://api.example.com` | Backend API |
| `https://files.example.com` | File storage |

Sign in to the dashboard with Google. Set `INSTANT_SUPERUSER_EMAIL` to the Google account that should administer the instance.

## 1. Prerequisites

- Ubuntu server with Docker and Portainer already running
- A domain on Cloudflare
- A Google Cloud project where you can create an OAuth client
- A dedicated Cloudflare R2 bucket for backups. See [Backup and restore](docs/backup-and-restore.md).

## 2. Create the Cloudflare Tunnel

You can do this before the stack is running. Create the tunnel and save the token now. Do **not** install `cloudflared` on the Ubuntu host. This stack already runs a `cloudflared` container.

One tunnel can publish many hostnames. You do **not** need a new tunnel for each site. This Instant stack should use its **own** tunnel so the container can reach Docker names like `server` and `www`. Other apps on the same server stay off this tunnel unless you add them as routes.

Do **not** add a private network / CIDR route (for example `192.168.1.0/24`). That can expose the rest of the LAN.

### Create the tunnel and copy the token

1. Open [Networking → Tunnels](https://dash.cloudflare.com/) in the Cloudflare dashboard (or Zero Trust → **Networks** → **Connectors** → **Cloudflare Tunnels**).
2. **Create Tunnel**. Connector type: **Cloudflared**. Name it something like `instant`.
3. On **Setup Environment** / **Install and Run**, you will see a command like:

   ```bash
   sudo cloudflared service install eyJ...
   ```

4. Copy only the long `eyJ...` string. That is `TUNNEL_TOKEN`. Paste it into a password manager.
5. Do **not** run that install command on the server.

The **Tunnel ID** on the Overview page is a short UUID. It is not the token.

If you already left the wizard and only see the Tunnel ID:

1. Open the tunnel.
2. Click **Add a replica** (Overview) or **Edit**.
3. Copy the `eyJ...` token from the install command.
4. Go back. Do not run the command.

### Add the three Instant hostnames

This is on the same tunnel page. Open the **Routes** tab, or click **+ Add route** on Overview.

For each hostname:

1. **+ Add route**
2. Choose **Published application** (not a private network)
3. Fill in the hostname and service URL
4. Save, then add the next one

| Public hostname | Type | Service URL |
| --- | --- | --- |
| `api.example.com` | HTTP | `http://server:8888` |
| `dash.example.com` | HTTP | `http://www:3000` |
| `files.example.com` | HTTP | `http://minio:9000` |

Those Docker names only resolve **inside this stack**. Do not point them at an existing host-level tunnel unless that connector shares this stack’s Docker network.

Cloudflare creates the DNS CNAMEs for you. The tunnel stays down until Portainer starts this stack. That is expected.

## 3. Create the Google OAuth client

1. Open [Google Cloud Console](https://console.cloud.google.com/apis/credentials).
2. Create a **Web application** OAuth client.
3. Add this authorized redirect URI:

```text
https://api.example.com/dash/oauth/callback
```

4. Copy the client ID and client secret.

## 4. Deploy in Portainer

1. In Portainer, go to **Stacks** → **Add stack**.
2. Choose **Repository**.
3. Use this repo URL and the `docker-compose.yml` at the root.
4. Open the environment variables editor (advanced mode).
5. Copy [`.env.example`](.env.example) into it.
6. Replace these values:
   - `INSTANT_BACKEND_URL`
   - `INSTANT_DASHBOARD_URL`
   - `S3_PUBLIC_ENDPOINT`
   - `TUNNEL_TOKEN`
   - `POSTGRES_PASSWORD`
   - `MINIO_ROOT_USER`
   - `MINIO_ROOT_PASSWORD`
   - `INSTANT_SUPERUSER_EMAIL`
   - `INSTANT_DASHBOARD_GOOGLE_OAUTH_CLIENT_ID`
   - `INSTANT_DASHBOARD_GOOGLE_OAUTH_CLIENT_SECRET`
   - `R2_ACCOUNT_ID`
   - `R2_ACCESS_KEY_ID`
   - `R2_SECRET_ACCESS_KEY`
   - `RESTIC_PASSWORD`
7. Deploy the stack. Leave **Re-pull image** off. The `backup` image is not on Docker Hub. Portainer builds it from `backup/Dockerfile` in this repo. If deploy fails with `pull access denied for instant-self-host-backup`, update the stack to this compose file and deploy again without re-pull.
8. Finish first-time backups in [section 9](#9-backups). The `backup` service stays unhealthy until you initialize the repository and take the first snapshot.

## 5. Verify

On Linux or macOS:

```sh
curl -fsS https://api.example.com/health/system
```

On Windows PowerShell, `curl` is `Invoke-WebRequest` and `-fsS` fails. Use real curl:

```powershell
curl.exe -fsS https://api.example.com/health/system
```

Or:

```powershell
Invoke-WebRequest -Uri https://api.example.com/health/system -UseBasicParsing
```

A healthy backend returns `{"wal":"ok"}`. If Instant is not up yet, you get a connection error or a Cloudflare 502/530.

Open `https://dash.example.com` and sign in with Google as the email you set in `INSTANT_SUPERUSER_EMAIL`.

## 6. Lock it down

The API is on the public internet. After the first login:

1. Open the account menu → **Deployment Settings**.
2. Set **Who can sign up?** to **Closed**.
3. Turn off **Allow temporary app creation**. The switch is **off** when the handle is on the left and the track is dark.

Existing users can still sign in. No one else can create a dashboard account or a temporary app.

## 7. Create an app for each site

Create one Instant app per site. Each site gets its own `app_id`.

Point clients at this instance:

```ts
init({
  appId: 'your-app-id',
  apiURI: 'https://api.example.com',
  websocketURI: 'wss://api.example.com/runtime/session',
});
```

To use the Instant CLI against this instance:

```sh
INSTANT_CLI_API_URI=https://api.example.com \
INSTANT_CLI_DASH_URI=https://dash.example.com \
bunx instant-cli@latest login
```

After login, use the same URLs with `create-instant-app`:

```sh
INSTANT_CLI_API_URI=https://api.example.com \
INSTANT_CLI_DASH_URI=https://dash.example.com \
bunx create-instant-app@latest
```

That writes `instant.config.ts` with `apiURI` and `dashURI`.

## 8. Update

In Portainer, open the stack and use **Pull and redeploy**. Instant publishes new `server` and `dashboard` images on `latest`. The `backup` service still builds from source. Do not treat a `pull access denied` error for that image as a registry login problem.

## 9. Backups

Encrypted snapshots go to a dedicated Cloudflare R2 bucket every 6 hours UTC. Change `BACKUP_CRON` if you want a different interval.

Each snapshot includes a PostgreSQL dump, the current MinIO uploads, and Instant server config. The backup container does not mount the live database or MinIO volumes.

Do this after the first deploy. Use placeholders here. Keep real keys and `RESTIC_PASSWORD` in a password manager.

Live disaster recovery, credential rotation, and extra Compose-checkout commands are in [Backup and restore](docs/backup-and-restore.md).

### 9.1 Create the R2 bucket and token

1. Open [R2](https://dash.cloudflare.com/) in the Cloudflare dashboard.
2. Create a dedicated bucket named `instant-self-host-backups`, or another name you will put in `R2_BUCKET`. Do not reuse the public files hostname or the live MinIO bucket.
3. Copy the **Account ID** from the R2 overview page. That is `R2_ACCOUNT_ID`.
4. Open **Manage API tokens**.
5. Create an **Account API token**. Prefer an account token, not a user token.
6. Permission: **Object Read & Write**. Do not choose Admin.
7. Apply it to this backup bucket only.
8. Copy the Access Key ID and Secret Access Key into a password manager. The secret is shown once.

Leave object lifecycle deletion off. restic removes old snapshots itself.

### 9.2 Store `RESTIC_PASSWORD`

Generate a long random password, at least 32 characters. Store it in a password manager that is not only on this server.

This password encrypts the backups. If you lose it, the copies on R2 cannot be opened. There is no reset. Do not reuse the MinIO or Postgres password.

### 9.3 Add the 7-day bucket locks

In the backup bucket **Settings** → **Bucket lock**, add five **Age** rules of **7 days**:

| Prefix | Lock |
| --- | --- |
| `data/` | 7 days |
| `index/` | 7 days |
| `snapshots/` | 7 days |
| `keys/` | 7 days |
| `config` | 7 days |

`data/`, `index/`, `snapshots/`, and `keys/` need the trailing slash. `config` does not. Leave `locks/` unlocked so restic can coordinate jobs. Do not lock the whole bucket with an empty prefix.

Keep `RESTIC_KEEP_WITHIN` at `7d` or longer. A shorter keep period will try to delete objects the lock still protects.

### 9.4 Put the variables in Portainer and redeploy

Copy the backup block from [`.env.example`](.env.example). Replace the `replace-with-...` values.

Fill these:

| Variable | Value |
| --- | --- |
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | Token access key |
| `R2_SECRET_ACCESS_KEY` | Token secret |
| `RESTIC_PASSWORD` | The restic password from 9.2 |
| `R2_BUCKET` | `instant-self-host-backups` unless you chose another name |
| `R2_REGION` | `auto` |

Leave these empty in the persistent Portainer environment:

- `R2_ENDPOINT` — use this only for the account-level endpoint `https://<account-id>.r2.cloudflarestorage.com`. Never put the bucket name in this URL.
- `RESTIC_REPOSITORY`
- `RESTIC_REPOSITORY_PREFIX` — do not set this to the bucket name. That creates an extra path segment.
- `BACKUP_STAGING_SOURCE`
- `RESTIC_INIT_CONFIRM`
- `RESTORE_TARGET_DB`, `RESTORE_TARGET_BUCKET`, `RESTORE_CONFIRM`

Redeploy so Portainer builds `backup/Dockerfile`. Leave **Re-pull image** off. The backup image is not on Docker Hub.

After deploy, Instant should still return `{"wal":"ok"}`. The `backup` container exists, but it stays unhealthy until you initialize the repository and take a snapshot.

### 9.5 Find the backup container

SSH to the Ubuntu host. Portainer often stores compose files inside its own container, so `/data/compose` may not exist on the host. You do not need that folder.

```sh
sudo docker ps -a --filter name=backup
```

Use the **NAMES** column. Portainer may call it `instantdb-backup-1` or similar. The short filter `backup` is not always the container name. Use `sudo` if your user cannot talk to Docker.

### 9.6 Check the repository URL, then initialize

```sh
sudo docker logs --tail 50 CONTAINER_NAME
```

The log should show a restic URL like:

```text
s3:https://<account-id>.r2.cloudflarestorage.com/instant-self-host-backups
```

Confirm the account ID and bucket name. If the URL is wrong, fix Portainer variables and redeploy. Do not initialize yet.

A URL that repeats the bucket name means `RESTIC_REPOSITORY_PREFIX` or `R2_ENDPOINT` includes the bucket. Fix that before the first init. After a repository exists, that path is fixed. Do not change it later unless you plan a migration.

Initialize with an explicit confirm:

```sh
sudo docker exec -e RESTIC_INIT_CONFIRM=yes CONTAINER_NAME /usr/local/bin/init-repo.sh
```

Success looks like `repository initialized`. If it says the repository already exists, do not init again.

| Message | What it means |
| --- | --- |
| `refusing to initialize` | `RESTIC_INIT_CONFIRM` was not `yes` |
| Access denied / 403 | Token is wrong, or it is not allowed on this bucket |
| No such host / 404 | Account ID or bucket name is wrong |
| Missing environment variable | A required Portainer variable is empty |

### 9.7 Run the first backup

Init through `docker exec` does not start a snapshot. The already-running scheduler skipped startup because the repository was missing. The next cron run is `0 */6 * * *` UTC (`00:00`, `06:00`, `12:00`, `18:00`).

Run the first snapshot now:

```sh
sudo docker exec CONTAINER_NAME /usr/local/bin/backup.sh
```

Or restart the container so the entrypoint sees the repository and backs up on startup:

```sh
sudo docker restart CONTAINER_NAME
sudo docker logs -f CONTAINER_NAME
```

Wait for `backup completed`, then `no errors were found` from the metadata check. The first successful run also applies retention and a 5% data-sample check.

```sh
sudo docker ps --filter name=CONTAINER_NAME
```

You want `(healthy)`. An empty MinIO upload bucket is fine. The snapshot should still include the Postgres dump and server config.

### 9.8 Run the restore drill

Do this before you treat backups as complete. The drill restores into temporary names. It does not replace live Instant data.

```sh
sudo docker exec -e RESTORE_CLEANUP=yes CONTAINER_NAME /usr/local/bin/restore.sh drill
```

The helper should:

1. Restore the latest snapshot into isolated staging
2. Create a temporary PostgreSQL database and open it
3. Create a temporary MinIO bucket and match object counts
4. Extract server config, including `override.edn` if present
5. Print `DRILL OK`
6. Remove those temporary targets when `RESTORE_CLEANUP=yes`

An empty upload bucket can report `restored=0 destination=0`. That still matches.

Do **not** run `restore.sh live` except during a real disaster recovery. That command replaces production data and needs `RESTORE_CONFIRM=I_UNDERSTAND_THIS_REPLACES_LIVE_DATA`. See [Backup and restore](docs/backup-and-restore.md).

## Notes

- **Memory.** The backend JVM is capped at 2 GB (`JAVA_OPTS=-Xmx2g -Xms2g`). Raise this if the host has spare RAM and Instant is the main workload.
- **Email.** No email provider is configured. Dashboard login uses Google. If an app sends a magic code, Instant writes it to the `server` container logs.
- **Uploads.** Cloudflare Free caps each request at about 100 MB. That limit applies to `files.example.com`.
- **Backups.** Do not treat the Docker volumes as the only copy. Follow [section 9](#9-backups) for first-time setup. Live recovery is in [Backup and restore](docs/backup-and-restore.md).
- **Other sites.** Other subdomains on your domain can share this Instant instance. Give each site its own app in the dashboard. They can also share one Cloudflare tunnel for their front ends. Instant still needs this stack’s tunnel (or a connector on the same Docker network).
- **Other services on the server.** This tunnel only publishes the hostnames you add. SSH, Portainer, and LAN-only apps stay private. Do not add their hostnames here, and do not add a private CIDR route.
