defmodule Mydia.Library.PathMappingSuggestionTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.PathMapping

  setup do
    tmp = Path.join(System.tmp_dir!(), "pms_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  test "suggests a single mapping when exactly one match is found (AE1)", %{tmp: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join([root, "torrents", "complete", "Severance.S02E10"]))

    assert {:ok, %{remote_prefix: "/downloads/complete", local_prefix: local}} =
             PathMapping.suggest("/downloads/complete/Severance.S02E10", [root])

    assert local == Path.join([root, "torrents", "complete"])
  end

  test "abstains when the deciding suffix matches under two roots (AE3)", %{tmp: tmp} do
    root_a = Path.join(tmp, "a")
    root_b = Path.join(tmp, "b")
    File.mkdir_p!(Path.join([root_a, "complete", "Show.S01E01"]))
    File.mkdir_p!(Path.join([root_b, "complete", "Show.S01E01"]))

    assert PathMapping.suggest("/downloads/complete/Show.S01E01", [root_a, root_b]) == :none
  end

  test "abstains when no match is found", %{tmp: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join(root, "unrelated"))

    assert PathMapping.suggest("/downloads/complete/Missing.S01E01", [root]) == :none
  end

  test "derives prefixes correctly when the local dir nests deeper than the remote", %{tmp: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join([root, "media", "tv", "downloads", "Release"]))

    assert {:ok, %{remote_prefix: "/dl", local_prefix: local}} =
             PathMapping.suggest("/dl/Release", [root])

    assert local == Path.join([root, "media", "tv", "downloads"])
  end

  describe "suffix join" do
    test "finds the release by joining a root with the reported path's tail", %{tmp: tmp} do
      root = Path.join(tmp, "data")
      File.mkdir_p!(Path.join([root, "downloads", "complete", "Fictional.Salt.Meridian.S01E01"]))

      assert PathMapping.suggest(
               "/downloads/complete/Fictional.Salt.Meridian.S01E01",
               [root],
               # Zero walk budget: only the suffix join can produce this match.
               max_scan_dirs: 0
             ) ==
               {:ok,
                %{
                  remote_prefix: "/downloads/complete",
                  local_prefix: Path.join([root, "downloads", "complete"])
                }}
    end

    test "prefers the longest matching tail over a basename-only match", %{tmp: tmp} do
      root_a = Path.join(tmp, "a")
      root_b = Path.join(tmp, "b")
      File.mkdir_p!(Path.join([root_a, "complete", "Show.S01E01"]))
      File.mkdir_p!(Path.join([root_b, "Show.S01E01"]))

      assert {:ok, %{local_prefix: local}} =
               PathMapping.suggest("/downloads/complete/Show.S01E01", [root_a, root_b])

      assert local == Path.join(root_a, "complete")
    end

    test "never joins a tail containing ..", %{tmp: tmp} do
      root = Path.join(tmp, "data")
      File.mkdir_p!(Path.join(root, "Release"))

      assert PathMapping.suggest("/dl/../Release", [root], max_scan_dirs: 0) == :none
    end
  end

  describe "walk budgets" do
    setup %{tmp: tmp} do
      root = Path.join(tmp, "data")

      for n <- 1..5 do
        File.mkdir_p!(Path.join([root, "d#{n}", "deep"]))
      end

      File.mkdir_p!(Path.join([root, "d5", "deep", "Release"]))
      {:ok, root: root}
    end

    test "finds the release when the budget is large enough", %{root: root} do
      assert {:ok, %{local_prefix: local}} = PathMapping.suggest("/remote/Release", [root])
      assert local == Path.join([root, "d5", "deep"])
    end

    test "returns :none when the directory budget runs out", %{root: root} do
      assert PathMapping.suggest("/remote/Release", [root], max_scan_dirs: 2) == :none
    end

    test "returns :none when the time budget runs out", %{root: root} do
      assert PathMapping.suggest("/remote/Release", [root], max_scan_ms: 0) == :none
    end
  end

  describe "suggestion_attrs/2" do
    test "stores the match and stamps the search", %{tmp: tmp} do
      root = Path.join(tmp, "data")
      File.mkdir_p!(Path.join([root, "complete", "Release"]))

      attrs = PathMapping.suggestion_attrs("/downloads/complete/Release", [root])

      assert attrs.path_mapping_remote_prefix == "/downloads/complete"
      assert attrs.path_mapping_local_prefix == Path.join(root, "complete")
      assert %DateTime{} = attrs.path_mapping_searched_at
    end

    test "stamps the search with null prefixes when nothing matches", %{tmp: tmp} do
      attrs = PathMapping.suggestion_attrs("/downloads/complete/Release", [tmp])

      assert attrs.path_mapping_remote_prefix == nil
      assert attrs.path_mapping_local_prefix == nil
      assert %DateTime{} = attrs.path_mapping_searched_at
    end

    test "uses the configured roots, which the test config empties" do
      assert PathMapping.search_roots() == []
    end
  end
end
