# How a Title Becomes a File

Between "add this movie" and "the file is in my library" there are about seven
distinct steps, run by different parts of Mydia, mostly in the background, and
mostly invisible. When something goes wrong the symptom is almost always the
same ("nothing happened"), and which of the seven steps stopped is the only
question that matters.

This page explains the shape of that pipeline: what each stage is responsible
for, why indexers and download clients are separate concepts, and where things
realistically stall. It does not explain how the best release is chosen from a
list of candidates; that has its own page,
[why Mydia picked that release](quality-decisions.md).

## The stages

**Search.** Mydia turns a media item into one or more indexer queries. This is
triggered when you add something monitored, on a schedule for monitored items
that still have no file, and on demand when you ask for it. Those schedules skip
anything that already has a file. A separate, slower daily sweep searches on
behalf of files that *do* exist but score below their profile's upgrade cutoff;
see [how upgrades are decided](quality-decisions.md#how-upgrades-are-decided).

**Indexer query.** Every enabled indexer is queried, and the results are pooled.
Indexers are search engines: they know what releases exist and where to get the
`.torrent` or `.nzb`, and nothing else. They do not download anything.

**Release selection.** The pooled results are deduplicated, filtered, ranked
against the item's quality profile, and one is chosen. This is the stage people
mean when they ask why Mydia grabbed a particular file.

**Handoff to a download client.** Mydia fetches the torrent or NZB payload,
picks a client that can accept that protocol, and hands it over. From this point
Mydia is an observer, not a participant: the client does the transferring.

**Monitoring and completion.** A background job polls the clients, tracks
progress, and notices when something finishes, fails, stalls, or disappears from
the client entirely.

**Import.** A completed download is matched back to the media item it was
grabbed for, its files are analysed, samples and junk are discarded, and the
real media files are placed into the library under Mydia's naming scheme.

**The library.** The file is now a first-class record with metadata attached,
and the item stops being searched for a missing file. If it lands below its
profile's upgrade cutoff it stays in scope for the upgrade sweep, which is the
one way a completed item re-enters this pipeline.

## Why indexers and download clients are separate

They look like two halves of one feature and they are configured next to each
other, but they are separate because they fail separately and they are owned by
separate people.

An indexer is a search API. It is usually a shared service (Prowlarr or Jackett
in front of a set of trackers, or a Cardigann definition talking to a site
directly), it is rate-limited, it can be down, and when it is down the symptom
is "no results". A download client is a transfer daemon. It runs on your
hardware or your account, it has disk and bandwidth, and when it is broken the
symptom is "results, a grab, and then nothing moves".

Keeping them apart is what lets Mydia be honest about which one failed. It is
also what lets one indexer's outage not take the others down: indexers are
queried concurrently and independently, and an indexer that errors contributes
an error to the result rather than aborting the search.

## Indexer priority does not do what its name suggests

Both indexers and download clients have a **Priority** field, and they mean
quite different things.

Indexers are queried **concurrently**, all of them, every time. Every enabled
indexer gets the same query at the same time, the results are merged into one
pool, and duplicates are collapsed. There is no first-indexer-wins short
circuit, and an indexer's priority number does not make its results rank higher
or arrive sooner. In the current implementation the field orders the indexer
list for display and nothing else.

That is worth stating plainly because it is a reasonable thing to assume
otherwise, and because tuning a number that does not do anything is a waste of an
evening. If you want an indexer to stop influencing results, disable it; if you
want its results to win, that is a job for the
[quality profile](quality-decisions.md), not for priority.

Deduplication is the part of this stage that actually decides between indexers.
When the same release comes back from three sites, Mydia keeps one copy, and the
copy it keeps is the one reporting the most seeders and the most complete
metadata. So an indexer with better metadata effectively does win ties, just not
through the priority field.

## Download client priority, and its one sharp edge

Client priority is real. When a release is ready to grab, Mydia filters the
enabled clients down to those that can handle the release's protocol (a torrent
cannot go to a Usenet client) and picks the one with the **lowest** priority
number. Priority 1 is tried before priority 2. This follows the *arr convention,
where priority is a rank rather than a weight.

