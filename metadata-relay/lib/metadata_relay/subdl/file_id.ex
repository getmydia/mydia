defmodule MetadataRelay.SubDL.FileId do
  @moduledoc """
  Encodes a SubDL archive path as the opaque `id` the subtitle contract carries.

  SubDL has no stable numeric file id. It returns only an archive path such as
  `/subtitle/3602674-8520054.zip`, so encoding that path is what keeps
  `download-url/:id` and `download/:id` stateless, with no database and no
  dependence on a cache entry surviving between two requests.

  Decoding is a trust boundary. The id arrives from the public internet and the
  relay fetches whatever it decodes to, so an unvalidated decode would turn the
  download route into an open proxy for arbitrary URLs. Only a path of the exact
  shape `/subtitle/<name>.zip` is accepted, and the name may not contain a
  slash, which rules out traversal without needing to reason about it.
  """

  # No slash in the name, so "/subtitle/../.." cannot match.
  @path_pattern ~r{\A/subtitle/[A-Za-z0-9._-]+\.zip\z}

  @spec encode(String.t()) :: String.t()
  def encode(url) when is_binary(url) do
    url
    |> strip_query()
    |> Base.url_encode64(padding: false)
  end

  @spec decode(term()) :: {:ok, String.t()} | {:error, :invalid_file_id}
  def decode(id) when is_binary(id) do
    with {:ok, path} <- Base.url_decode64(id, padding: false),
         true <- Regex.match?(@path_pattern, path) do
      {:ok, path}
    else
      _ -> {:error, :invalid_file_id}
    end
  end

  def decode(_id), do: {:error, :invalid_file_id}

  # SubDL appends the API key used for the search onto every result url.
  # Dropping the query string here is the single point that keeps the relay's
  # key out of responses.
  defp strip_query(url), do: url |> String.split("?") |> hd()
end
