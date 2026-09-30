defmodule Mydia.Plugins.Endpoints do
  @moduledoc """
  An instance's effective egress endpoints.

  Two sources feed an instance's approved endpoints, and both are operator
  actions:

    * `Instance.approved_endpoints`, written when the operator picks a server in
      a setup `choice` step or confirms rediscovered endpoints, and
    * the URL values of the instance's host-granting settings
      (`grants_host: true` in the manifest's `settings_schema`), which the
      operator typed.

  `Mydia.Plugins.Net.Gate` admits a request to an approved endpoint even when
  it resolves to a private address. A guest has no import that writes here.
  """

  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin
  alias Mydia.Settings

  @type endpoint :: %{String.t() => String.t() | pos_integer()}

  @doc "Parses an http(s) URL into an endpoint, filling the default port."
  @spec from_url(String.t()) :: {:ok, endpoint()} | :error
  def from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) ->
        {:ok, %{"scheme" => scheme, "host" => String.downcase(host), "port" => port}}

      _ ->
        :error
    end
  end

  def from_url(_), do: :error

  @doc "Validates and normalizes a stored endpoint map."
  @spec normalize(map()) :: {:ok, endpoint()} | :error
  def normalize(%{"scheme" => scheme, "host" => host, "port" => port})
      when scheme in ["http", "https"] and is_binary(host) and host != "" do
    case to_port(port) do
      nil -> :error
      p -> {:ok, %{"scheme" => scheme, "host" => String.downcase(host), "port" => p}}
    end
  end

  def normalize(%{scheme: s, host: h, port: p}),
    do: normalize(%{"scheme" => s, "host" => h, "port" => p})

  def normalize(_), do: :error

  @doc "The instance's approved endpoints plus those its host-granting settings imply."
  @spec effective(Plugin.t(), Instance.t() | nil) :: [endpoint()]
  def effective(%Plugin{}, nil), do: []

  def effective(%Plugin{slug: slug}, %Instance{} = instance) do
    stored =
      instance.approved_endpoints
      |> List.wrap()
      |> Enum.flat_map(&ok_list(normalize(&1)))

    from_settings =
      slug
      |> host_granting_keys()
      |> Enum.map(&Map.get(instance.settings || %{}, &1))
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&ok_list(from_url(&1)))

    Enum.uniq(stored ++ from_settings)
  end

  @doc "Gate options for a request made on behalf of `instance`."
  @spec gate_opts(Plugin.t(), Instance.t() | nil) ::
          [allowed_hosts: [String.t()], approved_endpoints: [endpoint()]]
  def gate_opts(%Plugin{} = plugin, instance) do
    [
      allowed_hosts: Plugin.granted_http_hosts(plugin),
      approved_endpoints: effective(plugin, instance)
    ]
  end

  defp host_granting_keys(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{manifest: %{"settings_schema" => schema}} -> Manifest.host_granting_keys(schema)
      _ -> []
    end
  end

  defp to_port(p) when is_integer(p) and p > 0 and p < 65_536, do: p

  defp to_port(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} -> to_port(n)
      _ -> nil
    end
  end

  defp to_port(_), do: nil

  defp ok_list({:ok, v}), do: [v]
  defp ok_list(:error), do: []
end
