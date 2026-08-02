# Mydia Compared to Radarr and Sonarr

Radarr and Sonarr are the reference implementations of this category. They work,
they are mature, they have enormous communities, and the standard self-hosted
media stack is built around them. Any project in the same space owes an
explanation of why it exists, so here is Mydia's, including the parts where the
*arr stack is simply better.

## The one-line version

Mydia collapses several services into one and is much younger. Radarr and Sonarr
are two specialised, deeply refined tools that expect to be surrounded by other
tools.

That is the whole argument, in both directions. Everything below is detail.

## Where Mydia is different by design

**Movies and TV in one application.** Radarr does films, Sonarr does series, and
running both is normal. The split is historical rather than principled: Sonarr
came first, Radarr was forked from it, and the two codebases diverged. The daily
cost is duplication. Two applications to install, update, and back up. Two sets
of indexer connections, download client connections, and quality profiles that
you want to keep identical and that drift anyway. Two places to look when
something did not download. Mydia treats a movie and an episode as two shapes of
the same problem, so one library, one profile, one set of connections covers
both.

**Users are built in.** The *arr applications are single-user administrative
tools. If you want other people to request media, the accepted answer is to run
Overseerr or Ombi in front of them: another service, another database, another
login, synchronised with the *arr instances over their APIs. Mydia has accounts,
admin and guest roles, and a request-and-approval flow as part of the
application, because "other people in the house want to ask for things" is the
normal case for a home media server rather than an extension of it.

**Single sign-on is part of the application.** The *arr stack has local
authentication and expects a reverse proxy with a forward-auth provider to do
anything more. That works and plenty of people run it, but it means the
authentication story lives in your proxy configuration rather than in the
application. Mydia speaks OIDC directly.

**Indexers without a separate manager.** Cardigann definitions are the community
format that Jackett created and Prowlarr adopted, and they are what actually
knows how to talk to each site. Mydia reads them natively, so a small install can
connect to a few trackers without running an indexer manager. Prowlarr and
Jackett remain fully supported, and for most people they remain the better
choice; see the caveat below.

**Configuration is layered.** Mydia's settings come from schema defaults, a YAML
file, environment variables, and a runtime-editable database overlay, with the
source of each value shown in the interface. The *arr applications keep
configuration in their own database, editable in their UI, and that is all: you
cannot declare an instance's download clients in a Compose file and have them
exist on first boot. Mydia can be described declaratively *and* changed while
running, which is the subject of its own [page](configuration-model.md).

**Remote access without configuring anything.** Mydia's player app reaches an
instance through an encrypted peer-to-peer connection with no port forwarding,
VPN, or dynamic DNS. The *arr applications have no equivalent because they have
no player; they are not trying to solve this problem. See
[how remote access works](remote-access.md).

## Where Radarr and Sonarr are better

This section is longer than the marketing instinct would like. It is also the
more useful one.

**Custom formats.** This is the big one. Radarr and Sonarr let you define named
formats (release groups you trust, audio codecs you want, encoders you avoid)
and assign each a score that feeds into release selection. It is the mechanism
that makes TRaSH Guides possible, and it is genuinely powerful and genuinely
well-designed. Mydia has ordered preference lists, and nothing resembling
per-format scoring. It does have a blocked-tag filter, but it is not exposed in
the interface, so in practice the ordered lists are the whole toolkit. Profiles derived from those guides ship in
Mydia's preset gallery, and they translate the resolution, source, and size parts
faithfully; the scoring layer has no equivalent to translate into. If custom
formats are why your setup grabs what you want, Mydia will disappoint you today.

