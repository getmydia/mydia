defmodule Mydia.Subtitles.Provider.Gestdown.LanguagesTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Provider.Gestdown.Languages

  test "maps a code to the name Gestdown expects in the path" do
    assert Languages.to_name("en") == {:ok, "English"}
    assert Languages.to_name("es") == {:ok, "Spanish"}
    assert Languages.to_name("pt") == {:ok, "Portuguese"}
  end

  test "is case insensitive on input" do
    assert Languages.to_name("EN") == {:ok, "English"}
  end

  test "returns :error for a code it does not know" do
    assert Languages.to_name("zz") == :error
  end

  test "maps a returned name back to a code" do
    assert Languages.to_code("English") == {:ok, "en"}
    assert Languages.to_code("Brazilian Portuguese") == {:ok, "pt"}
  end

  test "returns :error for a name it does not know" do
    assert Languages.to_code("Klingon") == :error
  end
end
