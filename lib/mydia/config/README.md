# Layered config

The `yaml -> db -> env` overlay is Mydia's core differentiator from the *arr
stack. Two things about it are not obvious from reading the schema.

## The database section cannot take the DB overlay

`Mydia.Config.Schema`'s `database` embed is the one section that can never
participate in the full merge. `Mydia.Config.Loader.load/1` calls
`Settings.load_database_config()`, which queries the database, and `Mydia.Repo` is
the second child in `Mydia.Application.children/1`. The full Loader therefore always
runs after the Repo is up, so nothing it produces can configure that Repo.

That is why the section sat declared, parsed, validated and documented while being
completely inert (issue #503). It was written alongside its fifteen siblings
without anyone noticing that its lifecycle differs.

SQLite pragmas are pinned in `Mydia.DB.Baseline` (WAL mode, immediate transactions,
busy timeout, etc.) for write concurrency safety (#283) and are not operator-tunable.

`database.path` and `database.pool_size` are the only two settings in the schema.
They are loaded during phase one (`sources: [:yaml, :env]`) and applied via
`Mydia.Repo.init/2`, which runs at Repo boot with all modules loaded and applies
uniformly to dev, test, and prod.

Oban settings (`poll_interval` and `max_age_days`) are likewise loaded from
`:runtime_config` and applied via `Mydia.Jobs.ObanConfig` when Oban starts in the
supervision tree (`Mydia.Application.children/1`).

## parse_atom/1 mints atoms, so do not reuse it

`Mydia.Config.Loader.parse_atom/1` tries `String.to_existing_atom/1` and rescues
`ArgumentError` by calling `String.to_atom(value)`. Any env var routed through it
can mint an atom, and atoms are never garbage collected. CLAUDE.md forbids
`String.to_atom/1` on user input, so the helper quietly violates the project's own
rule.

The trap is copy-paste. Existing `put_if_present(:type, ..., &parse_atom/1)` call
sites make it the obvious thing to reuse for a new enum-valued
`DOWNLOAD_CLIENT_<N>_*` or `INDEXER_<N>_*` variable. CodeRabbit caught exactly
this on PR #535.

To add a new enum-valued env var, write a dedicated fixed-enum parser matching the
valid strings, following `parse_external_torrents/1` in the same file.

Map unknown values to `{:ok, :invalid}` rather than `:error`. `put_if_present/4`
drops the key on `:error`, so the field silently falls back to its schema default,
and an operator who typo'd a safety-relevant setting gets the opposite of what they
asked for with no error anywhere. `:invalid` is not a member of the `Ecto.Enum`, so
config validation rejects it by name, which is how a bad `DOWNLOAD_CLIENT_<N>_TYPE`
already behaves.
