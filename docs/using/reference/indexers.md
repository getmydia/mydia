# Indexers Reference

Complete reference of the indexer types Mydia supports.

| Type | Description | Recommended |
|------|-------------|-------------|
| **Prowlarr** | Indexer manager with unified API | Yes |
| **Jackett** | Indexer proxy | Yes |
| **NZBHydra2** | NZB meta search aggregator | Yes |
| **Cardigann** | Built-in indexer support | Experimental |

## Configuration Fields

These fields appear when adding or editing an indexer on **Admin > Configuration**,
under the **Indexers** tab.

| Option | Description | Example |
|--------|-------------|---------|
| Name | Display name | `Prowlarr` |
| Type | Indexer type | `prowlarr` |
| Base URL | Indexer URL | `http://prowlarr:9696` |
| API Key | Authentication key | `abc123` |
| Enabled | Enable or disable this indexer | `true` |
| Priority | Orders the indexer list for display and nothing else, see below | `1` |
| Indexer IDs | Which Prowlarr indexers to query, picked from a checklist after the connection succeeds | `1,2,3` |
| Min post age (minutes) | Usenet only. Drops NZB results posted more recently than this, giving articles time to propagate. Blank disables it. | `30` |

### Priority does not affect searching

Priority is not a search priority. Searches fan out to every enabled indexer
concurrently, the results are merged into one pool, and ranking is done by the
quality profile rather than by which indexer answered. The field only sorts the
indexer list in the admin UI. See
[The Media Pipeline](../explanation/media-pipeline.md#indexer-priority-does-not-do-what-its-name-suggests)
for the full picture, including how download client priority differs.

### Fields with no form input

Two stored fields are used at search time but have no control in the admin form.
Set them with environment variables:

| Field | Environment variable | Effect |
|---|---|---|
| Categories | `INDEXER_<N>_CATEGORIES` | Default category IDs to search within, for Prowlarr and NZBHydra2 |
| Rate Limit | `INDEXER_<N>_RATE_LIMIT` | Maximum requests **per minute** for this indexer. Unset means no limit. |

!!! warning "Rate Limit is per minute, not per second"
    Mydia counts requests in a sliding one-minute window. `5` means five requests a
    minute. Reading it as five per second would let Mydia issue sixty times the
    traffic you intended, which is how indexer bans happen.
