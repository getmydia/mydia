# Keep a library in S3 storage

Mydia can read a library from an S3-compatible bucket (AWS S3, MinIO, Cloudflare
R2, Backblaze B2, RustFS and similar) instead of a folder on disk. Mydia scans
the bucket, analyzes the files, and streams them to the web player and the
mobile and desktop apps, including over remote access.

## Add a storage backend

A storage backend is a named connection to one bucket. You can add one in the
interface or declare it in configuration.

### In the interface

1. Open **Admin**, then **Storage**.
2. Add a backend and fill in the name, endpoint, region, bucket, access key ID
   and secret access key.
3. Use **Test connection** to check the credentials and that the bucket is
   reachable, then save.

Leave the endpoint empty for AWS S3. For MinIO, RustFS and most other
self-hosted servers, keep **Path-style addressing** enabled.

### In configuration

Environment variables, numbered from 1:

```bash
STORAGE_BACKEND_1_NAME=media
STORAGE_BACKEND_1_ENDPOINT=http://minio:9000
STORAGE_BACKEND_1_REGION=us-east-1
STORAGE_BACKEND_1_BUCKET=library
STORAGE_BACKEND_1_ACCESS_KEY_ID=AKIDEXAMPLE
STORAGE_BACKEND_1_SECRET_ACCESS_KEY=change-me
STORAGE_BACKEND_1_PATH_STYLE=true
```

Or in `config.yml`:

```yaml
storage_backends:
  - name: media
    endpoint: "http://minio:9000"
    region: us-east-1
    bucket: library
    access_key_id: AKIDEXAMPLE
    secret_access_key: change-me
    path_style: true
```

Backends declared this way appear in the Storage page as read-only rows. See the
[environment variable reference](../reference/environment-variables.md#s3-storage-backends)
for the full list.

## Add a library path

Add a library path whose path is `s3://<backend name>/<prefix>`, for example
`s3://media/movies`. The prefix is the folder inside the bucket where the library
starts; leave it out to use the whole bucket. Choose the library type as you
would for a local library, then scan it. Files should be organized the same way
as in a local library, such as `Movies/Invented Film (2031)/Invented Film (2031).mp4`.

If the bucket cannot be reached during a scan, the scan fails and Mydia leaves
your library as it was. Files are only marked missing when the bucket answers and
the file is really gone.

## What Mydia writes to the bucket

- Imported downloads. Mydia copies the file into the bucket and leaves the
  original where it is, so torrents keep seeding.
- Renames and organizing, when Auto Rename and Auto Organize are on for the
  library.
- NFO files and downloaded subtitles, next to the media file.
- A trash folder named `.mydia-trash` inside the library prefix. Files you delete
  or replace go there first and are removed after the usual trash retention.

Imports upload the whole file, and some providers bill for requests and egress.

## Things to know

- Playback goes through your Mydia server. Video bytes travel from the bucket to
  Mydia and on to the player, so the bandwidth counts as egress with your
  provider, and Mydia needs to reach the bucket from wherever it runs.
- Analysis, thumbnails and subtitle extraction read from the bucket too, so the
  first scan of a large library makes many requests.
- Keep the secret access key private. Mydia hides it in the interface and in
  logs.
