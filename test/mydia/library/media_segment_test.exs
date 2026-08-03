defmodule Mydia.Library.MediaSegmentTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Library.MediaSegment
  alias Mydia.Repo

  defp valid_attrs(media_file) do
    %{
      media_file_id: media_file.id,
      type: "intro",
      start_ms: 30_000,
      end_ms: 90_000,
      source: "fingerprint",
      confidence: 0.8
    }
  end

  test "inserts a valid segment" do
    media_file = media_file_fixture()

    assert {:ok, segment} =
             %MediaSegment{} |> MediaSegment.changeset(valid_attrs(media_file)) |> Repo.insert()

    assert segment.type == "intro"
    assert segment.start_ms == 30_000
  end

  test "rejects an unknown type" do
    media_file = media_file_fixture()
    attrs = %{valid_attrs(media_file) | type: "recap"}

    assert {:error, changeset} = %MediaSegment{} |> MediaSegment.changeset(attrs) |> Repo.insert()
    assert %{type: _} = errors_on(changeset)
  end

  test "rejects an unknown source" do
    media_file = media_file_fixture()
    attrs = %{valid_attrs(media_file) | source: "guesswork"}

    assert {:error, changeset} = %MediaSegment{} |> MediaSegment.changeset(attrs) |> Repo.insert()
    assert %{source: _} = errors_on(changeset)
  end

  test "rejects end_ms not after start_ms" do
    media_file = media_file_fixture()
    attrs = %{valid_attrs(media_file) | start_ms: 90_000, end_ms: 90_000}

    assert {:error, changeset} = %MediaSegment{} |> MediaSegment.changeset(attrs) |> Repo.insert()
    assert %{end_ms: _} = errors_on(changeset)
  end

  test "rejects confidence outside 0.0..1.0" do
    media_file = media_file_fixture()
    attrs = %{valid_attrs(media_file) | confidence: 1.5}

    assert {:error, changeset} = %MediaSegment{} |> MediaSegment.changeset(attrs) |> Repo.insert()
    assert %{confidence: _} = errors_on(changeset)
  end

  test "enforces one segment per type per file" do
    media_file = media_file_fixture()
    attrs = valid_attrs(media_file)

    assert {:ok, _} = %MediaSegment{} |> MediaSegment.changeset(attrs) |> Repo.insert()
    assert {:error, changeset} = %MediaSegment{} |> MediaSegment.changeset(attrs) |> Repo.insert()
    assert %{media_file_id: _} = errors_on(changeset)
  end

  test "deletes segments when the media file is deleted" do
    media_file = media_file_fixture()

    {:ok, segment} =
      %MediaSegment{} |> MediaSegment.changeset(valid_attrs(media_file)) |> Repo.insert()

    Repo.delete!(media_file)

    refute Repo.get(MediaSegment, segment.id)
  end

  test "media files default to pending segment analysis state" do
    media_file = media_file_fixture()

    assert media_file.segment_analysis_state == "pending"
    assert media_file.segment_analysis_attempts == 0
    assert is_nil(media_file.segments_analyzed_at)
    assert is_nil(media_file.fingerprint_blob)
  end
end
