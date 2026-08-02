# Quality Profiles Reference

Complete reference of the built-in and preset quality profiles, and the fields available when configuring a profile.

## Built-in Profiles

Mydia seeds 8 built-in profiles. Sizes are the movie range; episode ranges are roughly half.

| Profile | Preferred resolutions | Preferred sources | Movie size | Use case |
|---------|----------------------|-------------------|------------|----------|
| Any | 360p through 2160p | Any | No limit | Maximum availability |
| SD | 480p, 576p | DVD, DVDRip, SDTV | Up to 2 GB | Low bandwidth, small storage |
| HD-720p | 720p | BluRay, WEB-DL, HDTV | 1 to 5 GB | Balanced quality and size |
| HD-1080p | 1080p | BluRay, WEB-DL | 2 to 15 GB | Standard HD |
| Full HD | 1080p | REMUX, BluRay | 4 to 20 GB | Strict 1080p, high-quality sources only |
| Remux-1080p | 1080p | REMUX | 20 to 40 GB | Lossless disc rip |
| 4K/UHD | 2160p | REMUX, BluRay, WEB-DL | 15 to 80 GB | Ultra HD |
| Remux-2160p | 2160p | REMUX | 40 to 100 GB | Lossless 4K |

Only **Any** and **SD** ship with upgrades allowed; the rest have it switched off. In the current release this makes no difference either way, because nothing reads the upgrade fields. See [Upgrade Rules](#upgrade-rules).

## Preset Gallery

The preset gallery offers 23 one-click import profiles in four families.

### TRaSH Guides

Profiles following [TRaSH Guides](https://trash-guides.info/) recommendations:

- TRaSH - HD Bluray + WEB
- TRaSH - UHD Bluray + WEB
- TRaSH - Remux + WEB 1080p
- TRaSH - Remux + WEB 2160p
- TRaSH - WEB-1080p
- TRaSH - WEB-2160p

These translate the resolution, source, and size parts of the guides. The custom format scoring the guides are built around has no Mydia equivalent; see [Why Mydia Picked That Release](../explanation/quality-decisions.md#there-are-no-custom-formats).

### Profilarr/Dictionarry

Quality tiers, named `Profilarr - <resolution> <tier>`:

- **Quality** - Best possible quality (720p, 1080p, 2160p)
- **Quality HDR** - As above with HDR required (1080p)
- **Balanced** - Quality versus size tradeoff (1080p, 2160p)
- **Efficient** - Good quality, smaller files (1080p, 2160p)
- **Compact** - Minimal storage usage (1080p)
- **Remux** - Lossless quality (1080p, 2160p)

### Storage

- Storage - Archival
- Storage - Balanced
- Storage - Compact

### Use Case

- Use Case - Local Playback
- Use Case - Streaming
- Use Case - Mobile

## Profile Configuration

Every preference list is **priority ordered**: the first entry is the most preferred. Position in the list is what scores, and an attribute that does not appear in the list at all scores worse than one at the bottom of it. See [Why Mydia Picked That Release](../explanation/quality-decisions.md#what-the-score-actually-weighs).

### Resolution

| Field | Meaning |
|-------|---------|
| Preferred resolutions | Priority-ordered list. **Required, and must not be empty.** |
| Minimum resolution | Releases below this zero the quality score |
| Maximum resolution | Releases above this zero the quality score |

Accepted values: `360p`, `480p`, `576p`, `720p`, `1080p`, `2160p`, `4320p`.

**Preferred resolutions is the decisive field in the whole profile.** It is the primary sort key during release selection, ahead of every score, so a release at a resolution you have not listed cannot outrank one you have. If you would accept more than one resolution, list them all in the order you would accept them.

### File Size Limits

Absolute sizes in megabytes, set separately for movies and episodes. These are not per-minute values.

| Field | Meaning |
|-------|---------|
| `movie_min_size_mb` / `movie_max_size_mb` | Size range for a movie release |
| `episode_min_size_mb` / `episode_max_size_mb` | Size range for an episode release |

Sizes outside the range are a capped scoring penalty, not a rejection. A release that is too large or too small sinks in the ranking but remains selectable.

### Source Preferences

Priority-ordered list. Accepted values: `BluRay`, `REMUX`, `WEB-DL`, `WEBRip`, `HDTV`, `SDTV`, `DVD`, `DVDRip`, `BDRip`.

### Codec and Channel Preferences

All three are priority-ordered lists.

| Field | Accepted values |
|-------|-----------------|
| Video codecs | `h264`, `h265`, `hevc`, `x264`, `x265`, `av1`, `vc1`, `mpeg2`, `xvid`, `divx` |
| Audio codecs | `aac`, `ac3`, `eac3`, `dts`, `dts-hd`, `truehd`, `atmos`, `flac`, `mp3`, `opus` |
| Audio channels | `1.0`, `2.0`, `2.1`, `5.1`, `6.1`, `7.1`, `7.1.2`, `7.1.4` |

### HDR Preferences

| Field | Meaning |
|-------|---------|
| HDR formats | Priority-ordered list: `dolby_vision`, `hdr10+`, `hdr10`, `hlg` |
| Require HDR | When set, a release with no HDR zeroes the quality score |

### Torrent Preferences

| Field | Meaning |
|-------|---------|
| Minimum ratio | Minimum seeder-to-leecher ratio. A capped scoring penalty, not a rejection |

Minimum seeders is **not** a profile field. It is an application-level setting that applies to automatic searches, and unlike the fields above it is a hard filter. See [Why Mydia Picked That Release](../explanation/quality-decisions.md#minimum-seeders-is-a-filter-and-the-only-one-you-are-likely-to-set).

### Upgrade Rules

!!! warning "Not currently implemented"
    A profile stores two upgrade fields, and **nothing in the current release reads either of them.** There is no code path that compares a candidate release against a file you already have. An item that has a file is not searched again, whatever its profile says, so no upgrade ever happens. The fields are saved, exported, and imported faithfully; they simply have no effect yet.

| Field | Meaning when implemented |
|-------|--------------------------|
| Upgrades allowed | Whether a better release may replace an existing file |
| Upgrade until quality | The resolution at which upgrading stops |

There is no upgrade score threshold and no upgrade delay setting. For what this means in practice, including how to get a better copy of something you already have, see [Why Mydia Picked That Release](../explanation/quality-decisions.md#there-is-no-upgrade-path-yet).

## Profile Metadata

Alongside the quality fields, a profile carries a `name` (required and unique), an optional `description`, and import and export bookkeeping: `version`, `source_url`, and `last_synced_at`. Profiles seeded by Mydia are flagged as system profiles.
