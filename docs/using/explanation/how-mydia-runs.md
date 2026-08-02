# How Mydia Runs

Mydia is one process, with one database, managing one library. Nearly every
operational question about it follows from that sentence: why SQLite is the
default, why PostgreSQL is offered anyway, why there is no clustering story, and
how much hardware any of it needs.

This page explains that shape and its limits. For the mechanics of running
PostgreSQL, see the [PostgreSQL how-to](../how-to/postgresql.md); for the
database's own reference material, see the
[database reference](../reference/database.md).

## One instance, on purpose

Mydia is designed to run as a single instance. Not "single instance for now",
and not "single instance until you outgrow it": the workload does not want to be
distributed, and distributing it costs more than it returns.

The reason is that Mydia's work is mostly stateful, mostly serialised, and
mostly not user-facing. Scanning a library directory, polling download clients,
importing a finished download, and refreshing metadata are all jobs where running
two copies concurrently is worse than running one. Two instances scanning the
same directory race each other into the same rows. Two instances polling the
same download client double the API load for no additional information. Two
instances refreshing metadata double the request volume against a shared,
rate-limited service.

That last point generalises. Several of Mydia's rate limiters (for indexers, for
debrid providers, for pairing attempts, for API keys) are in-memory and
per-process. Running two instances does not halve each one's budget; it doubles
the aggregate rate against services that will notice. The most likely outcome of
horizontally scaling Mydia is getting rate-limited by your indexer, which is a
worse problem than the one you were trying to solve.

The user-facing half has the same shape from the other direction. The web
interface is Phoenix LiveView, so a browser holds a stateful WebSocket to one
process, and real-time updates are broadcast in-process. Two instances would
need session affinity to keep a connection pinned, and would need their
broadcasts bridged so that an import completing on one instance updated a page
open on the other. Both are solvable; neither is solved today, and solving them
buys throughput that a media manager does not need.

**So: high availability is not supported.** Not discouraged, not undocumented:
not built. If you put two Mydia instances behind a load balancer you will get
duplicated background work, split rate limiting, and stale pages. The correct
availability strategy for Mydia is a
[good backup](../how-to/backup-restore.md) and a fast restart, which for a
single container is very fast indeed.

The honest defence of this position is that the failure it protects against
barely exists. A media manager being down for the ninety seconds a container
takes to restart means a scheduled search runs ninety seconds late. There is no
transaction to lose and no customer to disappoint.

## SQLite is the default because it needs nothing

Mydia defaults to SQLite, and the reason is a design principle rather than a
performance one: a self-hosted application should work without the operator
having to stand up supporting infrastructure. SQLite is a file. It needs no
container, no credentials, no health check, no ordering constraint at startup,
and no separate backup procedure. Copying it copies the whole database.

For the workload described above, this is not a compromise. Mydia's database is
small (metadata and file references, not media), its write pattern is bursty
rather than sustained, and its read pattern is dominated by page loads that a
local file serves faster than any network round trip could.

Where SQLite's ceiling actually is: **one writer at a time**. Reads run
concurrently, and Mydia runs in write-ahead-log mode so readers are not blocked
by the writer, but writes serialise. In practice the thing that reaches this
ceiling is not user traffic; it is a large library scan writing thousands of rows
while download monitoring and metadata refreshes want to write too. Mydia
compensates with a generous busy timeout so contending writers wait rather than
error, and the default connection pool is small (five) because a larger pool
would only queue more writers against the same single write lock.

If you are hitting that ceiling, the symptom is a slow scan, not a broken
application.

## When PostgreSQL earns its keep

PostgreSQL is a first-class target, not a fallback or an experiment. It runs in
continuous integration alongside SQLite, migrations are written to work on both,
and the code is not permitted to branch on which one is in use. Choosing it is a
legitimate choice, not a warranty-voiding one.

It earns its keep in three situations:

**You already run PostgreSQL.** This is the most common good reason and the least
interesting one. If you have a database server with backups, monitoring, and
retention already solved, adding one more database to it is less operational work
than managing a new SQLite file, not more. The infrastructure argument for SQLite
evaporates when the infrastructure already exists.

**Your storage is a network filesystem.** SQLite's locking is only as reliable as
the filesystem's locking, and NFS and SMB have a long and unhappy history here.
If the database file cannot live on local storage, use PostgreSQL. This is less a
performance argument than a correctness one.

**Write contention is genuinely hurting.** Very large libraries with frequent
scheduled scans, or several people actively using the interface while background
work runs, can produce enough concurrent write pressure to notice. PostgreSQL
handles concurrent writers properly, and its default connection pool is
correspondingly larger (ten rather than five) because a larger pool now buys
parallelism instead of just queueing.

Notably absent from that list: horizontal scaling. PostgreSQL removes the
database from the list of reasons you cannot run two instances, but it does not
address any of the other reasons in the previous section. Choosing PostgreSQL
because you intend to scale out is choosing it for the one benefit it does not
deliver here.

The cost side is straightforward and should be weighed honestly. PostgreSQL adds
a service that must be running before Mydia starts, credentials to manage, its
own backup procedure, and its own upgrade path. The database adapter is compiled
into the image, so SQLite and PostgreSQL ship as separate images and cannot be
swapped at runtime, and there is no automated migration between them. Moving from
one to the other later is real work; it is worth deciding once, early, rather
than assuming you can defer it cheaply.

## Sizing a deployment

The useful way to think about Mydia's resource use is to separate the three
things that consume it, because they scale on completely different axes.

**Steady-state serving is cheap and roughly flat.** A running Mydia with nothing
happening is a web server, a job scheduler, and some polling. Its memory does not
grow meaningfully with library size, because the interface pages through data
rather than holding collections in memory, and the database holds the rest. A
library of ten thousand items does not cost ten times a library of one thousand
at rest.

**Background work scales with library size and is I/O-bound.** Scanning walks
directories, reads file headers, and writes rows; importing hardlinks or copies
files; metadata refresh makes HTTP requests. These are dominated by disk and
network, not CPU, and they are the reason database storage speed matters more
than CPU speed for most installs. Putting the database on an SSD is the single
highest-value hardware choice available, and it matters more than adding cores.

**Transcoding is the one genuinely expensive thing, and it is optional.**
Preparing media for the player app means running ffmpeg, which will use every
core you give it for as long as it runs. If you transcode, transcoding dominates
your sizing and nothing else comes close. If you do not, Mydia is a modest
application that runs comfortably on hardware you would otherwise describe as
inadequate.

The practical consequence is that the usual sizing question ("how much RAM per
thousand items?") is the wrong question. Mydia's baseline is small and does not
grow much. What varies is whether you scan frequently, how fast your storage is,
and whether you transcode. Size for those.

One thing that does not vary: the library filesystem and the download
directory want to be the same filesystem, so imports can hardlink rather than
copy. That is a layout decision made when you set up your volumes, and it is
awkward to change afterwards. See
[how a title becomes a file](media-pipeline.md#where-it-stalls) for why.

## Where to go next

- [PostgreSQL how-to](../how-to/postgresql.md) for running it.
- [Database reference](../reference/database.md) for locations and version
  support.
- [Backing up and restoring](../how-to/backup-restore.md), which is Mydia's
  actual availability story.
- [Why configuration is layered](configuration-model.md) for how a deployment
  describes itself.
