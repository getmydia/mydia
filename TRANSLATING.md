# Translating Mydia

Mydia's web interface is translated on Weblate:
https://hosted.weblate.org/projects/mydia/

You need a free Weblate account, no git and no code. Translations reach Mydia
as pull requests that a maintainer merges, and ship in the next release.

## Translating

1. Open the project, pick the `default` component (the interface) or `errors`
   (form validation messages), and pick your language.
2. Keep every `%{name}` placeholder exactly as written. You may move it, never
   rename or translate it. Weblate flags a changed placeholder; CI rejects it.
3. For plurals, fill every form Weblate shows for your language.
4. Keep the tone plain and direct. Do not translate product names (Mydia, Plex,
   TMDB...).

Partly translated languages are fine: anything untranslated shows in English,
and the language picker shows how complete each language is.

## Adding a language

Start it from the Weblate project page ("Start new translation"). It appears in
Mydia's language picker in the first release after its first translations are
merged.

## Reviewing the seed translations

The Spanish and Brazilian Portuguese translations were machine-drafted. Native
speakers: please review them on Weblate.
