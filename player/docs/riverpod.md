# Riverpod sharp edges

## Writing provider state from dispose needs two independent fixes

Writing provider state from `dispose()` or `didUpdateWidget()` of a
`ConsumerState` trips two separate Riverpod guards, and fixing one leaves the
other. This cost three review rounds on PR #347.

`ref` is unsafe during teardown. `ref.read(...)` from `dispose()` throws "Using
ref when a widget is about to or has been unmounted is unsafe", but only once a
listener is attached to the provider, so it can pass in an isolated test and fail
in the real app. Capture the notifier in a field.

The write itself is still forbidden. `dispose` and `didUpdateWidget` are both
lifecycles Riverpod refuses synchronous provider writes from, since unmounting
runs inside `BuildOwner.finalizeTree`'s build lock, so it throws "Tried to modify
a provider while the widget tree was building" regardless of how the notifier was
obtained. Defer via `SchedulerBinding.instance.addPostFrameCallback`.

There is a trap inside the trap. Capturing as `late final X = ref.read(...)`
evaluates lazily on first read, which for a widget disposed while active is
inside `dispose()` itself. Assign eagerly in `initState`.

Deferring then creates a race. By the time the callback runs, another instance may
have published newer state, so an unconditional clear wipes it.
`AmbientBackdropController.clearHoverIf(source)` in
`player/lib/presentation/widgets/ambient_backdrop_provider.dart` is the in-repo
answer: retract only what this instance published. Deferred callbacks must also
re-check the state that justified scheduling them
(`if (!mounted || !_isHovered) return;`), since the pointer may have left in
between.

`publishBackdropSource` in that same file already deferred for the second reason
and predates all of this, so it is the idiom to copy.

Any `ConsumerState` mutating a provider outside a normal callback needs eager
notifier capture, a deferred write, and an identity check on retraction. The guard
on the deferred state re-check is not unit-testable, because post-frame callbacks
fire synchronously inside a single `pump` and there is no window to interleave.
Document it rather than writing a test that passes either way. See
`player/lib/presentation/widgets/poster_frame.dart`.

## The analyzer does not catch post-await ref use

`use_build_context_synchronously` only flags a `BuildContext`, or a
`context.`-derived call, read after an async gap. A `ConsumerWidget`'s `ref`
outliving its element is structurally invisible to it, so this analyzes clean and
is still wrong:

```dart
final picked = await showSomeDialog(context);
if (picked != null) {
  ref.read(someProvider.notifier).save(picked);  // ref may be disposed
}
```

Verified independently during PR #349 on 2026-08-05. The analyzer reported zero
new issues both before and after adding the missing guard, because the call site
touches only `ref` after the await and never `context`.

When reviewing or writing any `await` inside a `ConsumerWidget` or
`ConsumerState` callback, check for the guard by eye. `settings_screen.dart`'s
`_handleLogout` is the in-repo idiom:
`if (result == expected && context.mounted) { ... }`. Every post-await `ref` use
in the player is guarded by convention and review rather than by tooling, so a
sweep for unguarded ones is worthwhile if this ever bites.

## ref.read(p.notifier) rethrows a throwing constructor, never a throwing build()

To make `ref.read(someProvider.notifier)` throw synchronously in a test, the fake
Notifier must throw from its constructor.

Verified against the pinned riverpod 3.2.1 source during work on the player's
sign-out teardown. `$ClassProviderElement.create()` wraps the constructor call in
`$Result.guard(...)` and stores it on `classListenable`, and `.notifier` resolves
through that same `classListenable` (`$ClassProvider.notifier` into
`ProviderElementProxy` into `readSafe().valueOrProviderException`), so a
constructor throw is rethrown synchronously at the `.notifier` read. A throwing
`build()` runs after the constructor already succeeded, so
`classListenable.result` is already `$ResultData`, and its error is routed only
into the provider's value (`handleError` sets `value = AsyncError(...)`). It
surfaces when you read `someProvider`, never `someProvider.notifier`.

A plan once specified a throwing-`build()` fake to cover a synchronous throw from
`ref.read(...notifier)`. That test would have passed for the wrong reason, because
the code path it targeted cannot be reached that way. If a test uses a throwing
`build()` and passes, confirm it actually goes red without the fix before
believing it.
