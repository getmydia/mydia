defmodule Mydia.Jobs.MediaImport.FileImportTest do
  use ExUnit.Case, async: true

  alias Mydia.Jobs.MediaImport.FileImport

  defp download(extra) do
    %{id: "dl-1", title: "Some.Show.S01", metadata: Map.merge(%{"episode_count" => 10}, extra)}
  end

  defp files(n), do: for(i <- 1..n, do: %{episode_id: "ep-#{i}"})

  describe "detect_partial_pack/2" do
    test "skipped owned episodes do not count against the pack" do
      dl = download(%{"skipped_owned_episode_ids" => ["a", "b", "c", "d"]})

      assert FileImport.detect_partial_pack(dl, files(6)) == nil
      assert FileImport.detect_partial_pack(dl, files(5)) == "partial_pack"
    end

    test "absent skipped list behaves as before" do
      assert FileImport.detect_partial_pack(download(%{}), files(10)) == nil
      assert FileImport.detect_partial_pack(download(%{}), files(9)) == "partial_pack"
    end
  end
end
