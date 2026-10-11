defmodule Mydia.Indexers.Cardigann.CharsetTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Charset

  # "Привет" in windows-1251
  @cp1251 <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>>

  test "decodes windows-1251 to UTF-8" do
    assert Charset.decode(@cp1251, "windows-1251") == "Привет"
  end

  test "decodes ISO-8859-2" do
    # "Łódź" in ISO-8859-2
    assert Charset.decode(<<0xA3, 0xF3, 0x64, 0xBC>>, "ISO-8859-2") == "Łódź"
  end

  test "keeps the Latin-1 behaviour" do
    assert Charset.decode(<<0x63, 0x61, 0x66, 0xE9>>, "iso-8859-1") == "café"
  end

  test "passes UTF-8, nil and unknown encodings through" do
    assert Charset.decode("ok", "UTF-8") == "ok"
    assert Charset.decode("ok", nil) == "ok"
    assert Charset.decode("ok", "x-klingon") == "ok"
  end

  test "encodes UTF-8 to windows-1251 for outgoing values" do
    assert Charset.encode("Привет", "windows-1251") == @cp1251
  end

  test "encode passes UTF-8 and nil through" do
    assert Charset.encode("Привет", "UTF-8") == "Привет"
    assert Charset.encode("Привет", nil) == "Привет"
  end

  test "encode falls back to the original string for unmappable characters" do
    assert Charset.encode("日本", "windows-1251") == "日本"
  end

  test "decode always returns valid UTF-8, replacing bytes with no mapping" do
    # 0x98 is unassigned in windows-1251
    assert String.valid?(Charset.decode(<<0x61, 0x98, 0x62>>, "windows-1251"))
  end
end
