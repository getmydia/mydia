# Managing Libraries

Libraries are the core of Mydia's media organization system. Each library represents a collection of media files in a specific directory.

## Library Types

| Type | Description | Features |
|------|-------------|----------|
| **Movies** | Feature films | Full metadata, downloads, quality profiles |
| **Series** | TV shows with seasons/episodes | Episode tracking, air dates, season monitoring |
| **Mixed** | Combined movies and TV shows | Both movie and series features |
| **Music** | Music collections | File scanning only (experimental) |
| **Books** | E-books and audiobooks | File scanning only (experimental) |
| **Adult** | Adult content | File scanning only (experimental) |

!!! warning "Experimental Library Types"
    Music, Books, and Adult libraries are highly experimental with minimal functionality. They support basic library scanning and browsing only - no metadata fetching, download automation, or quality profiles.

## Creating Libraries

### Via Environment Variables

Configure libraries at container startup:

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

| Option | Meaning |
|--------|---------|
| Off (manual only) | Default. Mydia only scans this library when you ask it to. |
| Every 15 minutes | Shortest supported interval. |
| Every hour | |
| Every 6 hours | |
| Every 12 hours | |
| Daily | |

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
libraries. It does not by itself enable automatic scanning.

## Path Management

Mydia uses **relative path storage** for media files:

- **Flexible Relocation** - Change library root paths without breaking file references
- **Path Independence** - Database records are portable
- **Automatic Migration** - Paths convert automatically on upgrade

### Configuration Priority

1. Environment variables (highest)
2. Admin UI (database settings)
3. YAML configuration file
4. Schema defaults (lowest)

## Next Steps

- [Adding Media](adding-media.md) - Import media into your libraries
- [Quality Profiles](quality-profiles.md) - Configure download quality
