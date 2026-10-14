defmodule Mydia.Indexers.Cardigann.EngineSupportTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.EngineSupport

  test "lists the engines a definition was verified on" do
    assert EngineSupport.verified_engines("anibt") == [:builtin, :prowlarr]
    assert EngineSupport.verified_engines("nyaasi") == [:prowlarr]
  end

  test "an unknown definition is verified on nothing" do
    assert EngineSupport.verified_engines("no-such-tracker") == []
  end

  test "only_on/2 keeps the ids verified on that engine alone" do
    assert EngineSupport.only_on(:prowlarr, ["anibt", "nyaasi", "no-such-tracker"]) == ["nyaasi"]
    assert EngineSupport.only_on(:builtin, ["anibt", "nyaasi"]) == []
  end

  test "names the bench date" do
    assert %Date{} = EngineSupport.verified_on()
  end

  describe "verification/2" do
    test "verified when the active engine is in the list" do
      assert EngineSupport.verification("anibt", :builtin) == :verified
      assert EngineSupport.verification("nyaasi", :prowlarr) == :verified
    end

    test "other_only when only the inactive engine is verified" do
      assert EngineSupport.verification("nyaasi", :builtin) == {:other_only, :prowlarr}
    end

    test "unverified when nothing is listed" do
      assert EngineSupport.verification("no-such-tracker", :builtin) == :unverified
    end
  end
end
