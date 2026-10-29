defmodule Mydia.Indexers.Cardigann.SessionCookies do
  @moduledoc """
  Decides which of a definition's stored session cookies may ride a request to
  a given URL, and normalises them into `name=value` pairs.

  Split out of `Mydia.Indexers.CardigannSearchEngine`, which builds the request
  options and is the only caller.
  """

  require Logger

  alias Mydia.Indexers.Cardigann.CredentialScope
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @doc """
  The cookie pairs to send to `url`, and whether any were attached. Cookies are
  withheld (with a warning) from a cleartext URL or one outside the
  definition's trusted origins.
  """
  # A session cookie is a bearer credential for the tracker account. Base URL
  # candidates come straight from the definition's `links`, and a few of them are
  # cleartext (torrentlt ships `http://www.torrent.ai/`), so the header is
  # withheld rather than handed to anyone on the path. The request still goes
  # out: an anonymous result is a better outcome than a leaked login, and the
  # search reports whatever the tracker returns for a logged-out visitor.
  #
  # A cookie-bearing request also stops following redirects, because Req carries
  # a manually supplied Cookie header along a redirect even to a different host
  # (checked against the pinned Req, not assumed). Following one would hand the
  # session to whatever host the Location names, which is a leak an attacker can
  # trigger from a hijacked mirror rather than an accident. Unfollowed 3xx keeps
  # the honest handling: `CardigannSearchEngine.validate_response/1` names the
  # Location, and failover moves on to the next candidate. Redirect following is
  # unaffected for every request without cookies.
  #
  # A session cookie is scoped to the origins the definition names as its own:
  # its links, plus any absolute search or login path it renders. A mirror
  # failover onto a stale legacylinks domain, or a download link parsed out
  # of a result row, can both name an origin the operator never trusted, and a
  # download link is remote content rather than shipped YAML. Withhold and
  # continue, because an anonymous result beats a leaked login.
  @spec pairs(term(), String.t(), Parsed.t(), term()) :: {[String.t()], boolean()}
  def pairs(cookies, url, definition, config)
      when is_list(cookies) and cookies != [] do
    case cookie_disposition(url, CredentialScope.trusted_origins(definition, config)) do
      {:withhold, reason} ->
        Logger.warning("Cardigann: withholding session cookies from #{reason}")
        {[], false}

      :ok ->
        pairs = cookies |> Enum.map(&normalize_cookie/1) |> Enum.reject(&is_nil/1)
        {pairs, pairs != []}
    end
  end

  def pairs(_cookies, _url, _definition, _config), do: {[], false}

  # The one place that decides whether a URL may receive the definition's
  # session. FlareSolverr no longer receives session cookies at all, so
  # pairs/4 is the only caller.
  defp cookie_disposition(url, trusted_origins) do
    cond do
      CredentialScope.cleartext?(url) ->
        {:withhold,
         "cleartext URL #{inspect(url)}. Configure an https base URL for this indexer to " <>
           "send credentials."}

      not CredentialScope.allows?(trusted_origins, url) ->
        {:withhold,
         "#{inspect(url)}, which is not one of this definition's own hosts. Searching " <>
           "anonymously."}

      true ->
        :ok
    end
  end

  # A stored session row holds either plain "name=value" strings or cookie maps
  # (older versions wrote FlareSolverr's cookies there), and
  # SessionManager.user_config/2 hands back whatever is in the row without
  # looking. Joining a map raises Protocol.UndefinedError before the request is
  # even sent, so a leftover row would crash the next search. Entries are
  # normalized here and anything unusable is dropped.
  defp normalize_cookie(cookie) when is_binary(cookie), do: cookie

  defp normalize_cookie(cookie) when is_map(cookie) do
    name = cookie["name"] || Map.get(cookie, :name)
    value = cookie["value"] || Map.get(cookie, :value)

    # Both halves have to be strings. These rows are decoded JSON, so a nested
    # object or array can land in either field, and interpolating one raises the
    # same Protocol.UndefinedError this function exists to prevent.
    if is_binary(name) and is_binary(value), do: name <> "=" <> value, else: nil
  end

  defp normalize_cookie(_cookie), do: nil
end
