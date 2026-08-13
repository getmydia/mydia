# Why Mydia Picked That Release

The most common complaint about any quality profile system is some version of
"there was a clearly better release right there and it took the other one". This
page explains how Mydia actually decides, which is not quite how it looks from
the outside, and why the answer is usually one of about five specific things.

For the fields you can set and the profiles that ship with Mydia, see the
[quality profiles reference](../reference/quality-profiles.md). For where
selection sits in the wider flow, see
[how a title becomes a file](media-pipeline.md).

## It is not a single score

The natural mental model is that every release gets a number and the biggest
number wins. Mydia does compute a number, and it is not the thing that decides.

Selection happens in two steps. First, releases are sorted by **which position
their resolution occupies in your profile's preferred resolution list**. Only
within that grouping does the numeric score break ties.

The consequence is blunt and it explains most surprises: a release whose
resolution is not in your preferred list cannot outrank one that is, at any
score, ever. Under a 1080p profile, a 2160p remux with a thousand seeders loses
to a mediocre 1080p WEB-DL. That is working as designed. A profile that names
1080p is read as a statement about what you want, not a floor to be exceeded when
something better shows up.

If you want Mydia to consider more than one resolution, the profile has to name
more than one, in the order you would accept them. This is the single most
consequential setting in the application, and it is the first thing to check when
selection surprises you.

## Two passes, and the first one does not know about your profile

There is a funnel before the profile is ever consulted, and it is easy to miss.

When Mydia queries indexers, it pools every result, drops duplicates, ranks what
is left, and keeps roughly the first hundred. That first ranking runs without a
quality profile, so it falls back to an availability-dominated ordering: seeders,
essentially. Only then does the profile-aware ranking run, on the survivors.

For a normal search this changes nothing, because a normal search does not return
a hundred plausible candidates. For a popular title on a well-stocked set of
indexers it can matter: a low-seeded release of exactly the flavour you asked for
can be cut in the first pass and never reach the stage that would have preferred
it. This is a real limitation of the current implementation rather than a
deliberate policy, and it is worth knowing about when a specific release you can
see on a tracker never appears in Mydia's reasoning.

## Hard rejections versus soft penalties

Most of what a profile expresses is a preference, not a rule, and Mydia
deliberately keeps the two categories small and separate.

A **hard rejection** removes a release from consideration entirely. The list is
short on purpose:

- The release title does not plausibly match the item being searched for. Two
  independent checks apply here: a parsed-title similarity threshold, and a
  relevance score that reaches zero. Alternate and localised titles are the
  usual innocent victims.
- The release fails a validity check: an executable or script extension, a
  hashed or numeric-only title, an apparently password-protected archive, or no
  meaningful content in the name.
- The release is on the blocklist, which is where releases go after a download
  built from them fails.
