defmodule Mydia.Repo.Migrations.QualityProfileBackfillTest do
  use ExUnit.Case, async: true

  alias Mydia.Repo.Migrations.QualityProfileBackfill, as: M

  describe "backfilled_standards/2" do
    test "fills preferred_resolutions from qualities when standards lack it" do
      result = M.backfilled_standards(["720p", "1080p"], %{})
      assert result["preferred_resolutions"] == ["720p", "1080p"]
    end

    test "derives min/max resolution from qualities when absent" do
      result = M.backfilled_standards(["720p", "1080p", "2160p"], %{})
      assert result["min_resolution"] == "720p"
      assert result["max_resolution"] == "2160p"
    end

    test "keeps existing non-empty preferred_resolutions untouched" do
      standards = %{"preferred_resolutions" => ["1080p"], "min_resolution" => "1080p"}
      assert M.backfilled_standards(["720p", "2160p"], standards) == standards
    end

    test "handles nil standards" do
      result = M.backfilled_standards(["1080p"], nil)
      assert result["preferred_resolutions"] == ["1080p"]
    end

    test "ignores unknown resolution tokens when deriving min/max but keeps them in the list" do
      result = M.backfilled_standards(["weird", "1080p"], %{})
      assert result["preferred_resolutions"] == ["weird", "1080p"]
      assert result["min_resolution"] == "1080p"
      assert result["max_resolution"] == "1080p"
    end

    test "falls back to a full resolution list when qualities is empty" do
      result = M.backfilled_standards([], %{})
      assert result["preferred_resolutions"] == ["360p", "480p", "576p", "720p", "1080p", "2160p"]
    end
  end
end
