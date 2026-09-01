defmodule Mydia.Jobs.ApplyImportCandidatesTest do
  # Promotion runs through Mydia.MetadataStubProvider, a process-global
  # registration -- see Mydia.MetadataStub's moduledoc for why every test that
  # relies on it must run synchronously.
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Jobs.ApplyImportCandidates
  alias Mydia.Library.ImportCandidate
  alias Mydia.Repo

  setup :setup_metadata_stub

  defp queue(candidate) do
    candidate
    |> Ecto.Changeset.change(%{
      queued_op: "accept",
      queued_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  describe "drain_accepted/2" do
    test "promotes a queued group and removes its candidates" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: "9001",
          title: "Wandering Aurora",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      assert {:ok, %{promoted: 1, failed: 0, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      refute Repo.get(ImportCandidate, candidate.id)
    end

    test "a group with no provider match clears its marker and records why" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Unknown Folder/file.mkv"
        })
        |> queue()

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id)

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)
      assert reloaded.queue_error == "No provider match to import from."
    end

    test "a group whose files match different titles clears its marker" do
      lp = library_path_fixture(%{type: "series"})

      for {path, provider_id} <- [{"Split Anchor/a.mkv", "9001"}, {"Split Anchor/b.mkv", "9002"}] do
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: path,
          provider_type: "tvdb",
          provider_id: provider_id,
          media_type: "tv_show",
          confidence: 0.9
        })
        |> queue()
      end

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id)

      assert [error | _] =
               ImportCandidate
               |> Ecto.Query.where([c], c.library_path_id == ^lp.id)
               |> Repo.all()
               |> Enum.map(& &1.queue_error)

      assert error == "Files in this folder match different titles."
    end

    test "drains more groups than one anchor page holds" do
      lp = library_path_fixture(%{type: "series"})

      # All three anchors resolve through Mydia.MetadataStubProvider, whose
      # catalog has exactly one series -- see its moduledoc. Sharing that
      # series' id (rather than three distinct ones the stub cannot
      # differentiate) keeps each promotion from racing to create a second
      # media item with the same tvdb id; each anchor still stays its own
      # group, and each candidate targets a distinct episode of that series.
      series_id = to_string(Mydia.MetadataStubProvider.series_tvdb_id())

      for n <- 1..3 do
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Show #{n}/s01e0#{n}.mkv",
          provider_type: "tvdb",
          provider_id: series_id,
          title: "Show #{n}",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [n]}
        })
        |> queue()
      end

      assert {:ok, %{promoted: 3, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 anchor_page_size: 1,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )
    end

    test "promotes only the queued rows of a mixed anchor" do
      lp = library_path_fixture(%{type: "series"})

      queued =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: "9001",
          title: "Wandering Aurora",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      # What a scan discovering a new file mid-drain leaves behind: a pending
      # row under an anchor whose import is already under way.
      newcomer =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e02.mkv"
        })

      assert newcomer.anchor_key == queued.anchor_key

      assert {:ok, %{promoted: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      refute Repo.get(ImportCandidate, queued.id)
      assert Repo.get(ImportCandidate, newcomer.id)
    end

    test "a library with nothing queued is a no-op" do
      lp = library_path_fixture(%{type: "series"})

      assert {:ok, %{promoted: 0, failed: 0, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id)
    end
  end

  describe "perform/1" do
    test "returns :ok when everything drained" do
      lp = library_path_fixture(%{type: "series"})

      assert :ok =
               ApplyImportCandidates.perform(%Oban.Job{
                 args: %{"library_path_id" => lp.id}
               })
    end
  end
end
