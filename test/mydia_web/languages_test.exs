defmodule MydiaWeb.LanguagesTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.Languages

  test "name/1 returns the display name for a known code" do
    assert Languages.name("pt") == "Portuguese"
    assert Languages.name("en") == "English"
  end

  test "name/1 falls back to the raw code for an unknown one" do
    assert Languages.name("xx") == "xx"
  end

  test "common/0 returns the eight chip languages in display order" do
    assert Enum.map(Languages.common(), &elem(&1, 0)) == ~w(en es fr de it pt ja zh)
  end

  test "every common code also appears in all/0" do
    all_codes = Enum.map(Languages.all(), &elem(&1, 0))

    for {code, _name} <- Languages.common() do
      assert code in all_codes
    end
  end

  test "all/0 pairs every code with a non-empty display name" do
    for {code, name} <- Languages.all() do
      assert is_binary(code) and byte_size(code) == 2
      assert is_binary(name) and name != ""
    end
  end
end