**Automatic upgrades.** The *arr applications will replace a file you already
have when a better one appears, bounded by a cutoff so it stops. Mydia does not.
Quality profiles have upgrade fields, they are editable, and nothing reads them;
an item with a file is simply not searched again. Getting a better copy of
something you already have means deleting the file or grabbing by hand. This is
covered honestly in
[why Mydia picked that release](quality-decisions.md#there-is-no-upgrade-path-yet).

**Indexer reliability.** Prowlarr has years of accumulated handling for the
specific ways individual trackers misbehave, and far more people noticing within
hours when one breaks. Mydia's native Cardigann implementation handles the common
shape of a definition well and the long tail badly. It is marked experimental
because it is experimental. Running Prowlarr in front of Mydia is a completely
reasonable configuration and is the right call if indexer reliability is what you
care about most.

**Maturity, in the boring sense.** Radarr and Sonarr have been running in
production on tens of thousands of machines for years. Their edge cases have been
found by other people. Their upgrade paths are well-trodden, their failure modes
are documented in forum posts you can search, and someone has already hit
whatever you are about to hit. Mydia is in its 0.x series and changes
substantially between releases. That is a real cost and it is not offset by any
feature.

**Ecosystem.** The surrounding tools (Bazarr for subtitles, Recyclarr for profile
sync, the various dashboards and mobile apps, every guide ever written) target
the *arr APIs. Mydia is not in that ecosystem and mostly cannot be.

**Depth in each domain.** A tool that does one media type has more room to model
that type precisely. Sonarr's handling of anime numbering, absolute episode
ordering, scene naming, and multi-season packs is deeper than Mydia's, and that
depth came from years of specialised attention that a unified application has to
spread across two domains.

## The comparison as a table

Useful as a summary, but the sections above are where the actual argument is.

| Feature | Mydia | Radarr | Sonarr |
|---------|-------|--------|--------|
| **Media types** | Movies and TV shows | Movies only | TV shows only |
| **Built-in indexers** | Cardigann (experimental) | Requires Prowlarr or Jackett | Requires Prowlarr or Jackett |
| **Multi-user and requests** | Built in (admin and guest roles) | Requires Ombi or Overseerr | Requires Ombi or Overseerr |
| **Authentication** | Local plus OIDC/SSO built in | Local only | Local only |
| **Layered configuration** | Defaults, YAML, env, and DB overlay | Database only | Database only |
| **Library management** | Yes | Yes | Yes |
| **Download automation** | Yes | Yes | Yes |
| **Quality profiles** | Yes | Advanced | Advanced |
| **Custom formats** | Planned | Yes | Yes |
| **Automatic upgrades** | Planned | Yes | Yes |
| **Media server integration** | Plex, Jellyfin | Plex, Kodi, Jellyfin | Plex, Kodi, Jellyfin |
| **List import** | Experimental | Yes | Yes |
| **Native playback** | Experimental (player app) | No | No |
| **Remote access (p2p)** | Experimental | No | No |
| **Technology** | Elixir, Phoenix LiveView | .NET, React | .NET, React |
| **Maturity** | Early development | Production-ready | Production-ready |

## Choosing

**Mydia is a reasonable choice if** you want movies and TV in one place, other
people in your household need to request things, you want SSO without building
it out of proxy configuration, you would like to describe your instance in a file
and still change it at runtime, or you want the player app. It is also a
reasonable choice if you enjoy being early to something and reporting bugs.

**Radarr and Sonarr are the better choice if** your release selection depends on
custom format scoring, you need automatic upgrades, indexer reliability is the
thing you cannot compromise on, or you want software whose sharp edges have
already been found by somebody else. None of those is a small consideration, and
the third and fourth apply to most people.

They also coexist perfectly well. Running Prowlarr in front of Mydia is normal.
Running Mydia alongside an existing *arr setup to see whether it fits, before
moving anything, is a sensible way to evaluate it.

## Where to go next

- [Why Mydia picked that release](quality-decisions.md) for the quality system
  in detail, including what it cannot do.
- [Why configuration is layered](configuration-model.md) for the difference that
  is hardest to see from a feature table.
- [Get Mydia running](../tutorials/get-mydia-running.md) to try it.
