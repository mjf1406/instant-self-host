# Restore one app from R2

Use this page when you need one Instant app back and the original stack may be gone.

This path does **not** replace live Postgres, MinIO, or server config. For a whole-host recovery, use [Backup and restore](backup-and-restore.md#9-required-restore-drill) sections 9 and 10.

## What you need

R2 holds an encrypted restic repository, not one Instant ZIP per app. You cannot download a single R2 object and upload it to **Restore from backup**.

Recovery needs three things that are not in R2 itself:

- this repository
- R2 read credentials
- `RESTIC_PASSWORD`

If `RESTIC_PASSWORD` is lost, no script can open the repository.

The ZIP contains production app data. Create it only on a machine you trust. Delete it after the restore.

## Clean host

Use this when the original stack is gone or `/staging` is not usable. You need Docker and a clone of this repo.

1. Copy [backup/recovery.env.example](../backup/recovery.env.example) to `backup/recovery.env`. Do not commit that file. Fill in the R2 values and `RESTIC_PASSWORD` from your password manager. Use the same `R2_BUCKET`, `R2_ENDPOINT`, and `RESTIC_REPOSITORY_PREFIX` the production stack used.

2. Create a host directory for the ZIP:

   ```sh
   mkdir -p backup/exports
   ```

3. List snapshots:

   ```sh
   docker compose \
     --env-file backup/recovery.env \
     -f backup/recovery-compose.yml \
     run --rm recover list
   ```

4. Export one app. The default ZIP name is `<app-id>-<backup-id>.zip` in `backup/exports`.

   ```sh
   docker compose \
     --env-file backup/recovery.env \
     -f backup/recovery-compose.yml \
     run --rm recover \
     --app replace-with-app-id \
     --snapshot latest
   ```

   Add `--backup-prefix replace-with-backup-id` to pick an older dashboard copy from that snapshot. Add `--output /staging/exports/my-app.zip` to set the file name. The command refuses to overwrite a ZIP unless you also pass `--force`.

5. On a working Instant dashboard, sign in as the superuser and open `/intern/restore`, or use **Restore from backup**. Upload `backup/exports/<app-id>-<backup-id>.zip`. Instant creates a new app from the ZIP. It does not overwrite an existing app id unless you delete that app first.

6. Check schema, data, and files in the restored app. Then delete the ZIP.

   ```sh
   shred -u backup/exports/replace-with-app-id-replace-with-backup-id.zip
   ```

   If `shred` is not installed, delete the local copy in a secure-delete tool you already use.

## Optional: original container is still running

If the backup container is healthy and `/staging` is writable, you can export there instead:

```sh
sudo docker exec CONTAINER_NAME /usr/local/bin/export-app-backup.sh list
sudo docker exec CONTAINER_NAME /usr/local/bin/export-app-backup.sh \
  --app replace-with-app-id \
  --snapshot latest
sudo docker cp \
  CONTAINER_NAME:/staging/exports/replace-with-app-id-replace-with-backup-id.zip \
  ./instant-app-restore.zip
```

That still reads from R2. It does not use the local MinIO copies. If `/staging` is corrupt, use the clean-host steps above.
