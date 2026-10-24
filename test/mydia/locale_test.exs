defmodule Mydia.LocaleTest do
  use ExUnit.Case, async: true

  alias Mydia.Locale

  @available ~w(de en es pt pt_BR)

  describe "resolve/4" do
    test "a concrete available preference wins" do
      assert Locale.resolve("de", "es", "pt", @available) == "de"
    end

    test "auto, nil and unavailable preferences fall through to the header" do
      for pref <- ["auto", nil, "ko", ""] do
        assert Locale.resolve(pref, "es", "de", @available) == "es"
      end
    end

    test "header entries are tried by descending q, ties in header order" do
      assert Locale.resolve(nil, "fr;q=0.9, de;q=0.8, es;q=0.95", "en", @available) == "es"
      assert Locale.resolve(nil, "fr, de, es", "en", @available) == "de"
    end

    test "q=0 means not acceptable" do
      assert Locale.resolve(nil, "de;q=0, es;q=0.1", "en", @available) == "es"
    end

    test "region tags try the exact code, then the bare language" do
      assert Locale.resolve(nil, "pt-BR", "en", @available) == "pt_BR"
      assert Locale.resolve(nil, "pt-PT", "en", @available) == "pt"
      assert Locale.resolve(nil, "PT-br", "en", @available) == "pt_BR"
      assert Locale.resolve(nil, "es-MX", "en", ~w(en es)) == "es"
    end

    test "no sibling-region guessing" do
      assert Locale.resolve(nil, "pt-PT", "en", ~w(en pt_BR)) == "en"
    end

    test "wildcards and garbage are skipped" do
      assert Locale.resolve(nil, "*, ;;, x-klingon", "de", @available) == "de"
    end

    test "instance default applies when the header gives nothing" do
      assert Locale.resolve(nil, nil, "de", @available) == "de"
      assert Locale.resolve(nil, "", "de", @available) == "de"
    end

    test "an unavailable instance default falls back to en" do
      assert Locale.resolve(nil, nil, "ko", @available) == "en"
      assert Locale.resolve(nil, nil, nil, @available) == "en"
    end
  end

  describe "with_preference/3" do
    test "an available preference overrides the fallback" do
      assert Locale.with_preference("de", "es", @available) == "de"
    end

    test "auto or unavailable keeps the fallback" do
      assert Locale.with_preference("auto", "es", @available) == "es"
      assert Locale.with_preference("ko", "es", @available) == "es"
    end

    test "an unavailable fallback becomes en" do
      assert Locale.with_preference(nil, "xx", @available) == "en"
      assert Locale.with_preference(nil, nil, @available) == "en"
    end
  end

  describe "available/0" do
    test "en is first and always complete" do
      assert [%Locale.Info{code: "en", native_name: "English", completion: 1.0} | _] =
               Locale.available()
    end

    test "every priv/gettext locale is listed with a bounded completion" do
      assert "es" in Locale.codes()

      for %Locale.Info{completion: c} <- Locale.available() do
        assert c >= 0.0 and c <= 1.0
      end
    end

    test "available?/1" do
      assert Locale.available?("en")
      assert Locale.available?("es")
      refute Locale.available?("auto")
      refute Locale.available?(nil)
    end
  end

  test "html_lang/1 converts to BCP 47" do
    assert Locale.html_lang("pt_BR") == "pt-BR"
    assert Locale.html_lang("es") == "es"
  end
end
