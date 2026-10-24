defmodule MydiaWeb.GettextPluralTest do
  use ExUnit.Case, async: true

  test "Spanish picks the singular for 1 and the plural for 2" do
    ngettext = fn n ->
      Gettext.with_locale(MydiaWeb.Gettext, "es", fn ->
        Gettext.ngettext(
          MydiaWeb.Gettext,
          "1 recovery code left",
          "%{count} recovery codes left",
          n
        )
      end)
    end

    assert ngettext.(1) == "Queda 1 código de recuperación"
    assert ngettext.(2) == "Quedan 2 códigos de recuperación"
  end
end
