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
LIBRARY_PATH_1_PATH=/media/music
LIBRARY_PATH_1_TYPE=music

LIBRARY_PATH_2_PATH=/media/books
LIBRARY_PATH_2_TYPE=books
```

### Via Admin UI

1. Navigate to **Admin > Libraries**
2. Click **Add Library**
3. Configure:
   - Name
   - Path
   - Type
   - Quality Profile
   - Monitoring settings

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

<!-- MOVES TO explanation/configuration-model.md IN TASK 11

### Configuration Priority

1. Environment variables (highest)
2. Admin UI (database settings)
3. YAML configuration file
4. Schema defaults (lowest)

-->

## Changing Library Paths

**Via Environment Variables:**

```bash
MOVIES_PATH=/new/path/movies
TV_PATH=/new/path/tv
```

**Via Admin UI:**

1. Navigate to **Admin > Settings**
2. Update library paths
3. Mydia validates files are accessible before saving

## Next Steps

- [Importing an Existing Collection](import-existing-collection.md) - Bring files you already have into a library via scanning
- [Adding Media](add-media.md) - Search for and download new media
- [Quality Profiles](quality-profiles.md) - Configure download quality
