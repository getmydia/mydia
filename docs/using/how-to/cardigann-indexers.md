# Cardigann Indexers

Mydia includes built-in Cardigann indexer support, allowing direct indexer connections without Prowlarr or Jackett.

!!! warning "Experimental Feature"
    Cardigann support is highly experimental. Only a limited number of indexers have been tested. If you encounter issues, please report them on GitHub.

## What is Cardigann?

Cardigann is a generic indexer definition format that describes how to interact with torrent/usenet indexers. It was originally developed for Jackett and is now used by Prowlarr as well.

Mydia includes a native Cardigann implementation, allowing you to use hundreds of indexers directly without running a separate indexer manager.

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
- RARBG (mirrors)
- YTS
- And others...

**Untested but Included:**

Many more indexer definitions are included but haven't been verified. They may work, have issues, or not work at all.

## Configuration

### Adding a Cardigann Indexer

1. Navigate to **Admin > Indexers**
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

### When to Use Prowlarr/Jackett

Consider using Prowlarr or Jackett instead if:

- You need more reliable indexer support
- You require specific indexers that don't work with Cardigann
- You want centralized indexer management
- You need advanced features like sync

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

## Architecture

For technical details about the Cardigann implementation, see the [Cardigann Architecture](https://github.com/getmydia/mydia/blob/master/docs/CARDIGANN_ARCHITECTURE.md) documentation.
