# Adapter portability and Ecto gotchas

Mydia ships on SQLite (the default for dev, test and most self-hosted installs)
and on PostgreSQL. Almost everything below is a case where SQLite passes and
PostgreSQL fails, which means a green local run proves less than it looks like it
does. See the root `CLAUDE.md` for how to run the suite against PostgreSQL.

## Never aggregate a boolean column

`max(type(e.monitored, :integer))` works on SQLite, which stores booleans as
integers, and fails on PostgreSQL:

```
** (Postgrex.Error) ERROR 42846 (cannot_coerce) cannot cast type boolean to bigint
```

Select the raw flags and fold them in Elixir:

```elixir
from(e in Episode, where: ..., select: {e.season_number, e.monitored})
|> Repo.all()
|> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
|> Map.new(fn {k, flags} -> {k, Enum.any?(flags)} end)
```

`fragment("bool_or(?)", ...)` is PostgreSQL-only and would need an adapter
branch, which the project avoids.

This shipped in PR #447 on 2026-08-13. A full local SQLite run of 7703 tests
passed and CI's `Test / PostgreSQL` job failed with 4 errors. Any query using
`max`, `min` or `sum` over a `:boolean` field is wrong. More generally, verify on
PostgreSQL locally before pushing a query that touches a boolean, casts a type,
or uses a fragment.

## Raw bytes in a string column

Inserting raw bytes such as `:crypto.strong_rand_bytes/1` into a column whose
PostgreSQL type is `:string` or `text` passes on SQLite and fails on PostgreSQL:

```
(Postgrex.Error) ERROR 22021 (character_not_in_repertoire)
invalid byte sequence for encoding "UTF8"
```

SQLite stores arbitrary bytes in text columns and PostgreSQL enforces UTF-8.

The concrete instance: `ErrorTracker.Error.fingerprint` is declared
`field :fingerprint, :binary` in the Ecto schema, while the PostgreSQL migration
column is `add :fingerprint, :string, null: false` with a unique index.
ErrorTracker itself stores it as `Base.encode16(:crypto.hash(:sha256, ...))`, an
ASCII hex string. Fixtures inserting ErrorTracker errors must use a Base16 or
ASCII fingerprint, such as `Base.encode16(:crypto.strong_rand_bytes(8))`.

The `:binary` Ecto type does not guarantee a `bytea` column. Trust the
migration's column type over the schema field type.

## Use the Mydia.DB JSON macros

`Mydia.DB` (`lib/mydia/db.ex`) exposes compile-time macros for adapter-agnostic
JSON SQL: `json_extract/2`, `json_not_null/2`, `json_extract_integer/2`,
`json_extract_boolean/2`, `json_equals/3` and `cast_to_real/1`. They expand to a
literal `fragment(...)` chosen by `Application.compile_env`, so they are ordinary
query expressions and compose anywhere.

`Mydia.Collections.SmartRules` also carried a private `json_extract_dynamic/2`
branching on `DB.postgres?/0` at runtime and returning an
`Ecto.Query.dynamic/2`. That is a different kind of value, with a hard
restriction from Ecto:

> dynamic expressions can only be interpolated at the top level of where, having,
> group_by, order_by, select, update or a join's on

Nesting a dynamic inside another `dynamic/2` is legal and is Ecto's composition
idiom. Nesting one inside a query expression is not, and that is the trap:
`where: not is_nil(^json_val)` looks harmless and raises `Ecto.QueryError` only
at runtime, when the query runs. Nothing catches it at compile time.

That line shipped in `SmartRulesFields`' genre, language and status value
providers. Because those ran inside `render_value_input/2` during LiveView
render, the exception terminated the LiveView, so Collections > Create Collection
> Smart lost the whole dialog the moment you picked Genre, Language or Status.
Fixed in #615 by switching to the macros and deleting that module's copy.

Reach for the macros first. Build a dynamic only when you genuinely need to
compose conditions (or-chains, conditional filters), and then interpolate it
inside another `dynamic/2` or as the entire value of a clause, never as an
argument to `is_nil`, `not`, `like` or any other function inside a `from`. And
never let a query run during render; load into an assign in the event handler so
a query failure cannot take the page down.

## cast/3 does not validate binary_id shape

`Ecto.Type.cast_fun(:binary_id)` is `cast_binary/1`
(`deps/ecto/lib/ecto/type.ex:845,925`), a bare `is_binary` check. So
`cast(changeset, %{some_id: "garbage"}, [:some_id])` produces a valid changeset on
both adapters. It is not a UUID format check.

Where it fails differs, which matters when reasoning about 500s:

- PostgreSQL write path fails in the adapter's `Ecto.UUID` dumper inside
  `Ecto.Repo.Schema.do_insert`, raising `Ecto.ChangeError` before any constraint
  is evaluated. It is not a constraint error, so a `rescue Ecto.ConstraintError`
  never sees it.
- PostgreSQL read path does validate shape. `Repo.get`, `get_by` and `where`
  raise `Ecto.Query.CastError` while binding the query parameter. Query-parameter
  casting validates; changeset casting does not.
- SQLite stores `binary_id` as TEXT, so a malformed id casts, dumps and is
  written. It only fails later on a foreign key, if one exists.

