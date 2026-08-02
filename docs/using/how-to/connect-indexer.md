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

Mydia also includes built-in [Cardigann](cardigann-indexers.md) indexer support for connecting to indexers directly, without Prowlarr or Jackett.

See [Indexers Reference](../reference/indexers.md#configuration-fields) for the full list of Admin UI configuration fields.

## Indexer Priority

Every enabled indexer is searched concurrently on every query, and the results are aggregated and deduplicated into one pool. The **Priority** field on an indexer orders the indexer list; it does not make an indexer's results rank higher or arrive sooner.

To stop an indexer influencing results, disable it. To change which release wins, adjust the [quality profile](quality-profiles.md). See [How a Title Becomes a File](../explanation/media-pipeline.md#indexer-priority-does-not-do-what-its-name-suggests) for the details.

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
