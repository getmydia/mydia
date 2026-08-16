# Managing Libraries

Libraries are the core of Mydia's media organization system. Each library represents a collection of media files in a specific directory.

See [Library Types](../reference/library-types.md) for the full list of supported types and their capabilities.

## Creating Libraries

### Via Environment Variables

Configure libraries at container startup. `MOVIES_PATH` and `TV_PATH` each create a default library automatically; use the numbered `LIBRARY_PATH_<N>_*` variables to add more:

```bash
# Default libraries
MOVIES_PATH=/media/library/movies
TV_PATH=/media/library/tv

# Additional libraries using numbered variables
LIBRARY_PATH_1_PATH=/media/documentaries
LIBRARY_PATH_1_TYPE=movies

LIBRARY_PATH_2_PATH=/media/anime
LIBRARY_PATH_2_TYPE=mixed
```

### Via Admin UI

1. Navigate to **Admin > Configuration**, then the **Library** tab
2. Click **New** in the Library Paths panel
3. Fill in the form:
   - **Path** (required) is the path inside the container
   - **Type** (required) is Movies, Series, or Mixed
   - **Monitored** controls whether scan-all includes this library
   - **Automatic scanning** picks a scan schedule, or Off
   - **TV metadata source** appears for Series and Mixed libraries only
   - Auto-import, auto-organize, write NFO, and auto-rename toggles
4. Click **Add Library**

Libraries have no name of their own; they are identified by their path. There is
no per-library quality profile field in this form either.

## Library Scanning

Scanning discovers media files that Mydia did not add itself, such as files you copied
into a library folder by hand. Files that arrive through the download and import
pipeline are added automatically and do not need a scan.

Scanning is manual by default. You can enable automatic scanning per library.

### Automatic Scanning

Set **Automatic scanning** on a library to have Mydia rescan that folder on a schedule.
Choose from six presets: Off (manual only, the default), every 15 minutes (the
shortest supported interval), every hour, every 6 hours, every 12 hours, or daily.
There is no free-form interval entry.

Scheduled scans are spread out by a random delay of up to 30 minutes so that many
self-hosted instances do not all contact the metadata service at once. Manual scans
start immediately.

You can also set this with the `LIBRARY_PATH_<N>_SCAN_INTERVAL` environment variable,
in seconds. When that variable is set it takes precedence and the value is reapplied on
every restart. When it is not set, your choice in the admin interface is preserved.

### Manual Scanning

Trigger a scan at any time from the library page or the admin interface. Manual scans
work whether or not automatic scanning is enabled.

### Monitored

**Monitored** controls whether a library is included when you trigger a scan of all
libraries. It does not by itself enable automatic scanning, but a library must also
be Monitored for its automatic scanning schedule to run. Unmonitoring a library
pauses both its inclusion in scan-all and any automatic schedule you have set for it.

## Path Management

Mydia uses **relative path storage** for media files:

- **Flexible Relocation** - Change library root paths without breaking file references
- **Path Independence** - Database records are portable
- **Automatic Migration** - Paths convert automatically on upgrade

## Changing Library Paths

**Via Environment Variables:**

```bash
MOVIES_PATH=/new/path/movies
TV_PATH=/new/path/tv
```

**Via Admin UI:**

1. Navigate to **Admin > Configuration**, then the **Library** tab
2. Edit the library and change its **Path**
3. Save

!!! warning "The path is not checked when you save"
    Mydia validates that the path is present and unique, and nothing else. It does
    not check that the directory exists inside the container, that it is readable,
    or that it is writable. A typo saves cleanly and then produces an empty or
    failing scan.

    After changing a path, run a scan and check the result before assuming it
    worked.

When a path is set by an environment variable, the environment wins and the
value is reapplied on every restart. See
[Configuration Reference](../reference/configuration.md) for the precedence
order, and [Why Configuration Is Layered](../explanation/configuration-model.md)
for the reasoning behind it.

## Next Steps

- [Importing an Existing Collection](import-existing-collection.md) - Bring files you already have into a library via scanning
- [Adding Media](add-media.md) - Search for and download new media
- [Quality Profiles](quality-profiles.md) - Configure download quality
