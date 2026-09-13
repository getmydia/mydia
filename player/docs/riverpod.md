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
notifier capture, a deferred write, and an identity check on retraction. See
`player/lib/presentation/widgets/poster_frame.dart`.

The identity check is testable and is tested: the scroll-recycling regression in
`player/test/presentation/widgets/poster_frame_test.dart` publishes a second
poster's override between the update and the pump that flushes the deferred
clear, and asserts the fresher override survives. A write does not have to land
in the same frame as the pump; it only has to be the active override when the
callback fires. What resists a test is narrower: the `!mounted || !_isHovered`
re-check, since there is no seam to move the pointer out between scheduling and
flushing. Document that one rather than writing a test that passes either way.

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

## An unwatched autoDispose provider loses its Ref at the first await

`flutter_riverpod` 3.3.2 pulls in `riverpod` 3.3.2, whose scheduler rework
changed when an autoDispose provider with no listeners is torn down: it is
already disposed by the time the first `await` inside it resumes. `read` never
adds a listener, so a provider the app only ever reads no longer survives a
single microtask, and `Ref.mounted` reads `false` in the continuation.

That breaks the shape the repo uses for every "command" provider —
`updateDownloadSettings`, `updateStorageSettings`, `saveCollectionSync`,
`removeCollectionSync` and `SidebarLayoutController._mutate`:

```dart
@riverpod                               // autoDispose, and nothing watches it
Future<void> Function(T) save(Ref ref) {
  return (T value) async {
    await write(value);                 // the Ref dies here
    ref.invalidate(theStateProvider);   // UnmountedRefException
  };
}
```

The throw lands in a continuation the caller never awaits, so the write still
lands and the flow just stops: a new sidebar filter never appeared, and the
storage sheet aborted before the download half of its save and never closed.
Nothing about the call sites looks wrong, which is why this went out with the
bump. On the previous pin the disposal was deferred past that microtask, so the
same tests passed.

`@Riverpod(keepAlive: true)` is the fix for a stateless command provider: it
holds no state, so keeping the element alive costs nothing else.
`ref.read(p.notifier)` captured in a field, or a `container.listen`
subscription held around the call, also keeps it alive, but pushes the
requirement onto every call site — and the subscription is what hid this:
`player/test/core/downloads/download_providers_test.dart`'s `saveSettings`
helper held one, so it never exercised the shape the app uses.

Reproduce with one probe rather than by reasoning: `debugPrint('${ref.mounted}')`
either side of the `await`. `true` then `false` is this bug.
