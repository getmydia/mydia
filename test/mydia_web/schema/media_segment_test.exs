defmodule MydiaWeb.Schema.MediaSegmentTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaSegment
  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias MydiaWeb.Schema.Resolvers.MediaResolver

  @movie_segments_query """
  query Movie($id: ID!) {
    movie(id: $id) {
      id
      files {
        id
        segments {
          type
          startMs
          endMs
        }
      }
    }
  }
  """

  @movie_segment_confidence_query """
  query Movie($id: ID!) {
    movie(id: $id) {
      files {
        segments {
          type
          confidence
        }
      }
    }
  }
  """

  @movie_segment_source_query """
  query Movie($id: ID!) {
    movie(id: $id) {
      files {
        segments {
          type
          source
        }
      }
    }
  }
  """

  describe "confidence floor" do
    test "exposes segments above the floor" do
      media_file = media_file_fixture()
      insert_segment(media_file, %{confidence: 0.8})

      assert [segment] = visible_segments_for(media_file)
      assert segment.type == "intro"
      assert segment.start_ms == 30_000
    end

    test "hides segments below the floor" do
      media_file = media_file_fixture()
      insert_segment(media_file, %{confidence: 0.2})

      assert visible_segments_for(media_file) == []
    end

    test "exposes a segment at exactly the minimum consensus confidence" do
      # 2 agreeing partners out of 5 attempted is 0.4, the lowest value the
      # detection acceptance rule can produce. If the exposure floor rejected
      # this, every minimum-consensus detection would be invisible and the
      # acceptance rule would be unreachable in practice.
      media_file = media_file_fixture()
      insert_segment(media_file, %{confidence: 0.4})

      assert [_segment] = visible_segments_for(media_file)
    end

    test "hides a segment just below the minimum consensus confidence" do
      media_file = media_file_fixture()
      insert_segment(media_file, %{confidence: 0.39})

      assert visible_segments_for(media_file) == []
    end

    test "exposes chapter sourced segments, which the pipeline writes at full confidence" do
      media_file = media_file_fixture()
      insert_segment(media_file, %{source: "chapters", confidence: 1.0})

      assert [_segment] = visible_segments_for(media_file)
    end

    test "applies the floor uniformly, without a bypass for chapter sourced segments" do
      # The floor is deliberately a single condition on confidence, with no
      # exception by source. A chapter hit clears it because the detection
      # pipeline writes chapter matches at confidence 1.0, not because the
      # resolver treats `source` specially.
      #
      # Keeping it uniform means a chapter segment that somehow lands below the
      # floor disappears from the wire, which is the signal you want: it says
      # something wrote it wrong. A source bypass would mask exactly that bug
      # and split exposure across two rules.
      media_file = media_file_fixture()
      insert_segment(media_file, %{source: "chapters", confidence: 0.2})

      assert visible_segments_for(media_file) == []
    end

    test "preloads segments when the association has not been loaded" do
      media_file = media_file_fixture()
      insert_segment(media_file, %{confidence: 0.8})

      unloaded = Repo.get!(MediaFile, media_file.id)
      assert %Ecto.Association.NotLoaded{} = unloaded.segments

      assert [_segment] = MediaResolver.visible_segments(unloaded)
    end

    test "returns segments ordered by start position" do
      media_file = media_file_fixture()
      insert_segment(media_file, %{type: "credits", start_ms: 1_200_000, end_ms: 1_260_000})
      insert_segment(media_file, %{type: "intro", start_ms: 30_000, end_ms: 90_000})

      assert ["intro", "credits"] = Enum.map(visible_segments_for(media_file), & &1.type)
    end
  end

  describe "mediaFile.segments over GraphQL" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "returns detected segments on the file", %{user: user} do
      media_item = MediaFixtures.media_item_fixture(%{type: "movie"})
      media_file = MediaFixtures.media_file_fixture(%{media_item_id: media_item.id})
      insert_segment(media_file, %{type: "credits", start_ms: 1_200_000, end_ms: 1_260_000})

      assert {:ok, %{data: data}} =
               run_query(@movie_segments_query, %{"id" => media_item.id}, user)

      assert [%{"segments" => [segment]}] = data["movie"]["files"]

      assert segment == %{
               "type" => "CREDITS",
               "startMs" => 1_200_000,
               "endMs" => 1_260_000
             }
    end

    test "omits segments below the confidence floor", %{user: user} do
      media_item = MediaFixtures.media_item_fixture(%{type: "movie"})
      media_file = MediaFixtures.media_file_fixture(%{media_item_id: media_item.id})
      insert_segment(media_file, %{confidence: 0.2})

      assert {:ok, %{data: data}} =
               run_query(@movie_segments_query, %{"id" => media_item.id}, user)

      assert [%{"segments" => []}] = data["movie"]["files"]
    end

    test "returns an empty list when detection has not run", %{user: user} do
      media_item = MediaFixtures.media_item_fixture(%{type: "movie"})
      MediaFixtures.media_file_fixture(%{media_item_id: media_item.id})

      assert {:ok, %{data: data}} =
               run_query(@movie_segments_query, %{"id" => media_item.id}, user)

      assert [%{"segments" => []}] = data["movie"]["files"]
    end

    test "keeps confidence off the wire", %{user: user} do
      media_item = MediaFixtures.media_item_fixture(%{type: "movie"})

      assert {:ok, %{errors: errors}} =
               run_query(@movie_segment_confidence_query, %{"id" => media_item.id}, user)

      assert Enum.any?(errors, &(&1.message =~ "confidence"))
    end

    test "keeps source off the wire", %{user: user} do
      media_item = MediaFixtures.media_item_fixture(%{type: "movie"})

      assert {:ok, %{errors: errors}} =
               run_query(@movie_segment_source_query, %{"id" => media_item.id}, user)

      assert Enum.any?(errors, &(&1.message =~ "source"))
    end
  end

  defp media_file_fixture do
    media_item = MediaFixtures.media_item_fixture(%{type: "movie"})
    MediaFixtures.media_file_fixture(%{media_item_id: media_item.id})
  end

  defp insert_segment(media_file, attrs) do
    %MediaSegment{}
    |> MediaSegment.changeset(
      Map.merge(
        %{
          media_file_id: media_file.id,
          type: "intro",
          start_ms: 30_000,
          end_ms: 90_000,
          source: "fingerprint",
          confidence: 0.8
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp visible_segments_for(media_file) do
    MediaFile
    |> Repo.get!(media_file.id)
    |> Repo.preload(:segments)
    |> MediaResolver.visible_segments()
  end

  defp run_query(query, variables, user) do
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: %{current_user: user})
  end
end
