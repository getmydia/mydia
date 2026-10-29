defmodule Mydia.Media.SortTitleTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.SortTitle

  describe "fold/1" do
    test "downcases and strips accents" do
      assert SortTitle.fold("Élan Quarry") == "elan quarry"
    end

    test "folds Latin letters NFD leaves whole" do
      assert SortTitle.fold("Ørsted Drift") == "orsted drift"
      assert SortTitle.fold("Æther Bay") == "aether bay"
    end

    test "nil folds to the empty string" do
      assert SortTitle.fold(nil) == ""
    end

    test "invalid UTF-8 falls back to a plain downcase" do
      assert SortTitle.fold(<<0xFF, ?A>>) == <<0xFF, ?a>>
    end
  end

  describe "key/1" do
    test "drops a leading the, a or an" do
      assert SortTitle.key("The Saltmarsh Years") == "saltmarsh years"
      assert SortTitle.key("A Lantern Below") == "lantern below"
      assert SortTitle.key("An Ordinary Day") == "ordinary day"
    end

    test "is case-insensitive and tolerates extra whitespace" do
      assert SortTitle.key("THE  Saltmarsh Years") == "saltmarsh years"
    end

    test "a stripped title starting with a digit stays a digit" do
      assert SortTitle.key("The 400") == "400"
    end

    test "keeps a title that is only an article" do
      assert SortTitle.key("The") == "the"
      assert SortTitle.key("A") == "a"
      assert SortTitle.key("The ") == "the "
    end

    test "only strips whole words followed by whitespace" do
      assert SortTitle.key("A.I. Garden") == "a.i. garden"
      assert SortTitle.key("Theory of Kites") == "theory of kites"
      assert SortTitle.key("Anna Below") == "anna below"
      assert SortTitle.key("Ash Meridian") == "ash meridian"
    end

    test "strips one article only" do
      assert SortTitle.key("The The") == "the"
    end

    test "strips after accent folding" do
      assert SortTitle.key("The Élan Quarry") == "elan quarry"
    end

    test "nil keys to the empty string" do
      assert SortTitle.key(nil) == ""
    end
  end
end
