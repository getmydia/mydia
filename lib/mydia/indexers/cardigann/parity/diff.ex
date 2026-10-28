defmodule Mydia.Indexers.Cardigann.Parity.Diff do
  @moduledoc """
  Compares the outcome of the native and wasm engines for one definition and
  query kind, producing `Divergence` records.

  Results are paired before comparing so a different ordering between the
  engines does not read as a field mismatch: first by info hash, then by
  normalised download URL, then whatever is left by position.
  """

  alias Mydia.Indexers.Cardigann.Parity.{Divergence, RequestKey}
  alias Mydia.Indexers.SearchResult

  @struct_fields ~w(title size seeders leechers download_url info_url guid category
                    published_at imdb_id tmdb_id tvdb_id)a
  @metadata_fields ~w(info_hash download_volume_factor upload_volume_factor)a
  @fields @struct_fields ++ @metadata_fields
  @date_tolerance_seconds 60

  @type outcome :: {:ok, [SearchResult.t()]} | {:error, term()}

  @spec compare(String.t(), atom(), outcome(), outcome(), [RequestKey.t()]) :: %{
          divergences: [Divergence.t()],
          paired: non_neg_integer(),
          agreeing: non_neg_integer()
        }
  def compare(definition, query, native, wasm, misses) do
    div = fn kind, field, n, w ->
      %Divergence{
        definition: definition,
        query: query,
        kind: kind,
        field: field,
        native: n,
        wasm: w
      }
    end

    request = if misses == [], do: [], else: [div.(:request, nil, misses, nil)]

    case {native, wasm} do
      {{:ok, n}, {:ok, w}} ->
        pairs = pair(n, w)
        count = if length(n) == length(w), do: [], else: [div.(:count, nil, length(n), length(w))]
        fields = field_divergences(pairs, div)

        differing = Enum.count(pairs, fn {a, b} -> Enum.any?(@fields, &differs?(&1, a, b)) end)

        %{
          divergences: request ++ count ++ fields,
          paired: length(pairs),
          agreeing: length(pairs) - differing
        }

      {{:error, _} = n, {:error, _} = w} ->
        outcome =
          if error_type(n) == error_type(w), do: [], else: [div.(:outcome, nil, n, w)]

        %{divergences: request ++ outcome, paired: 0, agreeing: 0}

      {n, w} ->
        %{divergences: request ++ [div.(:outcome, nil, n, w)], paired: 0, agreeing: 0}
    end
  end

  defp error_type({:error, err}) when is_map(err), do: Map.get(err, :type)
  defp error_type({:error, err}), do: err

  defp field_divergences(pairs, div) do
    for field <- @fields,
        {a, b} <- [Enum.find(pairs, fn {a, b} -> differs?(field, a, b) end)],
        a != nil do
      div.(:field, field, value(a, field), value(b, field))
    end
  end

  defp differs?(field, a, b), do: not equal?(field, value(a, field), value(b, field))

  defp value(%SearchResult{} = r, field) when field in @metadata_fields,
    do: metadata_value(r.metadata, field)

  defp value(%SearchResult{} = r, field), do: Map.get(r, field)

  defp metadata_value(meta, key) when is_map(meta),
    do: Map.get(meta, key, Map.get(meta, Atom.to_string(key)))

  defp metadata_value(_, _), do: nil

  defp equal?(:published_at, %DateTime{} = a, %DateTime{} = b),
    do: abs(DateTime.diff(a, b)) <= @date_tolerance_seconds

  defp equal?(field, a, b) when field in [:download_url, :info_url],
    do: normalise_url(a) == normalise_url(b)

  defp equal?(:info_hash, a, b), do: normalise_hash(a) == normalise_hash(b)
  defp equal?(_field, a, b), do: a == b

  # Pairing only: neither engine fills metadata today, so the hash falls back to
  # the one in a magnet link. The compared info_hash field stays metadata-only,
  # otherwise a magnet paired with a non-magnet would report the same difference
  # twice. Base32 btih spellings are not decoded, so they pair by URL or position.
  defp hash_from_magnet("magnet:" <> _ = url) do
    case Regex.run(~r/[?&]xt=urn:btih:([^&]+)/i, url) do
      [_, hash] -> hash
      _ -> nil
    end
  end

  defp hash_from_magnet(_), do: nil

  defp normalise_hash(h) when is_binary(h), do: String.downcase(h)
  defp normalise_hash(h), do: h

  defp normalise_url("magnet:" <> rest = url) do
    rest |> String.trim_leading("?") |> URI.query_decoder() |> Enum.to_list() |> magnet_key()
  rescue
    # Malformed percent-encoding: compare the raw string.
    ArgumentError -> url
  end

  defp normalise_url(url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]),
      do: RequestKey.new(:get, url, nil).url,
      else: url
  end

  defp normalise_url(other), do: other

  defp btih(xt) do
    case String.split(xt, ":", parts: 3) do
      [urn, btih, h] ->
        if String.downcase(urn <> ":" <> btih) == "urn:btih", do: String.downcase(h)

      _ ->
        nil
    end
  end

  defp magnet_key(params) do
    hash =
      Enum.find_value(params, fn
        {"xt", xt} -> btih(xt)
        _ -> nil
      end)

    {:magnet, hash, for({"dn", v} <- params, do: v),
     params |> Enum.flat_map(fn {k, v} -> if k == "tr", do: [v], else: [] end) |> Enum.sort()}
  end

  # Pairing: info hash, then normalised download URL, then position.
  defp pair(native, wasm) do
    {pairs, n_left, w_left} =
      {[], native, wasm}
      |> pair_by(&hash_of/1)
      |> pair_by(&url_of/1)

    Enum.reverse(pairs) ++ Enum.zip(n_left, w_left)
  end

  defp pair_by({pairs, native, wasm}, key_fun) do
    {pairs, wasm_left, native_left} =
      Enum.reduce(native, {pairs, wasm, []}, fn n, {acc, w_rest, n_rest} ->
        key = key_fun.(n)

        idx = key && Enum.find_index(w_rest, &(key_fun.(&1) == key))

        if idx do
          {w, w_rest} = List.pop_at(w_rest, idx)
          {[{n, w} | acc], w_rest, n_rest}
        else
          {acc, w_rest, [n | n_rest]}
        end
      end)

    {pairs, Enum.reverse(native_left), wasm_left}
  end

  defp hash_of(r) do
    (value(r, :info_hash) || hash_from_magnet(r.download_url)) |> normalise_hash()
  end

  defp url_of(r), do: r |> Map.get(:download_url) |> normalise_url()
end
