# Quality Profiles

Quality profiles define your preferences for media quality, including resolution, codecs, file size, and sources.

## Built-in Profiles

Mydia includes 8 built-in profiles:

| Profile | Resolution | Use Case |
|---------|------------|----------|
| SD | 480p | Low bandwidth, small storage |
| HD-720p | 720p | Balanced quality/size |
| HD-1080p | 1080p | Standard HD |
| Ultra-HD | 2160p | 4K content |
| WEB-DL-1080p | 1080p | Streaming sources |
| Bluray-1080p | 1080p | Disc quality |
| Remux-1080p | 1080p | Lossless disc rip |
| Remux-2160p | 2160p | 4K lossless |

## Preset Gallery

The preset gallery offers 23 one-click import profiles:

### TRaSH Guides

Community-vetted profiles following [TRaSH Guides](https://trash-guides.info/) recommendations:

- HD Bluray + WEB
- UHD Bluray + WEB
- Remux + WEB

### Profilarr/Dictionarry

Quality tiers for different use cases:

- **Quality** - Best possible quality
- **Balanced** - Quality vs. size tradeoff
- **Efficient** - Good quality, smaller files
- **Compact** - Minimal storage usage
- **Remux** - Lossless quality

Available for 720p, 1080p, and 2160p resolutions.

### Storage & Use-Case Profiles

- Storage-optimized
- Streaming-optimized
- Mobile-optimized

## Profile Configuration

### Resolution Filtering

Set minimum and maximum resolution:

- Minimum: Reject releases below this resolution
- Maximum: Reject releases above this resolution

### File Size Limits

Configure per-minute file size limits:

- Minimum: Reject undersized files (likely low quality)
- Maximum: Reject oversized files (storage constraints)

### Source Preferences

Rank your preferred sources:

1. Bluray
2. WEB-DL
3. WEBRip
4. HDTV
5. DVD

### Codec Preferences

Configure video codec preferences:

- x265/HEVC - Better compression, smaller files
- x264/AVC - Wider compatibility
- AV1 - Newest codec, best compression

### HDR Preferences

Configure HDR format handling:

- Dolby Vision
- HDR10+
- HDR10
- HLG

### Upgrade Rules

Configure automatic upgrades:

- Enable/disable automatic upgrades
- Set score threshold for upgrades
- Configure upgrade delay

## Creating Custom Profiles

1. Navigate to **Admin > Quality Profiles**
2. Click **Create Profile**
3. Configure settings
4. Save profile

## Assigning Profiles

Profiles can be assigned:

- Per library (default profile)
- Per media item (override)

## Next Steps

- [Download Clients](connect-download-client.md) - Configure download automation
- [Indexers](connect-indexer.md) - Set up release searching
