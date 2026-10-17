defmodule MetadataRelay.UpdateCheck.Handler do
  @moduledoc """
  `POST /update-check`: a Mydia install asks whether a newer release exists.

  Request body, JSON, every field required:

      {"install_id": "<64 hex chars>", "version": "0.16.0",
       "arch": "x86_64-pc-linux-musl", "db": "sqlite"}

  Response, `200`:

      {"latest_version": "0.16.1", "release_url": "https://github.com/..."}

  Both values are `null` while no release is known. A body that fails
  validation gets `400` and is not recorded.

  There is no rate limit. Behind Cloudflare every caller resolves to a shared
  edge address (see `MetadataRelay.ClientIp`), so an address limit would
  throttle real installs against each other, and the endpoint stores at most
  one small row per install id per week.
  """

  import Plug.Conn

  require Logger

  alias MetadataRelay.{Metrics, UpdateCheck}
  alias MetadataRelay.UpdateCheck.Releases

  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    case record(conn.body_params) do
      {:ok, version} ->
        Metrics.inc("metadata_relay_update_checks_total")
        respond(conn, 200, latest_body(version))

      {:error, %Ecto.Changeset{} = changeset} ->
        respond(conn, 400, %{error: "Validation failed", fields: invalid_fields(changeset)})
    end
  end

  # Storage trouble is ours, not the install's, so a check that validated is
  # still answered when the write raises.
  defp record(params) do
    case UpdateCheck.record(params) do
      {:ok, record} -> {:ok, record.version}
      {:error, _changeset} = error -> error
    end
  rescue
    error ->
      Logger.error("[UpdateCheck] Failed to record a check: " <> Exception.message(error))
      {:ok, params["version"]}
  end

  defp latest_body(client_version) do
    case Releases.latest_for(client_version) do
      nil -> %{latest_version: nil, release_url: nil}
      release -> %{latest_version: release.version, release_url: release.url}
    end
  end

  defp invalid_fields(changeset), do: changeset.errors |> Keyword.keys() |> Enum.uniq()

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
