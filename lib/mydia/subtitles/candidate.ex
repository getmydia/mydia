defmodule Mydia.Subtitles.Candidate do
  @moduledoc """
  Signs and verifies subtitle search candidates.

  The download mutation accepts a token rather than a raw provider file id. Left
  to itself a client could otherwise ask the server to fetch any file the
  provider will serve and write it into the library. Signing means the server
  trusts only what it issued, and being stateless it survives a restart, unlike
  an ETS cache.
  """

  @salt "subtitle candidate"
  @max_age 900

  @fields [
    :provider_id,
    :provider_name,
    :file_id,
    :language,
    :format,
    :subtitle_hash,
    :rating,
    :download_count,
    :hearing_impaired
  ]

  @doc """
  Signs a search result for a media file, returning an opaque token.
  """
  @spec sign(binary(), map()) :: String.t()
  def sign(media_file_id, result) do
    payload =
      result
      |> Map.take(@fields)
      |> Map.put(:media_file_id, media_file_id)

    Phoenix.Token.sign(MydiaWeb.Endpoint, @salt, payload, max_age: @max_age)
  end

  @doc """
  Verifies a token and confirms it was issued for `media_file_id`.

  The `:max_age` option exists so tests can force expiry deterministically
  instead of sleeping. Callers outside this module's own tests must not pass
  it: threading a caller-supplied `:max_age` through would let a client
  control how long its own tokens stay valid.
  """
  @spec verify(String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, :expired | :invalid | :media_file_mismatch}
  def verify(token, media_file_id, opts \\ []) do
    max_age = Keyword.get(opts, :max_age, @max_age)

    case Phoenix.Token.verify(MydiaWeb.Endpoint, @salt, token, max_age: max_age) do
      {:ok, %{media_file_id: ^media_file_id} = payload} -> {:ok, payload}
      {:ok, %{media_file_id: _other}} -> {:error, :media_file_mismatch}
      {:ok, _malformed} -> {:error, :invalid}
      {:error, :expired} -> {:error, :expired}
      {:error, _reason} -> {:error, :invalid}
    end
  end
end