A design doc for #587 asserted the opposite ("PostgreSQL rejects it in cast/3")
and built a four-cell adapter truth table on it. One cell was wrong, caught
during implementation.

Never assume a well-formed-looking `binary_id` was validated by `cast/3`. If a
code path must reject a malformed id cleanly, read the row first with `Repo.get`,
which raises `CastError` on PostgreSQL and finds nothing on SQLite, or check
existence explicitly. When writing an adapter-parity test for a malformed id,
expect different exceptions per adapter and branch on `Repo.__adapter__()`.

## cast/3 strips blank strings out of arrays

`Ecto.Changeset.cast/3`'s default `:empty_values` is `[""]`, and for an array
field it filters each element rather than the whole value. The moduledoc says "If
the field is an array type, any empty value inside the array will be removed",
and `filter_values/3`'s `{:array, type}` clause discards elements that trim to an
empty value.

Casting `["en", ""]` into a `{:array, :string}` field yields `["en"]` before any
validation runs. A test asserting that a blank entry is rejected passes because
the blank vanished, not because validation caught it. That false positive shipped
once in `Mydia.Config.Schema` and was only caught in review.

`:empty_values` is a whole-`cast/4` option with no per-field override, so the fix
is a scoped second `cast/3` call for just that field with `empty_values: []`.
Sequential casts merge via `cast_merge/2`: changes are merged, `valid?` is ANDed,
errors concatenated, and the override does not leak to later calls. Setting
`empty_values: []` on the shared cast would change every field in the embed.

`streaming.subtitle_language` does this as of PR #592.
`streaming.audio_language` has the identical latent gap, left unfixed as out of
scope, and its `validate_audio_language/1` comment was corrected so the two no
longer disagree.

## SQLite foreign keys are already on

Verified 2026-08-03 against the pinned exqlite.
`deps/exqlite/lib/exqlite/pragma.ex:52` reads
`Keyword.get(options, :foreign_keys, :on)`, and `connection.ex:590` applies it via
`set_foreign_keys/2` inside `do_connect/2`, before any transaction opens. So
`ON DELETE CASCADE` is enforced under the test sandbox even though
`config/test.exs` never sets `foreign_keys: :on`, and a cascade-delete assertion
passes on SQLite unmodified.

A per-test `PRAGMA foreign_keys` fix would not work regardless.
`PRAGMA foreign_keys` is a documented no-op inside an open transaction, and the
Ecto SQL sandbox holds one for the whole test, so "enable the pragma on that
test's own connection" silently does nothing.

This corrects an earlier assumption recorded during intro/credits detection
planning, which held that SQLite would not enforce the cascade and prescribed a
per-test pragma. Both halves were wrong.

## PRAGMA busy_timeout is unreadable under exqlite

Never assert on `PRAGMA busy_timeout` to check a Mydia SQLite connection.

exqlite installs a custom busy handler via `sqlite3_busy_handler()`
(`deps/exqlite/c_src/sqlite3_nif.c:498`) and applies the `:busy_timeout`
connection option through its own NIF, deliberately avoiding the pragma. Its
comment at `deps/exqlite/lib/exqlite/connection.ex:538` explains why: "PRAGMA
internally calls sqlite3_busy_timeout() which destroys our custom busy handler."

Reading the pragma returns a value exqlite never wrote. A live-connection test
asserting the configured 30000 would fail, and a test that set the pragma would
silently destroy the busy handler the issue #283 fix depends on.

`journal_mode`, `foreign_keys`, `synchronous`, `temp_store` and `cache_size` all
read back correctly and are safe to assert. Cover `busy_timeout` at the config
layer instead, via `Mydia.Repo.config()` or the baseline keyword list.

## A %Date{} in a sort tuple sorts by day

`Enum.sort_by(list, &{&1.some_date, ...})` does not order chronologically.

A struct is a map, and Erlang compares maps of equal size by their values in key
order. `%Date{}`'s keys sort as `:__struct__`, `:calendar`, `:day`, `:month`,
`:year`, so `:day` is compared before `:month` and `:year`. That makes
`~D[2026-07-31] > ~D[2026-08-01]`, and any range crossing a month boundary comes
back shuffled.

In a tuple key, convert first with
`Enum.sort_by(list, &{Date.to_erl(&1.air_date), ...})`, since `Date.to_erl/1`
yields `{year, month, day}` and sorts correctly as a plain tuple. For a single key
with no tiebreakers, pass the module as the sorter:
`Enum.sort_by(list, & &1.air_date, Date)`. That is what
`MydiaWeb.CalendarLive.Index` already does, which is why the Phoenix calendar
never had this bug.

Caught 2026-08-28 on PR #595 (player calendar). The GraphQL calendar resolver
sorted `{air_date, !has_files, media_item_title}` and returned entries in the
order 2026-09-01, 2026-08-10, 2026-08-10, 2026-07-31. The window it ships with is
30 days back and 90 forward, so it always crosses month boundaries and every
response was misordered. The Flutter client does not re-sort, so the wrong order
would have reached the screen.

It survived because the ordering test gave every entry the same air date and
exercised only the tiebreaks. A sort test whose fixtures share one date cannot
catch this. Make the fixtures cross a month boundary.
