defmodule Mydia.SystemTest do
  use ExUnit.Case, async: true

  alias Mydia.System, as: MydiaSystem

  describe "version_with_commit/2" do
    test "returns the base version without a commit" do
      assert MydiaSystem.version_with_commit("1.2.3", nil) == "1.2.3"
      assert MydiaSystem.version_with_commit("1.2.3", "") == "1.2.3"
    end

    test "appends the short commit" do
      assert MydiaSystem.version_with_commit("1.2.3", "abcdef0123456") == "1.2.3*abcdef0"
    end
  end

  describe "normalize_commit/1" do
    test "treats an empty commit as absent" do
      assert MydiaSystem.normalize_commit("") == nil
      assert MydiaSystem.normalize_commit(nil) == nil
      assert MydiaSystem.normalize_commit("abc") == "abc"
    end
  end

  test "dev_env?/1 is true only for :dev" do
    assert MydiaSystem.dev_env?(:dev)
    refute MydiaSystem.dev_env?(:prod)
  end
end
