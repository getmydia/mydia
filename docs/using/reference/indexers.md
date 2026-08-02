# Indexers Reference

Complete reference of the indexer types Mydia supports.

| Type | Description | Recommended |
|------|-------------|-------------|
| **Prowlarr** | Indexer manager with unified API | Yes |
| **Jackett** | Indexer proxy | Yes |
| **NZBHydra2** | NZB meta search aggregator | Yes |
| **Cardigann** | Built-in indexer support | Experimental |

## Configuration Fields

These fields appear when adding or editing an indexer in the Admin UI.

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
