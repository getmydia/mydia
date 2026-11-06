# TV D-pad focus: a row remembers its place

On the television tier (`InputCapabilities.directionalPrimary`), every D-pad
landing inside the content area and the player OSD obeys one rule. The design
is in `design/specs/2026-11-05-tv-dpad-focus-rule-design.md`; the code is
`lib/core/focus/focus_memory.dart`.

## The rule

1. Each row, grid, list and button bar remembers the item that last had focus
   in it, by a stable item id rather than by position.
2. Entering one from outside (UP or DOWN from another row) lands on that
   remembered item; one never visited lands on its first item (first visible
   item, for vertical lists).
3. If the remembered item is gone or not built, focus lands on the item nearest
   its last index.
4. Moves inside a row (LEFT and RIGHT along a rail, column-straight in a grid)
   stay Flutter's geometric search, one item at a time.
5. Moves inside a popup (sheet, menu, dialog) are never redirected, and an
   emptied row is skipped.

Off the television tier none of this exists: the widgets return their child
untouched and the callback only delegates to Flutter's default.

## Opting a widget in

The shared widgets already do it. Pass a stable id and you are done:

```dart
HorizontalRail(itemCount: items.length, itemId: (i) => items[i].ref, ...)
BrowseGrid(itemCount: items.length, itemId: (i) => items[i].ref, ...)
```

Use the item's identity (`ItemSummary.ref`, a button's action name), never the
index, or a reordered row (Continue Watching moving a title to the front)
returns to the slot instead of the title.

A row that builds its own list wraps the list in a `FocusMemoryRegion` and
each item in a `FocusMemoryItem`:

```dart
FocusMemoryRegion(
  child: ListView.builder(
    scrollDirection: Axis.horizontal,
    itemCount: items.length,
    itemBuilder: (context, i) => FocusMemoryItem(
      id: items[i].ref,
      index: i,
      child: PosterCard(item: items[i]),
    ),
  ),
)
```

The item's focus target is the first traversable node inside it, so a card
with its own `Focus` or `InkWell` needs nothing else. For a one-column vertical
list pass `entry: FocusMemoryEntry.firstVisible`, so a first visit lands on
the top on-screen row rather than a cached row above the viewport.

## Where the callback is installed

Regions and items only record. The redirect happens in
`FocusMemory.requestFocus`, installed as a traversal policy's
`requestFocusCallback`, which every directional move Flutter makes goes
through. It is installed in two places only:

- the shell's content region policy in `lib/presentation/widgets/app_shell.dart`
  (`RegionTraversalPolicy(onExit: ..., requestFocusCallback: FocusMemory.requestFocus)`);
- the player OSD's traversal group.

A region outside both never redirects anything. Do not add per-screen arrow-key
handlers to get the same effect; that is the pattern this replaced.

## Testing

TV tests are files named `*_tv_test.dart`. Their `group` skips itself unless
the process is compiled with the TV define, because `InputCapabilities.forcedTv`
is a compile-time constant:

```bash
./dev flutter test --dart-define=MYDIA_FORCE_TV=true test/core/focus/focus_memory_tv_test.dart
```

CI runs every `test/**/*_tv_test.dart` file with that define in the
"Run television-tier tests" step. Patterns to copy:
`test/core/focus/focus_memory_tv_test.dart` (rows, reorder, removal, popups)
and `test/presentation/widgets/tv_sidebar_traversal_tv_test.dart` (the sidebar
edge). Label each focusable with its item id via `Focus(debugLabel: ...)` and
assert on `FocusManager.instance.primaryFocus?.debugLabel` after
`tester.sendKeyEvent(...)` and `pumpAndSettle()`. Use invented titles only.
