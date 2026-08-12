defmodule Mydia.Subtitles.CandidateTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Candidate

  @media_file_id "11111111-1111-1111-1111-111111111111"

  @result %{
    provider_id: "relay-default",
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
    assert payload.provider_id == "relay-default"
    assert payload.language == "en"
    assert payload.media_file_id == @media_file_id
  end

  test "rejects a token issued for a different media file" do
    token = Candidate.sign(@media_file_id, @result)
    other = "22222222-2222-2222-2222-222222222222"

    assert {:error, :media_file_mismatch} = Candidate.verify(token, other)
  end

  test "rejects a token whose payload was swapped under another signature" do
    token = Candidate.sign(@media_file_id, @result)
    other = Candidate.sign("22222222-2222-2222-2222-222222222222", @result)

    [protected, _payload, signature] = String.split(token, ".")
    [_, other_payload, _] = String.split(other, ".")
    forged = Enum.join([protected, other_payload, signature], ".")

    assert {:error, :invalid} = Candidate.verify(forged, @media_file_id)
  end

  test "rejects garbage" do
    assert {:error, :invalid} = Candidate.verify("not-a-token", @media_file_id)
  end

  test "rejects an expired token" do
    token = Candidate.sign(@media_file_id, @result)
    assert {:error, :expired} = Candidate.verify(token, @media_file_id, max_age: -1)
  end

  test "rejects a token whose payload lacks media_file_id" do
    bare_token = Phoenix.Token.sign(MydiaWeb.Endpoint, "subtitle candidate", %{file_id: 1})

    assert {:error, :invalid} = Candidate.verify(bare_token, @media_file_id)
  end

  test "defaults to a 900 second max age when the caller supplies none" do
    stale_token =
      Phoenix.Token.sign(
        MydiaWeb.Endpoint,
        "subtitle candidate",
        %{media_file_id: @media_file_id},
        signed_at: System.system_time(:second) - 901
      )

    assert {:error, :expired} = Candidate.verify(stale_token, @media_file_id)
  end
end
