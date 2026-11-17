defmodule Mydia.Config.Schema.Proxy do
  @moduledoc """
  The `proxy` section of `Mydia.Config.Schema`: an outbound HTTP proxy.

  `bypass` is a comma-separated list of hosts that skip the proxy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :url, :string
    field :bypass, :string
  end

  @type t :: %__MODULE__{url: String.t() | nil, bypass: String.t() | nil}

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:url, :bypass])
    |> validate_proxy_url()
  end

  # The same parser routing uses (`Mydia.Net.Proxy.parse_url/1`), so a URL
  # this accepts is never one the proxy then ignores. Messages never echo the
  # URL, which may carry credentials.
  defp validate_proxy_url(changeset) do
    # Trimmed like `Mydia.Net.Proxy.effective/2` trims it.
    validate_change(changeset, :url, fn :url, url ->
      url = String.trim(url)
      if url == "", do: [], else: url |> Mydia.Net.Proxy.parse_url() |> url_errors()
    end)
  end

  defp url_errors({:ok, _uri}), do: []
  defp url_errors({:error, :invalid_port}), do: [url: "must have a port from 1 to 65535"]
  defp url_errors({:error, _}), do: [url: "must be an http:// or https:// proxy URL with a host"]
end
