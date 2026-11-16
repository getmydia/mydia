defmodule Mydia.Net.Proxy.Bypass do
  @moduledoc """
  Parsing and matching of proxy bypass entries, using curl `NO_PROXY` semantics.

  Supported entries: `*`, `example.com` / `.example.com` (the domain and all its
  subdomains), an IP literal, and a CIDR such as `10.0.0.0/8` or `fd00::/8`.
  Matching is case-insensitive and ignores a trailing dot and any port. Nothing
  here performs DNS lookups.
  """

  import Bitwise
  import Kernel, except: [match?: 2]

  @type entry ::
          :any
          | {:domain, String.t()}
          | {:ip, :inet.ip_address()}
          | {:cidr, :inet.ip_address(), non_neg_integer()}

  @doc "Parses a comma-separated bypass string. Malformed entries are dropped."
  @spec parse(String.t() | nil) :: [entry()]
  def parse(nil), do: []

  def parse(string) when is_binary(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_entry/1)
  end

  defp parse_entry("*"), do: [:any]

  defp parse_entry(raw) do
    entry = raw |> bracketless() |> String.downcase()

    if String.contains?(entry, "/") do
      parse_cidr(entry)
    else
      case parse_ip(entry) do
        {:ok, ip} -> [{:ip, ip}]
        _ -> parse_domain(entry)
      end
    end
  end

  defp parse_cidr(entry) do
    with [addr, bits] <- String.split(entry, "/", parts: 2),
         {:ok, ip} <- parse_ip(addr),
         {bits, ""} <- Integer.parse(bits),
         true <- bits >= 0 and bits <= tuple_size(ip) * if(tuple_size(ip) == 4, do: 8, else: 16) do
      [{:cidr, ip, bits}]
    else
      _ -> []
    end
  end

  defp parse_domain(entry) do
    domain =
      entry
      |> strip_port()
      |> String.trim_leading(".")
      |> String.trim_trailing(".")

    if domain == "", do: [], else: [{:domain, domain}]
  end

  @doc "Returns true when `host` (already stripped of any port) matches an entry."
  @spec match?(String.t(), [entry()]) :: boolean()
  def match?(host, entries) when is_binary(host) do
    host = normalize_host(host)
    ip = host_ip(host)
    Enum.any?(entries, &entry_match?(&1, host, ip))
  end

  defp entry_match?(:any, _host, _ip), do: true
  defp entry_match?({:domain, d}, host, _ip), do: host == d or String.ends_with?(host, "." <> d)
  defp entry_match?({:ip, ip}, _host, ip), do: true
  defp entry_match?({:ip, _}, _host, _ip), do: false
  defp entry_match?({:cidr, _, _}, _host, nil), do: false

  defp entry_match?({:cidr, net, bits}, _host, ip) when tuple_size(net) == tuple_size(ip),
    do: top_bits(net, bits) == top_bits(ip, bits)

  defp entry_match?({:cidr, _, _}, _host, _ip), do: false

  # Packs the address into one integer and keeps the leading `bits` bits.
  defp top_bits(ip, bits) do
    {width, group_bits} = if tuple_size(ip) == 4, do: {32, 8}, else: {128, 16}

    value =
      ip
      |> Tuple.to_list()
      |> Enum.reduce(0, fn group, acc -> (acc <<< group_bits) + group end)

    value >>> (width - bits)
  end

  @doc false
  @spec normalize_host(String.t()) :: String.t()
  def normalize_host(host) do
    host
    |> String.trim()
    |> bracketless()
    |> strip_port()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  @doc false
  @spec host_ip(String.t()) :: :inet.ip_address() | nil
  def host_ip(host) do
    case parse_ip(host) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip(string), do: string |> String.to_charlist() |> :inet.parse_address()

  defp bracketless("[" <> rest), do: rest |> String.split("]", parts: 2) |> hd()
  defp bracketless(other), do: other

  # A single colon means host:port; more than one is an IPv6 literal.
  defp strip_port(host) do
    case String.split(host, ":") do
      [name, _port] -> name
      _ -> host
    end
  end
end
