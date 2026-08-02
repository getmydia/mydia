# First Steps

After installing Mydia, follow these steps to configure your media management system.

## Initial Admin Setup

When you first access Mydia at `http://localhost:4000`, you'll be guided through creating the initial admin user.

You can either:

- Set a custom password of your choice
- Generate a secure random password that will be displayed once

After the admin user is created, you'll be automatically logged in.

## Configure Download Clients

Navigate to **Admin > Download Clients** to add your download clients.

### Supported Clients

This list highlights common client types. The Admin UI also supports rTorrent, Blackhole, and Debrid clients.

**Torrent Clients:**

- qBittorrent
- Transmission
- rqbit

**Usenet Clients:**

- SABnzbd
- NZBGet

### Example: qBittorrent Setup

1. Click **Add Download Client**
2. Select **qBittorrent** as the type
3. Enter connection details:
   - Host: `qbittorrent` (or your qBittorrent hostname)
   - Port: `8080`
   - Username/Password: Your qBittorrent credentials
4. Click **Test Connection** to verify
5. Click **Save**

## Configure Indexers

Navigate to **Admin > Indexers** to add your indexers.

### Supported Indexers

- **Prowlarr** - Recommended indexer manager
- **Jackett** - Alternative indexer proxy
- **Cardigann** - Built-in indexer support (experimental)

### Example: Prowlarr Setup

1. Click **Add Indexer**
2. Select **Prowlarr** as the type
3. Enter connection details:
   - Base URL: `http://prowlarr:9696`
   - API Key: Your Prowlarr API key
4. Click **Test Connection** to verify
5. Click **Save**

## Set Up Libraries

Mydia automatically creates default libraries based on your `MOVIES_PATH` and `TV_PATH` environment variables.

To add additional libraries or configure existing ones:

1. Navigate to **Admin > Libraries**
2. Configure library paths and settings
3. Trigger a library scan to discover existing media

## Quality Profiles

Mydia includes built-in quality profiles for different use cases:

- **SD** through **Remux-2160p** - 8 built-in profiles
- **Preset Gallery** - 23 one-click imports including TRaSH Guides and Profilarr profiles

To configure quality profiles:

1. Navigate to **Admin > Quality Profiles**
2. Browse the preset gallery or create custom profiles
3. Assign profiles to your libraries

## Next Steps

- [Managing Libraries](../using/how-to/manage-libraries.md) - Detailed library configuration
- [Quality Profiles](../using/how-to/quality-profiles.md) - Profile configuration guide
- [Download Clients](../using/how-to/connect-download-client.md) - Advanced client setup
