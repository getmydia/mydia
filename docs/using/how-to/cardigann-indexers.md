# Cardigann Indexers

Mydia includes built-in Cardigann indexer support, allowing direct indexer connections without Prowlarr or Jackett.

!!! warning "Experimental Feature"
    Cardigann support is highly experimental. Only a limited number of indexers have been tested. If you encounter issues, please report them on GitHub.

Cardigann is the community indexer definition format from Jackett, also used by
Prowlarr. Mydia reads those definitions natively, so you can point it at trackers
without running a separate indexer manager.

For why Mydia ships its own engine and what that trades away, see
[Why Mydia ships its own indexer implementation](../explanation/media-pipeline.md#why-mydia-ships-its-own-indexer-implementation).
The short version: use Prowlarr or Jackett when reliability matters more than
running fewer services.

## Enabling Cardigann

Cardigann is enabled by default:

```bash
ENABLE_CARDIGANN=true
```

To disable:

```bash
ENABLE_CARDIGANN=false
```

## Supported Indexers

Mydia includes definitions for many popular indexers. However, only a subset have been thoroughly tested.

**Tested Indexers:**

- 1337x
- YTS

**Untested but Included:**

Many more indexer definitions are included but haven't been verified. They may work, have issues, or not work at all.

## Configuration

### Adding a Cardigann Indexer

1. Navigate to **Admin > Configuration**, then the **Indexers** tab
2. Click **Add Indexer**
3. Select the indexer from the Cardigann list
4. Enter required credentials (if applicable)
5. Test and save

### Indexer Settings

Each indexer may have specific settings:

- Username/Password
- API Key
- Cookie authentication
- Site-specific options

Refer to the indexer's requirements in the Admin UI.

## FlareSolverr Integration

Some indexer sites are protected by Cloudflare or similar anti-bot services. You can use [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) to bypass these challenges automatically.

### Setup

1. Run a FlareSolverr instance (e.g., via Docker)
2. Configure the following environment variables:

```bash
FLARESOLVERR_URL=http://flaresolverr:8191
# FLARESOLVERR_ENABLED is auto-enabled when URL is set
# FLARESOLVERR_TIMEOUT=60000
# FLARESOLVERR_MAX_TIMEOUT=120000
```

See [Environment Variables](../reference/environment-variables.md#flaresolverr) for the full reference.

## Limitations

### Known Issues

- Some indexers may not parse results correctly
- Authentication may fail on some sites
- Rate limiting varies by indexer
- CAPTCHA challenges not supported

## Troubleshooting

### Search Returns No Results

1. Test the indexer connection
2. Check if the site is accessible
3. Verify credentials if required
4. Check application logs for errors

### Authentication Errors

1. Verify credentials are correct
2. Some sites require manual cookie refresh
3. Check if site requires 2FA (not supported)

### Rate Limiting

1. Reduce search frequency
2. Add delay between requests
3. Consider using fewer indexers

## Reporting Issues

When reporting Cardigann issues:

1. Include the indexer name
2. Describe the expected vs. actual behavior
3. Include relevant log entries
4. Specify if it works with Prowlarr/Jackett

## Next Steps

- [Indexers](connect-indexer.md) - Prowlarr, Jackett, and NZBHydra2 setup
- [How a Title Becomes a File](../explanation/media-pipeline.md#why-mydia-ships-its-own-indexer-implementation) - Why Mydia has a native Cardigann engine at all, and what it trades away
