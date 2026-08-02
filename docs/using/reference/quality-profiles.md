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

Only **Any** and **SD** ship with automatic upgrades allowed; the other six have it switched off, so a library on one of those profiles will never upgrade a file until you enable it yourself. See [Upgrade Rules](#upgrade-rules).

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

Unlike the built-in profiles, presets ship with automatic upgrades **allowed**, except **Storage - Compact** and **Use Case - Mobile**, which are size-constrained by intent and have it switched off.

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

Three fields, all on the profile's **Basic** tab, control automatic quality upgrades for every item using the profile.

| Field | Schema field | Default | Meaning |
|-------|--------------|---------|---------|
| Allow automatic quality upgrades | `upgrades_allowed` | `true` on new profiles | Whether items on this profile are considered for upgrades at all. When off, the daily sweep skips them regardless of the two fields below |
| Upgrade cutoff score | `upgrade_until_score` | `85` | Integer 0 to 100. A file scoring **below** this is eligible for an upgrade search; a file at or above it is left alone. Near 100 means almost nothing is ever good enough, so the sweep keeps searching for that item indefinitely |
| Minimum upgrade margin | `min_upgrade_margin` | `5` | Integer 0 to 100. How many points higher the replacement must score before it is accepted. `0` means "any genuine improvement"; an exact tie is never an upgrade, at any margin |

Both scores are the profile's **quality score**, the weighted blend of the preference lists above on a 0 to 100 scale. It is not the ranking score used to order search results, which mixes in seeders and title relevance. See [Why Mydia Picked That Release](../explanation/quality-decisions.md#the-upgrade-score-is-not-the-ranking-score).

There is no per-profile upgrade delay, and no per-format upgrade scoring. Pacing for the daily sweep is instance-wide rather than per profile: see [Automatic Quality Upgrades](../how-to/automatic-quality-upgrades.md#pacing-the-sweep).

!!! note "Legacy exports"
    Profiles exported before the cutoff score existed carry an `upgrade_until_quality` resolution instead. Importing one translates it to a score (`480p` to 40, `576p` to 45, `720p` to 60, `1080p` to 85, `2160p` to 95, anything unrecognised to 85). The field itself no longer exists on a profile.

## Profile Metadata

Alongside the quality fields, a profile carries a `name` (required and unique), an optional `description`, and import and export bookkeeping: `version`, `source_url`, and `last_synced_at`. Profiles seeded by Mydia are flagged as system profiles.
