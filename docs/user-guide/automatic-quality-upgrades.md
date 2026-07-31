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

Episodes are handled a little differently from movies. If most of a season
is below cutoff, Mydia searches for a season pack instead of searching every
episode individually, since one pack search covers the whole season at a
fraction of the indexer cost.

## Turning it on for a profile

Automatic upgrades are controlled per quality profile, not globally. Open
**Admin > Quality Profiles**, edit a profile, and look for **Allow automatic
quality upgrades** on the Basic tab. This is checked by default on new
profiles.

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

Two settings control the sweep itself, both set through an environment
variable or `config/config.yml` rather than the Admin UI:

| Setting | Environment variable | Default | What it does |
|---------|----------------------|---------|--------------|
| `upgrade_sweep_enabled` | `UPGRADE_SWEEP_ENABLED` | `true` | Master switch for the daily sweep. Set to `false` to stop automatic upgrades from running at all, without having to disable the checkbox on every profile. |
| `upgrade_sweep_batch_size` | `UPGRADE_SWEEP_BATCH_SIZE` | `50` | The maximum number of indexer searches a single sweep run may cost. |

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

Once Mydia decides the new file wins, the old one is not deleted right away.
It is moved to trash and kept there for the retention window configured by
`trash_retention_days` (30 days by default) before the trash cleanup job
permanently removes it. If you have a lot of files sitting below your
cutoff score when you first turn this on, the first several sweeps can grow
your disk usage noticeably before that trash starts clearing out.

If this is a concern, lower `upgrade_sweep_batch_size` so the library is
upgraded gradually instead of all at once, which keeps the number of files
sitting in "both copies held" or "in trash" state small at any given time.

The upside of that retention window is that a replaced file is not gone the
moment it is replaced. If an upgrade turns out to be a mistake, the
superseded file is still sitting in trash and recoverable for the full
retention period, not permanently deleted the instant a new file is
imported.

## Next Steps

- [Quality Profiles](quality-profiles.md) - configure cutoff scores, upgrade
  margins, and the per-profile upgrade checkbox
- [Indexers](indexers.md) - set up the sources the sweep searches against
