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
- The release is for the wrong thing: an episode search that matched a season
  pack, the wrong episode, or a movie search that matched something with season
  and episode markers in the name.
- The title contains one of your blocked tags. This is a case-insensitive
  substring test, so a short token matches inside longer words, including
  release group names.
- The release fails a validity check: an executable or script extension, a
  hashed or numeric-only title, an apparently password-protected archive, or no
  meaningful content in the name.
- The release is on the blocklist, which is where releases go after a download
  built from them fails.
- A Usenet post is younger than the indexer's configured minimum age.

Nearly everything else is a **soft penalty**: it pushes a release down the
ranking instead of removing it. Size outside your configured range, low seeders,
and a poor seeder-to-leecher ratio all work this way, and the penalties are
deliberately capped small enough that they cannot flip a correct release below an
incorrect one. The reasoning is that a search returning nothing is a worse
outcome than a search returning something imperfect, and hard size and seeder
filters are extremely good at returning nothing.

This is why raising the minimum seeder count does not behave like a filter. It
biases the ranking; it does not empty the result list.

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
2. **It never survived the first pass.** On a busy title, a low-seeded release
   can be cut before the profile is consulted.
3. **It lost the duplicate collapse.** When the same release comes back from
   several indexers, Mydia keeps the copy with the most seeders and the most
   complete metadata, and discards the rest.
4. **Its codec, source, or audio was unlisted rather than merely second.** See
   above; the penalty for absent is larger than for last.
5. **The title did not match closely enough.** Either the parsed title fell below
   the similarity threshold, or a name padded with tags and group suffixes drove
   the relevance score to zero and triggered a hard rejection.
6. **It violated a resolution bound or a required HDR format.** This does not
   remove the release, but it zeroes the entire quality component, which is most
   of the available score.
7. **A blocked tag matched inside another word.** Substring matching is
   unanchored.
8. **It was blocklisted** after a previous download built from it failed.

Notice what is not on that list. Indexer priority is not a factor; indexers are
queried concurrently and their priority number does not weight their results.
Size limits and seeder minimums are almost never decisive on their own, because
they are capped soft penalties. And "the cutoff was already met" is not a reason
in Mydia at all, for the reason in the next section.

## There is no upgrade path yet

This needs saying plainly, because the interface implies otherwise.

Quality profiles have an **upgrades allowed** switch and an **upgrade until**
quality, they are editable, they are saved, and they export and import with the
profile. Nothing currently reads them when deciding anything. There is no code
path that compares a candidate release against a file you already have and
replaces it.

What actually prevents a media item from being downloaded twice is much simpler:
automatic searches only consider items that have no file at all, and the grab
path independently refuses a release for something that already has one. An item
with a file is not searched, so it is never upgraded, regardless of what its
profile says.

The practical consequences are worth being concrete about. Changing a profile
from 720p to 1080p does not cause anything you already have to be re-fetched. A
PROPER or REPACK of something you already downloaded will not replace it. If you
want a better copy of a file you already have, you delete the file and let Mydia
search again, or you grab a specific release by hand.

Mydia's [comparison page](vs-radarr-sonarr.md) lists automatic upgrades as
planned rather than present, and the front page does the same. This section
exists because a switch in a settings form is a much louder claim than a word in
a table, and the switch is currently telling you something that is not true.

## There are no custom formats

Radarr and Sonarr let you define named custom formats with individual scores:
release groups you trust, audio formats you want, encoders you avoid, each
contributing points to a total. That model is the main reason the *arr stack's
quality handling is more expressive than Mydia's, and it is genuinely more
expressive.

Mydia has three term-based mechanisms and none of them is a custom format.
Blocked tags hard-reject on a substring match. Resolution, codec, source, audio,
and HDR preferences are ordered lists scored by position. A preferred-tag bonus
exists in the ranking code but is not reachable from any part of the interface,
so in a running instance it is always empty.

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
- [How a title becomes a file](media-pipeline.md) for what happens either side
  of selection.
- [Mydia compared to Radarr and Sonarr](vs-radarr-sonarr.md) for the wider
  feature comparison.
