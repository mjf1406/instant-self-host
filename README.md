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
8. Initialize the backup repository and run the restore drill. The backup service stays unhealthy until you do this. Follow [Backup and restore](docs/backup-and-restore.md).

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
npx instant-cli@latest login
```

After login, use the same URLs with `create-instant-app`:

```sh
INSTANT_CLI_API_URI=https://api.example.com \
INSTANT_CLI_DASH_URI=https://dash.example.com \
npx create-instant-app@latest
```

That writes `instant.config.ts` with `apiURI` and `dashURI`.

## 8. Update

In Portainer, open the stack and use **Pull and redeploy**. Instant publishes new `server` and `dashboard` images on `latest`. The `backup` service still builds from source. Do not treat a `pull access denied` error for that image as a registry login problem.

## 9. Backups

Encrypted snapshots go to a dedicated Cloudflare R2 bucket every 6 hours UTC. The interval is `BACKUP_CRON` if you want a different schedule.

The backup copies PostgreSQL, MinIO uploads, and Instant server config. The live database and MinIO volumes are not mounted into the backup container.

Do this after the first deploy:

1. Create the dedicated R2 bucket and scoped token.
2. Add the 7-day bucket locks on restic's durable prefixes.
3. Set `RESTIC_PASSWORD` and the R2 keys in Portainer.
4. Initialize the repository with an explicit confirm.
5. Wait until the `backup` service is healthy.
6. Run the isolated restore drill. Do not skip this.

The full setup, lock prefixes, drill command, credential rotation, and live recovery steps are in [Backup and restore](docs/backup-and-restore.md).

## Notes

- **Memory.** The backend JVM is capped at 2 GB (`JAVA_OPTS=-Xmx2g -Xms2g`). Raise this if the host has spare RAM and Instant is the main workload.
- **Email.** No email provider is configured. Dashboard login uses Google. If an app sends a magic code, Instant writes it to the `server` container logs.
- **Uploads.** Cloudflare Free caps each request at about 100 MB. That limit applies to `files.example.com`.
- **Backups.** Do not treat the Docker volumes as the only copy. Use the R2 backup flow in [Backup and restore](docs/backup-and-restore.md).
- **Other sites.** Other subdomains on your domain can share this Instant instance. Give each site its own app in the dashboard. They can also share one Cloudflare tunnel for their front ends. Instant still needs this stack’s tunnel (or a connector on the same Docker network).
- **Other services on the server.** This tunnel only publishes the hostnames you add. SSH, Portainer, and LAN-only apps stay private. Do not add their hostnames here, and do not add a private CIDR route.
