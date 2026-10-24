defmodule MydiaWeb.Gettext.Plural do
  @moduledoc """
  Plural rules for `MydiaWeb.Gettext`, chosen by locale.

  The default `Gettext.Plural` parses each .po file's `Plural-Forms` header and
  compiles the parsed `Expo.PluralForms` struct into the backend as a literal.
  That type is opaque, so Dialyzer rejects the literal. This module has no
  `init/1`, which makes the plural info just the locale string. Weblate writes
  the same standard rules into its headers that `Gettext.Plural` already knows
  per locale, so nothing is lost.
  """
  @behaviour Gettext.Plural

  @impl true
  defdelegate nplurals(locale), to: Gettext.Plural

  @impl true
  defdelegate plural(locale, count), to: Gettext.Plural
end
