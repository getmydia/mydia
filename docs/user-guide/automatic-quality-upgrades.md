# Automatic Quality Upgrades

Mydia can quietly replace a movie or episode file you already have with a
better one, without you having to notice the file was ever lacking. This page
explains what the feature does, how to tune it, and what it means for your
disk.

## What it does

Once a day, Mydia scans your library for files that score below the cutoff
set on their quality profile. For every file below cutoff, it searches your
indexers for a better release. If a candidate scores enough higher than the
current file, Mydia grabs it, imports it alongside the original, and only
once the new file has been analyzed does it decide for real which copy to
keep. The loser is trashed automatically.

Because scanning the whole library every day would mean sending a large
batch of searches to your indexers, the daily scan (Mydia calls this the
"sweep") is bounded and paced. Each run alternates between leading with
movies or episodes, so neither type is permanently starved by the other, and
it stops once it hits its search budget for the day rather than working
through your entire library at once.

Episodes are handled a little differently from movies. If at least 70% of a
season's episodes are below cutoff, Mydia searches for a season pack instead
of searching every episode individually, since one pack search covers the
whole season at a fraction of the indexer cost.

## Turning it on for a profile

Automatic upgrades are controlled per quality profile, not globally. Open
**Admin > Quality Profiles**, edit a profile, and look for **Allow automatic
quality upgrades** on the Basic tab. This is checked by default on new
profiles, but the built-in profiles Mydia ships with are not all the same:
only **Any** and **SD** have it on out of the box. The other six
(**HD-720p**, **HD-1080p**, **Full HD**, **Remux-1080p**, **4K/UHD**, and
**Remux-2160p**) ship with it off. If you're using one of those and expect
upgrades to already be running, open the profile and check the box
yourself.

Two more fields on that same tab control how aggressive the upgrades are:

- **Upgrade cutoff score** - files scoring below this are eligible for an
  automatic upgrade. Setting it near 100 means almost nothing will ever be
  good enough, which keeps the sweep searching for that item indefinitely.
  85 is a reasonable starting point.
- **Minimum upgrade margin** - how much higher a candidate release's score
  must be than the current file's score before it counts as a real upgrade.
  This keeps the sweep from replacing a file for a one-point difference that
  is not a meaningful improvement.

Only movies and episodes that use a profile with automatic upgrades enabled
are ever considered by the sweep.

## Pacing the sweep

Two settings control the sweep itself. Neither one has an Admin UI control
yet, so set them through an environment variable or `config/config.yml`:

| Environment variable | Default | What it does |
|----------------------|---------|--------------|
| `UPGRADE_SWEEP_ENABLED` | `true` | Master switch for the daily sweep. Set to `false` to stop automatic upgrades from running at all, without having to disable the checkbox on every profile. |
| `UPGRADE_SWEEP_BATCH_SIZE` | `50` | The maximum number of indexer searches a single sweep run may cost. |

The same two settings can be set in `config/config.yml` instead, nested
under `upgrades:`:

```yaml
upgrades:
  sweep_enabled: true
  sweep_batch_size: 10
```

The batch size counts indexer searches, not items. A season pack search
covers an entire season for the cost of one search, so the number of files
actually re-evaluated in a run can be higher than the batch size suggests.
Either way, the budget exists to protect your indexer accounts: searching a
large library every day is exactly the kind of activity that gets a
self-hoster rate-limited or banned from a private tracker, so keep this
number modest rather than raising it to "cover everything in one run."

## What it means for your disk

This is the part most likely to catch you off guard: an upgrade in progress
holds **both** copies of a file at once. The new file has to be downloaded
and imported before Mydia can compare it against the one it might replace,
so for a while your library (and your disk) is holding the original and its
replacement simultaneously.

Once Mydia decides the new file wins, the old one is not deleted right
away. It is moved to trash, which takes it out of your library listings,
for the retention window configured by `trash_retention_days` (30 days by
default). Be aware that today, the file itself stays on disk through and
past that window: the trash cleanup job clears the record after the
retention period, but does not currently free the underlying disk space
([tracked in #295](https://github.com/getmydia/mydia/issues/295)). In
practice, every automatic upgrade you accept adds to your disk usage, and
that space is not reclaimed automatically. If you have a lot of files
sitting below your cutoff score when you first turn this on, expect disk
usage to grow steadily and stay grown until you clean up the superseded
files yourself.

Since none of that space comes back on its own, `upgrade_sweep_batch_size`
is your main lever: lowering it spreads the upgrades (and the disk growth
that comes with them) out over more days instead of letting one large first
sweep replace everything at once.

The one upside is that a replaced file is not gone the moment it is
replaced. For the full retention window, the original file is sitting in
trash, out of your library listings but not deleted, so a mistaken upgrade
can still be recovered during that period.

## Next Steps

- [Quality Profiles](quality-profiles.md) - configure cutoff scores, upgrade
  margins, and the per-profile upgrade checkbox
- [Indexers](indexers.md) - set up the sources the sweep searches against
