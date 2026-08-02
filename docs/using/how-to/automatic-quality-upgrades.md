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
**Admin > Configuration**, go to the **Quality** tab, edit a profile, and look for **Allow automatic
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
  is not a meaningful improvement. Setting it to 0 means "take any genuine
  improvement, however small"; a release that scores exactly the same as
  what you already have is never an upgrade, at any margin.

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
away. It is moved to trash: the file leaves your library folder for a trash
directory, and stays there for the retention window configured by
`trash_retention_days` (30 days by default). When that window expires, the
daily trash cleanup job deletes it for real and the space comes back.

So an upgrade costs you the size of the replaced file for the length of the
retention window, and nothing after that. If you have a lot of files sitting
below your cutoff score when you first turn this on, expect disk usage to
rise for about a month and then level off.

Lowering `upgrades.sweep_batch_size` (`UPGRADE_SWEEP_BATCH_SIZE`) spreads the
upgrades out over more days instead of letting one large first sweep replace
everything at once. The retention window itself is not adjustable from a
container: `trash_retention_days` is compile-time configuration and is not part
of the runtime config schema, so it cannot be set through `config.yml` or an
environment variable.

Nothing is deleted the moment it is replaced. For the full retention window
the original is sitting in the trash directory, out of your library listings
but intact, so a mistaken upgrade can still be undone during that period.
Restoring a file moves it back where it came from.

### Where the trash directory is

By default, Mydia trashes into a `.mydia-trash` folder **beside** each
library folder. A library at `/media/movies` trashes into
`/media/.mydia-trash`.

Two things make that the default. It is outside your library, so a library
scan never finds the trashed file and re-adds it, which is what would undo
the upgrade you just accepted. And it is on the same disk as your media, so
trashing a 60 GB file is an instant rename rather than a slow copy.

Being on the same disk matters more than being outside the folder, because
Mydia's scanner already ignores any folder named `.mydia-trash`. So when the
folder beside your library would land on a **different** disk, Mydia puts the
trash *inside* the library instead, at `<library>/.mydia-trash`. That happens
in two common setups:

- Your library is a mount point itself, such as `/media` or `/data` in
  Docker. The folder beside it would be `/` inside the container, which is
  usually a different filesystem and is often read-only.
- Your library is a network share mounted below a local folder, such as
  `/mnt/media` where `/mnt` is on the system disk.

You do not need to do anything for either case. If you see a `.mydia-trash`
folder appear inside a library, that is why.

You can point all of it somewhere else with the `MYDIA_TRASH_DIR`
environment variable. Two rules if you do, because the automatic handling
above does not apply to a path you chose yourself:

- Pick a directory **outside every one of your library folders**, unless you
  name it `.mydia-trash`. Any other folder inside a library is a folder Mydia
  will scan.
- Pick one on the **same filesystem** as your media. If it is on a different
  mount, Mydia still trashes the file, but it has to copy the whole thing
  and then delete the original, which is slow for large media and briefly
  needs room for both copies. It logs a warning when this happens.

## When an upgrade gets stuck

While an upgrade is in flight, the newly imported file records which file it
is meant to replace. That record clears as soon as Mydia has scored both
copies for real and trashed the loser, which normally happens a minute or two
after import.

If it has not cleared an hour later, the upgrade is wedged and both copies
are still taking up room. **Admin > Configuration > Status** says so at the
top of the page, with a count of the files affected and a link to the jobs
page. Nothing is shown there when the count is zero, so a Status page with no
such warning means nothing is stuck.

Two things cause it, and both leave a trace on **Admin > Jobs**:

- The new file was never analyzed, so the step that finishes the upgrade was
  never queued in the first place. There is no `UpgradeFinalize` job for the
  file at all, and the analysis job for it failed or never ran.
- Analysis succeeded but the finishing step itself failed. There is an
  `UpgradeFinalize` job in the `discarded` or `retryable` state, and its
  **Details** view carries the error that explains why.

Filter the jobs list by state to find them. Nothing is lost while an upgrade
sits in this state: the file you already had is untouched and still playable,
and the replacement is imported alongside it. The cost is disk, and it lasts
until the upgrade finishes or you remove one of the two copies yourself.

## Next Steps

- [Quality Profiles](quality-profiles.md) - configure cutoff scores, upgrade
  margins, and the per-profile upgrade checkbox
- [Connect an indexer](connect-indexer.md) - set up the sources the sweep searches against
