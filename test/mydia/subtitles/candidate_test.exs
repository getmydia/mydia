defmodule Mydia.Subtitles.CandidateTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Candidate

  @media_file_id "11111111-1111-1111-1111-111111111111"

  @result %{
    provider_id: "33333333-3333-3333-3333-333333333333",
    provider_type: :relay,
    provider_name: "Mydia Relay",
    file_id: 12_345,
    language: "en",
    format: "srt",
    subtitle_hash: "abc123",
    rating: 8.5,
    download_count: 4200,
    hearing_impaired: false
  }

  test "round trips a candidate" do
    token = Candidate.sign(@media_file_id, @result)
    assert {:ok, payload} = Candidate.verify(token, @media_file_id)

    assert payload.file_id == 12_345
    assert payload.provider_id == "33333333-3333-3333-3333-333333333333"
    assert payload.provider_type == :relay
    assert payload.language == "en"
    assert payload.media_file_id == @media_file_id
  end

  test "carries the provider type so a deleted config still resolves an adapter" do
    token = Candidate.sign(@media_file_id, @result)
    assert {:ok, payload} = Candidate.verify(token, @media_file_id)

    assert payload.provider_type == :relay
  end

  test "rejects a token issued for a different media file" do
    token = Candidate.sign(@media_file_id, @result)
    other = "22222222-2222-2222-2222-222222222222"

    assert {:error, :media_file_mismatch} = Candidate.verify(token, other)
  end

  # Tamper in the middle, not at the end. A trailing Base64 character can carry
  # as few as two significant bits, so replacing it often decodes to identical
  # bytes and the signature still verifies. Phoenix.Token embeds a timestamp, so
  # the alignment shifts between runs: an end-tamper test passes on most seeds
  # and quietly proves nothing on the rest. Seed 4242 caught it.
  test "rejects a tampered token" do
    token = Candidate.sign(@media_file_id, @result)

    middle = div(byte_size(token), 2)
    <<head::binary-size(middle), original::binary-size(1), tail::binary>> = token
    replacement = if original == "A", do: "B", else: "A"
    tampered = head <> replacement <> tail

    refute tampered == token
    assert {:error, :invalid} = Candidate.verify(tampered, @media_file_id)
  end

  test "rejects garbage" do
    assert {:error, :invalid} = Candidate.verify("not-a-token", @media_file_id)
  end

  test "rejects an expired token" do
    token = Candidate.sign(@media_file_id, @result)
    assert {:error, :expired} = Candidate.verify(token, @media_file_id, max_age: -1)
  end
end
