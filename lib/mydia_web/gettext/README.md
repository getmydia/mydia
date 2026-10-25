# Translating the web UI

The Phoenix UI is translated with Gettext. Translations live in
`priv/gettext/<locale>/LC_MESSAGES/{default,errors}.po` and are written on
Weblate (see `TRANSLATING.md`). This file is for developers writing UI code.
The player app is translated separately, with ARB files: see
`player/docs/l10n.md`.

## Writing translatable text

- The msgid is the English text: `{gettext("Library")}`.
- One msgid per whole sentence. Never build a sentence from translated pieces.
- Values go in bindings: `gettext("Added %{title}", title: @title)`.
- Counts use `ngettext("%{count} file", "%{count} files", @count)`. `count` is bound
  automatically. Keep `%{count}` in the singular too: some languages use the
  singular form for 21, 31 and so on.
- Ambiguous short words take a context: `pgettext("tv", "Season")`.
- Inline markup inside a sentence: use a binding with plain text. Split a
  sentence only around a link or button, translating each piece as a whole
  phrase.
- Strings built in Elixir (flash messages, labels) use `gettext` too. Never put
  translatable text in a module attribute: attributes are evaluated at compile
  time, before any locale is set.
- Work done in another process (`start_async`, `Task`) does not inherit the
  Gettext locale. Build translated strings in the LiveView process, or pass
  `Gettext.get_locale(MydiaWeb.Gettext)` to the task and call
  `Gettext.put_locale/2` there.
- Do not translate user or media data, log messages, API error codes or
  anything sent to the player.
- Changeset messages use the `errors` domain through `translate_error/1`
  (in `MydiaWeb.CoreComponents`).

## Locale

`Mydia.Locale` decides the locale: the user's `interface_language`, then the
browser's `Accept-Language`, then `ui.default_locale` (`DEFAULT_UI_LANGUAGE`),
then `en`. `MydiaWeb.Plugs.Locale` and `MydiaWeb.Plugs.UserLocale` set it for
HTTP requests; `MydiaWeb.Live.UserAuth` sets it for LiveView processes, which
do not inherit it. `@locale` is assigned in both.

A language is offered once `priv/gettext/<code>/LC_MESSAGES/` contains a `.po`
file. Untranslated messages fall back to English.

## Files and checks

- `priv/gettext/*.pot` are generated: run `./dev mix gettext.extract` after
  changing UI text and commit them. CI fails if they are stale.
- Never edit or merge `.po` files by hand. Weblate runs msgmerge and opens PRs.
- The untranslated-text check in `mix mydia.ratchet` fails a branch that adds
  literal English to a template. Converted files stay converted.
- `test/mydia_web/gettext_po_test.exs` fails a translation whose placeholders
  do not match its msgid, so a Weblate PR cannot break a page.
