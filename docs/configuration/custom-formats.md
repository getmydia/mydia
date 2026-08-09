# Custom Formats

Custom formats match release titles with regular expressions and let a quality
profile decide what each match is worth. Use them to prefer a particular audio
dub, favour a release group, or refuse a tag outright.

A format on its own means nothing. It gets meaning when a quality profile
assigns it a score or marks it as rejecting, so the same format can be worth
100 points in one profile and be grounds for refusal in another.

## Where things live

- **Admin > Custom Formats** defines formats: their name and their patterns.
- **Admin > Quality Profiles > (a profile)** assigns each format a score or a
  reject flag for that profile only.

## Scoring

Within a resolution tier, a higher total format score wins. Format score is
compared before seeders, file size, and source, and after the profile's
resolution preference. A format score never promotes a 720p release over a
1080p one when the profile prefers 1080p.

Scores are only meaningful relative to each other. A format worth 100 simply
outranks one worth 50; the number does not compete with the general quality
score.

A rejecting format drops the release entirely. It never appears as a grab
candidate, and the rejection shows up in Activity with the reason
`custom_format: <name>`.

## Built-in formats

Mydia ships formats for the common French audio tags. They start unassigned, so
they do nothing until you give them a score.

| Format | Matches | Meaning |
|---|---|---|
| VFF | `VFF`, `TRUEFRENCH` | France French dub |
| VF2 | `VF2` | Second French dub, usually a France redub |
| VFI | `VFI` | International French dub, produced in France |
| VFQ | `VFQ`, `VQ` | Quebec French dub |
| MULTI | `MULTI` | Multiple audio tracks |
| VOSTFR | `VOSTFR` | Original audio with French subtitles, not a dub |

Built-in definitions ship with Mydia, so a later release can improve one of
these patterns and you get the fix automatically. If you edit a built-in, your
version wins from then on and later improvements no longer apply to it. Use
**Reset** to go back to the shipped definition.

## Example: prefer France French, refuse Quebec French

In the quality profile you use for French content:

| Format | Score | Reject |
|---|---|---|
| VFF | 100 | no |
| VF2 | 100 | no |
| VFI | 50 | no |
| MULTI | 50 | no |
| VFQ | 0 | **yes** |

With this set:

- `Film.2024.VFF.1080p.WEB-DL` scores 100 and is preferred over a
  better-seeded release with no French tag.
- `Film.2024.MULTI.VFF.1080p` scores 150, because both formats match.
- `Film.2024.VFQ.1080p.WEB-DL` is rejected and never grabbed.

## Writing patterns

Patterns are regular expressions matched against the raw release title. They
are always case-insensitive, so do not add an `(?i)` flag.

Wrap tags in `\b` word boundaries. Scene titles separate words with dots and
underscores, which count as boundaries, so `\bVFF\b` matches
`Film.2024.VFF.1080p` and does not match a release group whose name happens to
contain those letters.

A format matches when any one of its patterns matches. Put each pattern on its
own line.

The edit dialog has a test box: paste a real release title and see which
patterns match before saving.

### Limits

A pattern must compile, or the format cannot be saved. Patterns are capped at
500 characters and 20 per format. Matching is bounded, so a pattern that would
otherwise backtrack forever is abandoned and treated as a miss rather than
stalling your searches.

## What custom formats do not do

Custom formats apply when deciding what to download. They do not re-evaluate
files already in your library, so a file you already have is never automatically
replaced because of a format score. To replace one, delete it and search again.
