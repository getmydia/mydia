defmodule Mydia.Locale.CatalogTest do
  use ExUnit.Case, async: true

  alias Mydia.Locale.Catalog

  @dir Path.expand("../../support/fixtures/gettext_catalog", __DIR__)

  test "counts translated messages per locale across domains" do
    # Library, plural and "can't be blank" are translated. Settings is empty,
    # Profile is fuzzy (Gettext ignores fuzzy entries), the obsolete entry is
    # not counted at all.
    assert Catalog.scan(@dir) == %{"de" => {3, 5}}
  end

  test "an empty or missing directory has no locales" do
    assert Catalog.scan(Path.join(@dir, "nope")) == %{}
  end
end
