# Contributing to Mydia

## Quality gates

Mydia enforces a small set of automated quality gates in CI: the compiler's
set-theoretic type checker (`mix compile --warnings-as-errors`), Credo
(`mix credo --strict`), a ratchet on complexity, nesting and module size
(`mix mydia.ratchet`), compile warnings in test files
(`mix test --warnings-as-errors`), LiveViewTest warnings
(`config :phoenix_live_view, :test_warnings, :raise` in `config/test.exs`),
`cargo fmt` and `cargo clippy -D warnings` for every native crate and wasm
plugin, and an advisory dead-code report (`mix_unused`). A second, more precise
dead-code detector, `mix mydia.dead_code`, is available for manual use; see
"A note on `mix mydia.dead_code`" below.

Run the Rust gates with `scripts/check-rust.sh` (native crates) and
`scripts/check-plugins.sh` (wasm plugins); `--fix` rewrites formatting.
Clippy findings need a code fix. Both scripts find crates by directory
(`native/*`, `player/rust/*`, `plugins/*`, `plugins-extra/*`), so a new crate is
gated without editing a list; the pre-commit hook and CI both call them. All
first-party crates share one lint set, described in
[`native/README.md`](native/README.md#rust-rules).

These gates follow one rule, and it is the rule that keeps them honest:

> **Exceptions must be rules about tool blindness, never lists of deferred
> findings.** If an exception names a specific function or file because the
> finding is real but inconvenient, it is rejected.

A legitimate exception describes something a static analyzer structurally
cannot see (dynamic dispatch via `apply/3`, a behaviour callback, framework
dispatch). It is expressible as a regex or predicate, and it auto-covers
future code. Grandfathering is the opposite: a list that grows by one entry
every time someone hits the gate. The first is a rule; the second is a
backlog wearing a config file.

### The three dispositions

Every finding from a gate gets exactly one of these:

1. **Rule-shaped ignore.** The tool is structurally blind here (the call site
   is generated, dynamically dispatched, or a framework callback). Express the
   blindness as a regex or predicate so it covers every present and future
   case. Example: the behaviour-callback predicate (`MydiaQuality`) in `mix.exs`.
2. **Fix it.** The finding is real and the check is precise. Refactor the code,
   or delete it if it is dead. Do not suppress it.
3. **Retire the check.** The check is majority false-positive by construction
   and cannot be made precise with a rule. Disable it with `false` and a
   one-line rationale, and rely on a precise tool instead. Example:
   `StructBracketAccess` was retired in favour of the compiler's type checker.

### Ratchets

`mix mydia.ratchet` (run by `mix precommit` and CI) judges a branch against its
merge base with `origin/master` rather than judging the whole tree. It fails when
the branch adds a cyclomatic-complexity or nesting finding, makes an existing one
worse, adds a file over 800 lines under `lib/`, or grows a file that is already over 800
lines.

The comparison uses your local `origin/master`, so run `git fetch origin` first if
it is stale. Otherwise findings already fixed or added on master can be attributed
to your branch.

This is not grandfathering. Nothing lists the findings that already exist, and the
gate only ever tightens: once a function is simplified or a file shrinks, the
lower number becomes the new baseline. Findings are matched by check and function name
(a lower complexity or depth passes, a higher one fails), ignoring file and module, so
moving an unchanged function into a new module is free. Splitting a large file is
exactly what the gate wants.

**Untranslated text.** A template file (`.heex`, or `~H` in an `.ex` under
`lib/mydia_web/`) may not gain literal English text: text nodes and
`placeholder`, `title`, `alt`, `aria-label`, `label` and `prompt` values. Wrap
new text in `gettext/1` (see `lib/mydia_web/gettext/README.md`). Print a file's
count with `./dev mix run -e 'IO.puts Mydia.Ratchet.TemplateText.count_file("path")'`.

### Dialyzer

`./dev dialyzer` (and the `Dialyzer` CI job) must report zero findings. There is
no ignore list: no `ignore_warnings`, no `.dialyzer_ignore.exs`, no `@dialyzer`
attributes. CI fails if any appear.

Fix a finding by making the code and its `@spec` agree, and prefer correcting
the spec. A clause Dialyzer calls unreachable is either dead (delete it) or
proof the callee's spec is too narrow (widen the spec). A spec you cannot state
precisely gets looser (`map()`, `term()`), not deleted.

Two patterns come up often. An `Ecto.Multi` pipeline trips an opaque-type false
positive, so write the transaction with `Repo.transaction/1` and
`Repo.rollback/1` instead. A compile-time `Mix.env()` comparison is reported as
`exact_compare`, so read `Application.get_env(:mydia, :env)` (set in
`config/config.exs`) rather than adding helpers to dodge it.

It runs in `MIX_ENV=test`, with `:mix`, `:ex_unit` and `:wallaby` added to the
PLT. The first run builds the PLT under `priv/plts` (a few minutes); later runs
reuse it.

This gate exists because nothing else checks the typespecs. Once Elixir's
native type signatures replace typespecs, it goes away with them.

### What is forbidden

Because each of these is a list of deferred findings, not a rule:

- Dialyzer ignores: `ignore_warnings` in `mix.exs`, a `.dialyzer_ignore.exs`
  file (Dialyxir loads it by default, so the file alone is enough), or `@dialyzer`
  attributes in `lib/` or `test/support/`. CI checks for each.
- `exit_status: 0` on an otherwise-enabled Credo check. CI greps `.credo.exs`
  for this and fails the build if it reappears.
- `mix credo --mute-exit-status` in CI.
- Per-finding inline disables (`# credo:disable-for-...`) placed over a real
  finding to make the build pass.
- Accumulated `{Module, :function, arity}` ignore tuples added to `mix_unused`
  to silence a specific finding. Rule-shaped ignores (regex / predicate /
  arity-range) are fine; finding-shaped ones are not.

A Credo check is therefore always in one of two honest states:
enabled-and-gating at zero findings, or `false` with a rationale. There is no
"on but not enforcing."

### A note on the dead-code gate

`mix_unused` runs in CI as an advisory (non-blocking) step. This is a
deliberate disposition, not grandfathering: a Phoenix app's export analysis
cannot trace controller actions, HEEx components, behaviour callbacks, or
runtime dispatch, and the irreducible residual is intentional public API plus
default-argument arity artifacts. Rule-shaped ignores cover the structural
blind spots and provably-dead code is deleted at the source, but the gate
reports rather than blocks. See `.github/workflows/ci.yml`.

### Deprecated code versus compatibility shims

`DEPRECATED:` must not appear in `lib/`. If code is deprecated, delete it.
CI greps for it and fails the build if it reappears.

Code that reads old data or old configuration is not deprecated; it is
load-bearing, and it is marked `COMPAT:`. A `COMPAT:` block states three things:

- **Accepts:** what old input the code handles
- **Source:** where that input actually comes from in the field
- **Removing it would:** the concrete operator-visible breakage

This distinction exists because the two are indistinguishable on sight, and
mistaking a live shim for dead code, or the reverse, is how stale parallel
implementations survive.

### A note on `mix mydia.dead_code`

`mix_unused` checks for unused exports; it cannot tell a genuinely dead
module from a self-referencing cluster that only calls itself (a scanner, a
context, and its schemas that reference one another but nothing outside the
group). `mix mydia.dead_code` closes that gap with true reachability
analysis: it traces every module reference the compiler records and
classifies each module as live, test-only, or orphaned by growing outward
from a small set of exempt framework entry points.

Run it with:

    MIX_ENV=test mix mydia.dead_code

`MIX_ENV=test` is mandatory. `test/support` is only on `elixirc_paths` in the
test environment, so without it the task cannot see test references and
misreports every test-only module as orphaned. Pass `--format json` for
machine-readable output.

Like `mix_unused`, this is advisory: it is not wired into CI and does not
fail the build. Verify every finding by hand before deleting anything. The
known blind spot is attribution: the task attributes a template's edges to
the module it believes owns the template (a colocated `foo.ex` for
`foo.html.heex`, or the parent directory's `.ex` file for
`embed_templates "dir/*"`), and any template or other non-module-defining
file whose owner it cannot resolve this way contributes no liveness at all.
That silence is a gap in the tool, not proof that the code is dead.
