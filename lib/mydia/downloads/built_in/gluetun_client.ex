defmodule Mydia.Downloads.BuiltIn.GluetunClient do
  @moduledoc "Reads gluetun's control server (`/v1/...`, `X-API-Key` auth)."

  def new(base_url, api_key) do
    Req.new(
      base_url: base_url,
      headers: [{"x-api-key", api_key}],
      retry: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 2_000]
    )
  end

  def vpn_status(req), do: get(req, "/v1/vpn/status", "status")
  def public_ip(req), do: get(req, "/v1/publicip/ip", "public_ip")

  def forwarded_port(req) do
    case get(req, "/v1/portforward", "port") do
      {:ok, nil} -> {:ok, 0}
      other -> other
    end
  end

  defp get(req, path, key) do
    case Req.get(req, url: path) do
      {:ok, %Req.Response{status: 200, body: body}} -> field(body, key)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  # Gluetun encodes with json.Encoder and may not send a JSON content type, so
  # Req can hand back the raw string.
  defp field(%{} = body, key), do: {:ok, Map.get(body, key)}

  defp field(body, key) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, Map.get(decoded, key)}
      _ -> {:error, :invalid_json}
    end
  end

  # A JSON array or scalar decoded by Req (when gluetun does send a JSON content
  # type) is not a status object.
  defp field(_body, _key), do: {:error, :invalid_json}
end
