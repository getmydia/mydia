defmodule MydiaWeb.Gettext.Plural do
  @moduledoc """
  Plural rules for `MydiaWeb.Gettext` that honour each catalog's `Plural-Forms`
  header.

  The default `Gettext.Plural` parses the header at compile time and compiles
  the resulting `Expo.PluralForms` struct into the backend as a literal. That
  struct holds an opaque AST, so Dialyzer rejects the literal. Here the header
  stays a plain string in the plural info and is parsed at runtime (memoized in
  `:persistent_term`). A catalog without a header falls back to the per-locale
  rules in `Gettext.Plural`. An invalid header still fails the build, because
  the compiler calls `nplurals/1` on it.
  """
  @behaviour Gettext.Plural

  @impl true
  def init(%{locale: locale, plural_forms_header: header}) when is_binary(header),
    do: {locale, header}

  def init(%{locale: locale}), do: locale

  @impl true
  def nplurals({_locale, header}), do: parsed(header).nplurals
  def nplurals(locale), do: Gettext.Plural.nplurals(locale)

  @impl true
  def plural({_locale, header}, n), do: Expo.PluralForms.index(parsed(header), n)
  def plural(locale, n), do: Gettext.Plural.plural(locale, n)

  defp parsed(header) do
    key = {__MODULE__, header}

    case :persistent_term.get(key, nil) do
      nil ->
        forms = Expo.PluralForms.parse!(header)
        :persistent_term.put(key, forms)
        forms

      forms ->
        forms
    end
  end
end
