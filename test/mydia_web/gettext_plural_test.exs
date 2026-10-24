defmodule MydiaWeb.GettextPluralTest do
  use ExUnit.Case, async: true

  test "Spanish picks the singular for 1 and the plural for 2" do
    ngettext = fn n ->
      Gettext.with_locale(MydiaWeb.Gettext, "es", fn ->
        Gettext.ngettext(
          MydiaWeb.Gettext,
          "%{count} recovery code left",
          "%{count} recovery codes left",
          n
        )
      end)
    end

    assert ngettext.(1) == "Queda 1 código de recuperación"
    assert ngettext.(2) == "Quedan 2 códigos de recuperación"
  end

  describe "a locale Gettext.Plural does not know" do
    alias MydiaWeb.Gettext.Plural

    @header "nplurals=3; plural=(n==1 ? 0 : n==2 ? 1 : 2);"

    test "honours the catalog's Plural-Forms header" do
      info = Plural.init(%{locale: "xx", plural_forms_header: @header})

      assert Plural.nplurals(info) == 3
      assert Enum.map([1, 2, 3, 0], &Plural.plural(info, &1)) == [0, 1, 2, 2]
    end

    test "without a header it falls back to the per-locale rules" do
      info = Plural.init(%{locale: "es"})

      assert Plural.nplurals(info) == 2
      assert Plural.plural(info, 1) == 0
      assert Plural.plural(info, 2) == 1
    end

    test "an invalid header fails loudly" do
      info = Plural.init(%{locale: "xx", plural_forms_header: "nonsense"})

      assert_raise Expo.PluralForms.SyntaxError, fn -> Plural.nplurals(info) end
    end
  end
end