The sharp edge: there is no automatic failover. Mydia selects one client and
hands the release to it. If that client refuses the release or is unreachable,
the grab fails and surfaces as an error; it is not retried against the next
client down the list. Priority chooses a client, it does not describe a fallback
chain.

That is a deliberate limitation rather than a bug, but it is one worth knowing
about, because "I have a backup client configured" does not mean what it looks
like it means. If your primary client is unhealthy, grabs fail until you disable
it or fix it.

## Why Mydia ships its own indexer implementation

Prowlarr and Jackett both exist, both work, and Mydia supports both. Running a
third implementation of the same idea needs a reason.

The reason is the same one behind most of Mydia's design: a self-hosted install
should not require a second and third service to be useful. Cardigann is the
indexer definition format Jackett invented and Prowlarr adopted, and the
definitions themselves are community-maintained YAML files describing how to
query and parse a given site. Those definitions are the valuable part, not the
process that reads them. Mydia includes a native Cardigann engine and syncs the
definition set directly, so an operator who wants three trackers and nothing
else can have three trackers and nothing else.

The trade-off is honest and unflattering. Prowlarr has years of accumulated
handling for the ways individual sites misbehave, and a much larger set of
people noticing when one breaks. Mydia's implementation covers the common shape
of a definition well and the long tail badly, which is why it is marked
experimental and why the [how-to guide](../how-to/cardigann-indexers.md)
recommends Prowlarr when reliability matters more than service count. Running
Cardigann natively is a way to reduce moving parts, not a claim to have replaced
a mature project.

Sites behind anti-bot challenges are the clearest illustration. Mydia can route
requests through FlareSolverr, which is itself another service, so the operator
who wanted fewer moving parts ends up running one anyway. Some parts of this
problem do not have a self-contained answer.

## Where it stalls

Four places, in roughly descending order of how often they are the real cause.

**Nothing was found.** The search ran, the indexers answered, and either nothing
came back or everything that came back was rejected. This is the most common
outcome by a wide margin and the least visible one, because "no results" and "no
search happened" look identical from the outside. The
[release selection page](quality-decisions.md) covers why a result that looks
fine to you can be rejected.

**The grab failed.** A release was chosen but the download client would not take
it, the torrent file could not be fetched from the indexer, or the client was
unreachable. This surfaces as a failed download rather than silence, and, per the
section above, is not retried against a different client.

**The download stalled.** The client accepted the release and then made no
progress. Mydia tracks this with a stall clock that only accrues while the
download is actually being observed, so a client outage or a Mydia restart resets
the baseline rather than counting as a stall. A download that genuinely sits at
the same byte count past its grace window is flagged as a recoverable soft stall,
and only escalates to a real failure (releasing the item to be searched again)
after a longer threshold.

This is deliberately slow to conclude anything. A torrent with no seeders and a
debrid provider still resolving a remote cache look the same for the first
several minutes, which is why debrid clients get a much longer grace window than
local ones. Aggressive stall detection produces confident wrong answers.

**The import failed.** The download completed and the files did not make it into
the library. Usually this is a permissions problem, a path that Mydia and the
download client disagree about, or a release whose contents did not match what
was expected. Import is the stage most sensitive to how the container is mounted,
because it is the only stage that touches both the download directory and the
library directory at once.

That last point is also why the download directory and the library want to be on
the same filesystem. When they are, importing is a hardlink: instant, and it
costs no additional disk, so the file can stay seeding in the client and exist in
the library simultaneously. When they are not, importing is a copy, which takes
time proportional to the file and doubles the space until the client's copy is
removed. Nothing breaks either way, but "my imports are slow and my disk is
full" almost always means a filesystem boundary sits between the two paths.

## Where to go next

- [Why Mydia picked that release](quality-decisions.md) for the selection stage
  in detail.
- [Download clients](../how-to/connect-download-client.md) and
  [indexers](../how-to/connect-indexer.md) for configuring the two ends.
- [Adding media](../how-to/add-media.md) for triggering the pipeline by hand.
