# Why Configuration Is Layered

Mydia reads its configuration from four places at once: built-in schema
defaults, a YAML file, a database table it can write to at runtime, and
environment variables. Each layer overrides the one before it, so an
environment variable always wins and a schema default is only used when nothing
else has an opinion.

That is more machinery than a media manager strictly needs. This page explains
why it is there, what the database layer in particular buys an operator, and
what it costs. For the mechanical precedence order and the list of settings, see
the [configuration reference](../reference/configuration.md) and the
[environment variables reference](../reference/environment-variables.md).

## Four layers because there are four different authors

The layers are not four ways of doing the same thing. Each one exists because a
different person, at a different moment, needs to be the one who decides.

**Schema defaults** are the project's opinion. They are compiled in, they are
what a fresh instance runs on, and their job is to make Mydia work before anyone
has configured anything. If a default has to be changed to get a normal
single-user install working, the default is wrong.

**The YAML file** is the operator's hand-written baseline. It lives with the
rest of the deployment, it is diffable, and it survives being copied to a new
machine. It is where you put the settings you want to be able to read six months
from now without opening a UI.

**The database layer** is what the running instance can change about itself. It
is the subject of most of this page.

**Environment variables** are the deployment's word, and they are last because
the deployment is the thing an operator has the least interactive control over.
Docker Compose files, Kubernetes manifests, and NixOS modules all express
configuration as environment; if the database could override them, then
redeploying with a changed variable would silently do nothing, and the file
under version control would stop describing the running system.

## The database overlay is the interesting one

Most self-hosted media tooling picks a side. Either configuration lives in files
and you restart to change it, or configuration lives in a database and the files
are decorative. Mydia does both, and the database layer sits deliberately in the
middle of the stack: above YAML, below environment.

What that buys is the ability to change a running instance without redeploying
it. Turning on OIDC, pointing at a different metadata language, adding a
download client, adjusting a scan schedule: none of these require editing a
Compose file, none require a container restart, and none require the operator to
have shell access to the host. For a self-hosted application this matters more
than it might seem. The person configuring Mydia is frequently doing it from a
phone, on a home network, against a machine they last SSH'd into months ago. A
setting that can only be changed by editing a file and restarting is, in
practice, a setting that does not get changed.

The *arr stack has no real equivalent. Radarr and Sonarr keep their settings in
their own database and expose them in their UI, which is the runtime-editable
half, but there is no layered file or environment configuration underneath: you
cannot declare a Sonarr instance's download clients in a Compose file and have
them exist on first boot. Mydia's position is that both halves are load-bearing.
Declaring an instance from a file is what makes it reproducible; being able to
change it while it runs is what makes it usable.

### Showing where a value came from

Layering is only honest if the reader can see it. Every setting the admin
interface displays carries a badge naming the layer that actually supplied the
current value: `ENV`, `DB`, `YAML`, or `Default`. Without that, a four-layer
system is a trap. An operator changes a value in the UI, the change appears to
save, and nothing happens, because an environment variable further up the stack
is still winning. That is a genuinely awful debugging experience, and it is the
default failure mode of any precedence system that hides its own precedence.

Mydia goes one step further and makes environment-sourced fields read-only in
the interface rather than editable-but-ineffective. The badge tells you which
layer won; the disabled input tells you that arguing with it here will not help.
Both are the same idea: the UI should never let you believe you have changed
something you have not.

### What the overlay costs

Three things, and it is worth being plain about them.

**Configuration is no longer in one place.** Reproducing a broken instance means
reproducing four layers, not one, and the database layer is the one that does not
show up in a Compose file or a git history. A support conversation that starts
with "here is my docker-compose.yml" is now starting with an incomplete picture.
The provenance badges are what make this recoverable, but the complexity is real
and it is the price of the feature.

**Not every setting can honour it.** Some values are read exactly once, when the
application boots, and no amount of reloading the merged configuration afterwards
will move them. The HTTP listener's port and bind address are decided when the
web endpoint starts. The database adapter is chosen at compile time, which is why
SQLite and PostgreSQL ship as separate images. For settings like these, the
database layer can store a value and the interface can show it, but the running
process will not pick it up until it restarts. A layered system does not make a
process reconfigure itself; it only makes the merged answer available.

**Validation has to be forgiving.** The merged configuration is validated before
the supervision tree starts, which means a validation failure is a boot failure.
That is the right place for validation, but it makes rejecting a bad value
dangerous: a value that was harmlessly ignored by an older release would, after
an upgrade, put the instance into a crash loop over a setting that never did
anything. Mydia's answer is to clamp rather than reject where clamping is
meaningful, and to log loudly when it does. A library scan interval below the
supported floor is raised to the floor and a warning is written, on every
configuration source alike, rather than refusing to start.

## Lists merge instead of overriding

Single values follow strict precedence: the highest layer that sets a value
wins. Collections do not, and cannot sensibly, work that way. Download clients,
indexers, media servers, library paths, and path mappings are lists, and if
environment variables replaced the list wholesale then declaring one client in a
Compose file would delete every client an operator had added through the
interface.

So collections are additive. Entries declared in YAML and in the environment are
appended to what is already there, and an entry created in the database shadows a
declared entry with the same name rather than duplicating it. The practical
consequence is that an environment-declared download client is a *floor*, not a
ceiling: it will exist on every boot, it comes back if someone deletes it from
the interface, and it can be superseded by name but not removed by name.

This is also why entries that came from the environment are marked as such in
the interface and reapplied on every restart. They are not user data; they are
part of the deployment description, and a restart is entitled to restore them.

## Where to go next

- [Configuration reference](../reference/configuration.md) for the precedence
  order as a lookup.
- [Environment variables](../reference/environment-variables.md) for the full
  variable list.
- [How Mydia runs](how-mydia-runs.md) for the deployment shape these settings
  describe.
