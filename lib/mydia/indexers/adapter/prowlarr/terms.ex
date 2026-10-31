defmodule Mydia.Indexers.Adapter.Prowlarr.Terms do
  @moduledoc """
  Tracker terms for `Mydia.Indexers.Adapter.Prowlarr` results.

  Prowlarr's search JSON carries no volume factors or seeding minimums
  (`ReleaseResource.cs`), only the flags it derives from the factors
  (`IndexerFlag.cs`: freeleech is a download factor of 0, halfleech 0.5,
  neutralleech 0 both ways, doubleupload an upload factor of 2). `terms/2`
  maps those back, reading the explicit keys first in case a Prowlarr version
  adds them.

  Search results do not say whether a tracker is private either; Prowlarr's
  indexer list does. `privacy_by_indexer_id/2` reads it through
  `Mydia.Indexers.Adapter.ProwlarrPrivacy`, so at most once an hour per
  connection, and only when there are results to mark. Test config turns the
  lookup off (`:prowlarr_privacy_lookup`) so every Bypass search stub does not
  also need an indexer-list stub; `options.privacy_lookup` overrides it.
  """

  require Logger

  alias Mydia.Indexers.Adapter.{Prowlarr, ProwlarrPrivacy}
  alias Mydia.Indexers.Structs.TrackerTerms

  @connect_timeout 10_000

  @doc "Privacy by Prowlarr indexer id for a search response body."
  @spec privacy_by_indexer_id(map(), term()) :: %{integer() => boolean()}
  def privacy_by_indexer_id(config, [_ | _]) do
    if privacy_lookup?(config) do
      key =
        {config.host, config.port, get_in(config, [:options, :base_path]),
         :erlang.phash2(config.api_key)}

      ProwlarrPrivacy.lookup(key, fn -> fetch_privacy(config) end)
    else
      %{}
    end
  end

  def privacy_by_indexer_id(_config, _body), do: %{}

  defp privacy_lookup?(config) do
    case get_in(config, [:options, :privacy_lookup]) do
      nil -> Application.get_env(:mydia, :prowlarr_privacy_lookup, true)
      value -> value == true
    end
  end

  defp fetch_privacy(config) do
    case Req.get(Prowlarr.build_url(config, "/api/v1/indexer"),
           headers: Prowlarr.build_headers(config),
           receive_timeout: 5_000,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        privacy =
          for %{"id" => id, "privacy" => privacy} <- body,
              is_integer(id),
              privacy in ["public", "private", "semiPrivate"],
              into: %{},
              do: {id, privacy != "public"}

        {:ok, privacy}

      other ->
        Logger.debug("Prowlarr indexer privacy lookup failed: #{inspect(other, limit: 3)}")
        :error
    end
  end

  @doc "The terms of one search result item, given the connection's privacy map."
  @spec terms(map(), %{integer() => boolean()}) :: TrackerTerms.t() | nil
  def terms(item, privacy) do
    flags = item |> Map.get("indexerFlags") |> List.wrap() |> Enum.map(&flag_name/1)

    %TrackerTerms{
      private?: Map.get(privacy, item["indexerId"]),
      minimum_ratio: TrackerTerms.parse_float(item["minimumRatio"]),
      minimum_seed_time: TrackerTerms.parse_seconds(item["minimumSeedTime"]),
      download_volume_factor:
        TrackerTerms.parse_float(item["downloadVolumeFactor"]) || flag_download_factor(flags),
      upload_volume_factor:
        TrackerTerms.parse_float(item["uploadVolumeFactor"]) || flag_upload_factor(flags)
    }
    |> TrackerTerms.nil_if_empty()
  end

  defp flag_name(flag) when is_binary(flag), do: String.downcase(flag)
  defp flag_name(%{"name" => name}) when is_binary(name), do: String.downcase(name)
  defp flag_name(_flag), do: nil

  defp flag_download_factor(flags) do
    cond do
      "freeleech" in flags or "neutralleech" in flags -> 0.0
      "halfleech" in flags -> 0.5
      true -> nil
    end
  end

  defp flag_upload_factor(flags) do
    cond do
      "neutralleech" in flags -> 0.0
      "doubleupload" in flags -> 2.0
      true -> nil
    end
  end
end
