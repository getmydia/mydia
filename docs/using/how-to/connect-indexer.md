# Indexers

Indexers provide search capabilities for finding media releases. Mydia supports Prowlarr, Jackett, and built-in Cardigann indexers.

See [Indexers](../reference/indexers.md) for the full list of supported indexer types.

## Prowlarr (Recommended)

Prowlarr is an indexer manager that aggregates multiple indexers into a single API.

### Setup

1. Navigate to **Admin > Indexers**
2. Click **Add Indexer**
3. Select **Prowlarr**
4. Enter connection details:
   - Base URL: `http://prowlarr:9696`
   - API Key: Your Prowlarr API key
5. Test connection
6. Save

### Environment Variables

Every indexer variable is listed in [Environment variables](../reference/environment-variables.md#indexers).

## Jackett

Jackett is an alternative indexer proxy.

### Setup

1. Navigate to **Admin > Indexers**
2. Click **Add Indexer**
3. Select **Jackett**
4. Enter connection details:
   - Base URL: `http://jackett:9117`
   - API Key: Your Jackett API key
5. Test connection
6. Save

### Environment Variables

Every indexer variable is listed in [Environment variables](../reference/environment-variables.md#indexers).

## NZBHydra2

NZBHydra2 is a meta search aggregator for NZB indexers.

### Setup

1. Navigate to **Admin > Indexers**
2. Click **Add Indexer**
3. Select **NZBHydra2**
4. Enter connection details:
   - Base URL: `http://nzbhydra2:5076`
   - API Key: Your NZBHydra2 API key
5. Test connection
6. Save

### Environment Variables

Every indexer variable is listed in [Environment variables](../reference/environment-variables.md#indexers).

## Cardigann (Experimental)

Mydia includes built-in Cardigann indexer support, allowing direct indexer connections without Prowlarr or Jackett.

!!! warning "Experimental Feature"
    Cardigann support is highly experimental. Only a limited number of indexers have been tested. Report issues on GitHub.

### Enable Cardigann

Set environment variable:

```bash
ENABLE_CARDIGANN=true
```

### Configuration

Cardigann indexers are configured through the Admin UI with their specific settings.

## Configuration Options

| Option | Description | Example |
|--------|-------------|---------|
| Name | Display name | `Prowlarr` |
| Type | Indexer type | `prowlarr` |
| Base URL | Indexer URL | `http://prowlarr:9696` |
| API Key | Authentication key | `abc123` |
| Enabled | Enable/disable | `true` |
| Priority | Search priority | `1` |
| Indexer IDs | Specific indexers | `1,2,3` |
| Categories | Content categories | `movies,tv` |
| Rate Limit | Requests per second | `5` |

## Indexer Priority

When multiple indexers are configured:

- Higher priority indexers are searched first
- Results are aggregated from all enabled indexers
- Duplicate results are deduplicated

## Categories

Filter indexers by content category:

- `movies` - Movie content
- `tv` - TV show content
- `music` - Music content (experimental)
- `books` - Book content (experimental)

## Rate Limiting

Configure rate limits to prevent being blocked:

- Set requests per second
- Mydia automatically throttles requests

## Next Steps

- [Quality Profiles](quality-profiles.md) - Configure download preferences
- [Environment Variables](../reference/environment-variables.md) - All configuration options
