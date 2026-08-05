# Contributing to Mydia

## Quality gates

Mydia enforces a small set of automated quality gates in CI: the compiler's
set-theoretic type checker (`mix compile --warnings-as-errors`), Credo
(`mix credo --strict`), and an advisory dead-code report (`mix_unused`).

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

### What is forbidden

Because each of these is a list of deferred findings, not a rule:

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
