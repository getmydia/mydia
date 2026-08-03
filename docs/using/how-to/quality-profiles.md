# Quality Profiles

Quality profiles define your preferences for media quality, including resolution, codecs, file size, and sources.

See [Quality Profiles](../reference/quality-profiles.md) for the built-in profiles, preset gallery, and the full set of configurable fields.

## Creating Custom Profiles

1. Navigate to **Admin > Configuration**, then the **Quality** tab
2. Click **New**
3. Configure settings
4. Save profile

## Using the Preset Gallery

Instead of building a profile from scratch, click **Browse Presets** on the Quality Profiles page and pick one to import. See [Quality Profiles Reference](../reference/quality-profiles.md#preset-gallery) for the full list of presets.

## Assigning Profiles

Every search resolves a profile through two tiers:

1. **The media item's own profile**, if one is set. This always wins.
2. **The global default profile**, chosen at the top of **Admin > Configuration**, **Quality** tab. It governs every item that has no profile of its own.

Wherever you pick a profile for a media item, the blank choice reads **Use default (name)**. Picking it clears the item's own profile so the item follows the global default, including any later change to that default. Setting a profile on the item instead pins it, and it stops tracking the default.

A fresh install seeds the **Any** profile as the global default, so searches are ranked from the start rather than falling back to raw seeder counts. Changing the default afterwards is never overwritten on restart, and clearing it is respected too.

## Next Steps

- [Automatic quality upgrades](automatic-quality-upgrades.md) - turn on upgrades for a profile and pace the daily sweep
- [Download Clients](connect-download-client.md) - Configure download automation
- [Indexers](connect-indexer.md) - Set up release searching