- A Usenet post is younger than the indexer's configured minimum age.
- The title contains a blocked tag. This one is real but is currently almost
  unreachable; see [below](#blocked-tags-are-not-reachable-from-the-interface).
- The release is a torrent with fewer seeders than the configured minimum. This
  is not a profile field but an application-level setting, and it is the one
  most likely to surprise you; see the next section.

Nearly everything else is a **soft penalty**: it pushes a release down the
ranking instead of removing it. Size outside your configured range, a poor
seeder-to-leecher ratio, and low (but non-zero) seeder counts all work this way,
and those penalties are deliberately capped small enough that they cannot flip a
correct release below an incorrect one. The reasoning is that a search returning
nothing is a worse outcome than a search returning something imperfect, and hard
size filters are extremely good at returning nothing.

### Minimum seeders is a filter, and the only one you are likely to set

Minimum seeders is the exception to the paragraph above, and it behaves
differently from everything else in a quality profile, so it is worth separating
out.

It is applied as a hard filter on the pooled indexer results, before
deduplication and before ranking. A torrent below the threshold is removed, not
demoted. The manual search interface applies the same filter to what it shows
you. Inside the ranker there is *also* a small soft seeder penalty, which is
what leads to the reasonable but wrong assumption that seeders are only ever a
preference.

Two details soften it. The default is zero, so out of the box it filters
nothing, and it only applies to automatic background searches unless you set it
yourself in the manual search interface. And Usenet results, which report no
seeder count at all, are exempt rather than being filtered out wholesale.

#### Setting it

The floor for automatic searches lives in the layered configuration as
`downloads.min_seeders`, so you can set it three ways, in increasing order of
precedence:

- **Settings > Configuration > Downloads** in the web UI, as *Minimum Seeders
  (automatic search)*. This is the usual way and takes effect without a restart.
- `downloads.min_seeders` in `config.yml`.
- The `AUTO_SEARCH_MIN_SEEDERS` environment variable, which wins over both.

The manual search interface keeps its own separate control, which is only ever
applied to the search you are running at the time.

Something to know before you raise it above zero: a few torrent indexers report
zero seeders when they mean "I could not read the seeder count", not "this
torrent is dead". Cardigann definitions do this when their seeders selector does
not match the site's markup, and Jackett does it for an empty field. Any nonzero
floor discards every result from those indexers that has no parsed seeder count,
which looks a lot like an indexer that quietly stopped working. If you set a
floor, check that your indexers still return results.

The practical warning: this is the one setting that can genuinely empty a result
list. If you raised it to filter out dead torrents and searches stopped finding
anything, lower it before investigating anything else.

### Identity mismatch is a penalty, not a rejection

An episode search that matched a season pack or the wrong episode, or a movie
search that matched something with season and episode markers in its name, is an
**identity mismatch**. You would expect that to be a hard rejection. It is not.

It is a very large negative score adjustment, deliberately sized to exceed the
maximum score any release can otherwise achieve, so that a matching release
always outranks a mismatching one while the mismatching one stays selectable.
The design intent is to fail open: if the parser cannot read a release name at
all, no penalty is applied, so unusual naming conventions are not silently
discarded.

There is a consequence to this that is genuinely surprising, and it follows from
the resolution-first sorting described at the top of this page. Because the
resolution grouping is applied *before* scores are compared, a release that
mismatches on identity but sits at a preferred resolution sorts above a release
that matches on identity but sits at a non-preferred one. The enormous penalty
only settles ties within a resolution grouping; it cannot reach across
groupings.

In practice this needs an unusual setup to bite, since a search that only
returns wrong-identity releases at your preferred resolution is already an
unusual search. But if you ever see Mydia grab a season pack for an episode
search, this interaction, rather than a broken matcher, is the likely mechanism.

## What the score actually weighs

Within a resolution grouping, the score is roughly: a quality component worth
about sixty percent, an availability component derived from seeders (or from
completion and grab count for Usenet), and a small title-relevance bonus. A
release with zero seeders takes a flat multiplier against the whole thing.

The quality component is itself a weighted blend of the profile's preference
lists: resolution and video codec carry the most weight, then audio codec, then
audio channels and source, then file size and HDR.

The important detail is how a preference list scores. Position in the list is
what counts, and the gaps are large. Being first in a list scores far better than
being last, and **not appearing in the list at all scores worse than appearing at
the bottom of it**. An attribute Mydia could not determine from the release name
lands in the middle, better than being explicitly unpreferred.

That last rule catches people out. If your preferred video codecs are `h265` then
`h264`, an h264 release is second-best and scores accordingly. If your preferred
codecs list only `h265`, an h264 release is not merely second-best, it is
unlisted, and it takes a substantially larger hit. Short preference lists are
strong statements.

Availability is logarithmic, so seeder counts matter much less than they appear
to. The difference between fifty and five hundred seeders is a handful of points,
comparable to a single codec preference. The one sharp effect is having zero
seeders, which applies a multiplier to the entire score.

## So why did it take that one?

In rough order of how often each is the real cause:

1. **The better release's resolution was not in your preferred list.** Nothing
   else can produce this outcome as reliably. Check the resolution list first.
2. **It was filtered out for having too few seeders.** The only hard filter you
   are likely to have set yourself, and the only one that can empty a list.
3. **It never survived the first pass.** On a busy title, a low-seeded release
   can be cut before the profile is consulted.
4. **It lost the duplicate collapse.** When the same release comes back from
   several indexers, Mydia keeps the copy with the most seeders and the most
   complete metadata, and discards the rest.
5. **Its codec, source, or audio was unlisted rather than merely second.** See
   above; the penalty for absent is larger than for last.
6. **The title did not match closely enough.** Either the parsed title fell below
   the similarity threshold, or a name padded with tags and group suffixes drove
   the relevance score to zero and triggered a hard rejection.
7. **It violated a resolution bound or a required HDR format.** This does not
   remove the release, but it zeroes the entire quality component, which is most
   of the available score.
8. **It was blocklisted** after a previous download built from it failed.

Notice what is not on that list. Indexer priority is not a factor; indexers are
queried concurrently and their priority number does not weight their results.
Size limits are almost never decisive on their own, because they are capped soft
penalties. Blocked tags are not a factor either, because you almost certainly do
not have any set. And "the cutoff was already met" answers a different question
entirely: it decides whether Mydia goes looking for an upgrade at all, rather
than which release wins once it has. See
[how upgrades are decided](#how-upgrades-are-decided).

## Blocked tags are not reachable from the interface

Blocked tags are a real hard rejection: a case-insensitive substring test against
the release title, unanchored, so a short token can match inside a longer word or
a release group name. If you had one set, it would remove releases outright.

You almost certainly do not have one set. There is no field for blocked tags in
the admin interface, no environment variable for them, and no database row that
holds them. The only ways in are a compiled-in application setting overridden in
a release configuration file, or an argument passed to a search job
programmatically. Neither is something an operator does through normal
configuration, and the shipped default is an empty list.

So the mechanism exists and works, and for practical purposes it is not part of
the configuration surface today. It is listed among the hard rejections above for
completeness rather than because it is likely to be your answer. The same is true
of the preferred-tag bonus mentioned later on this page: implemented, reachable
only from job arguments, and empty in a running instance.

## How upgrades are decided

Mydia does replace a file you already have when a better one turns up. It
deserves its own section here, because the decision is made twice, on two
different kinds of evidence, and everything above this point describes only the
first half.

For which settings to change and what the feature costs you in disk, see
[automatic quality upgrades](../how-to/automatic-quality-upgrades.md). This
section is about why it is shaped this way.

### The upgrade score is not the ranking score

The score described further up this page (quality blended with seeders, a
title-relevance bonus, and a flat multiplier for zero seeders) exists to order
candidates against each other. Upgrades never use it. They use the profile's
quality score on its own: the weighted blend of your resolution, codec, audio,
source, size, and HDR preferences on a 0 to 100 scale, with no availability term
in it at all.

That separation is forced rather than chosen. A file sitting on your disk has no
seeders and no indexer behind it, so any number mixing availability in cannot be
compared against one. The two numbers answer different questions, which is why
"the score" means something different in the two halves of this page.

### First decision: a bounded daily sweep

Once a day Mydia looks for files scoring below their profile's **upgrade cutoff
score** and searches for something better. Four conditions gate an item into
that sweep, and each of them is a plausible answer to "why is nothing being
upgraded":

- Its profile has upgrades allowed. This is per profile rather than global, and
  most of the built-in profiles ship with it switched off.
- The item is monitored, and for an episode the show is monitored too.
- It has at least one analyzed, untrashed file. An unanalyzed file has no score,
  and is skipped rather than being treated as maximally upgradeable.
- Nothing is already downloading for it, including a season pack that covers it.

The sweep is deliberately slow. It works oldest-checked-first, stamps each item
at the moment it enqueues a search rather than when the search comes back, and
stops once it has spent its budget of indexer searches for the day. Searches
that keep coming back empty back off, in their own namespace so that an upgrade
search and a missing-file search cannot suppress one another.

All of that pacing exists to protect your indexer accounts. Missing-file
searches only ever touch a small and shrinking set of items, but upgrade-eligible
items can be the entire library, and an instance that queries a private tracker
about every file it owns every night is an instance that gets banned.

Movies cost one search each. Episodes are grouped by season first, and a season
where most episodes are below cutoff is searched as a season pack, since one
pack search covers the season for the price of one. Movies and episodes take
turns leading each run, because a library with more below-cutoff movies than the
daily budget would otherwise leave nothing for episodes on every run, forever.

### The candidate comparison neutralises what it cannot see

At this stage a candidate is a release name and a file is a fully analyzed
artifact, so comparing them directly means comparing unequal evidence. Mydia
handles that symmetrically: a dimension the file does not know is blanked on the
candidate too, and a dimension the release name does not mention inherits the
file's value.

Both halves matter. Without the first, a file whose source was never determined
would score the neutral middle while a candidate advertising "BluRay" scored full
marks, handing every candidate a free win. Without the second, a terse but
accurate release name would be punished for what it did not bother to say.

Everything else on this page still governs which surviving candidate gets
grabbed. The upgrade comparison runs after blocklist rejection and before
ranking, so what it lets through is then ordered by the ordinary rules,
resolution grouping first. A release at a resolution your profile does not list
still cannot win.

### Second decision: the release has to prove it

Nothing is thrown away on the strength of a release name, because release names
lie. The new file is downloaded and imported **alongside** the file it might
replace, and only once it has been analyzed for real is the comparison run
again, this time between two analyzed files scored against the same profile.

Both comparisons apply the same **minimum upgrade margin**, deliberately: the
gate that picks a candidate and the gate that accepts the imported file cannot be
allowed to disagree about what counts as better. The difference is the evidence
each one has. The first works from a release name; the second works from a file
that has been measured.

If the measured file clears the margin, the old file is trashed and the activity
feed records both scores along with the per-dimension difference between them. If
it does not, the *new* file is trashed instead and its release is blocklisted, so
the next sweep does not grab the same lying release again.

Season packs are the one exception to that blocklisting. An episode inside a pack
that was already above cutoff is *supposed* to lose this comparison, so
blocklisting the pack would burn a release that legitimately upgraded the rest of
the season.

Neither file is hard-deleted here. The loser is moved to trash and stays
recoverable for the trash retention window.

### An exact tie is not an upgrade

A margin of zero means "any genuine improvement", not "no improvement required".
A release scoring exactly what you already have is never an upgrade at any
margin, and the reason is a loop rather than a preference: it would be grabbed,
the current file trashed, the replacement would score the same, and the item
would be eligible again tomorrow, indefinitely.

### What this changes elsewhere on this page

Two things above read differently now. "The cutoff was already met" is a real
reason for Mydia not to search, since an item at or above its profile's cutoff
score is never swept. And changing a profile from 720p to 1080p does now cause
files you already have to be re-examined, over the following days rather than at
once, provided the profile allows upgrades and those files fall below its
cutoff.

PROPER and REPACK markers are still not scored. A PROPER replaces the release it
corrects only if it happens to score higher on the profile dimensions above,
which is not what the marker is for.

## There are no custom formats

Radarr and Sonarr let you define named custom formats with individual scores:
release groups you trust, audio formats you want, encoders you avoid, each
contributing points to a total. That model is the main reason the *arr stack's
quality handling is more expressive than Mydia's, and it is genuinely more
expressive.

Mydia has three term-based mechanisms and none of them is a custom format. Only
one of the three is configurable: resolution, codec, source, audio, and HDR
preferences are ordered lists scored by position. The other two, blocked tags
and a preferred-tag bonus, are implemented in the ranking code and not reachable
from the interface, as described above.

PROPER and REPACK markers are parsed out of release names and are then not used
for scoring. A PROPER does not currently rank above the release it corrects.

This is a real capability gap, not a philosophical difference, and it is the
honest answer to "can I replicate my TRaSH Guides setup". The preset gallery
includes profiles derived from those guides, and they translate the resolution,
source, and size parts faithfully; the per-format scoring that makes those guides
powerful has no equivalent to translate into.

## Where to go next

- [Quality profiles reference](../reference/quality-profiles.md) for the fields
  and the built-in profiles.
- [Automatic quality upgrades](../how-to/automatic-quality-upgrades.md) for
  turning upgrades on, pacing the sweep, and what it costs you in disk.
- [How a title becomes a file](media-pipeline.md) for what happens either side
  of selection.
- [Mydia compared to Radarr and Sonarr](vs-radarr-sonarr.md) for the wider
  feature comparison.
