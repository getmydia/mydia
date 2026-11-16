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

  defp validate_proxy_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      if url == "" or valid_proxy_url?(url) do
        []
      else
        [url: "must be an http:// or https:// proxy URL with a host"]
      end
    end)
  end

  defp valid_proxy_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end
end
