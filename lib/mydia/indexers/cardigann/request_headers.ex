defmodule Mydia.Indexers.Cardigann.RequestHeaders do
  @moduledoc """
  Assembles the headers of an outgoing Cardigann request.

  Three sources feed one request: the headers the definition declares, the
  user's session cookies, and a FlareSolverr clearance cached for the host. They
  disagree about the user-agent and all contribute cookies, so merging them is
  its own small policy. Keeping it here leaves the search engine to decide
  whether a session may be sent at all and to build the rest of the Req options.
  """

  alias Mydia.Indexers.FlareSolverr.ClearanceCache

  # Req's own "req/x.y" user-agent is refused or served a different page by
  # some public trackers. Prowlarr's own default is "Prowlarr/<version> (<os>)",
  # which Cloudflare refuses on some of them, so a desktop browser's string is
  # sent instead, and a definition's own user-agent header still takes
  # precedence.
  @default_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                        "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

  @doc """
  Builds the header list for a request to `url`.

  `definition_headers` are the definition's own headers and `session_pairs` the
  `"name=value"` session cookies the caller decided may be sent. A cached
  clearance for `url` contributes its cookies and its user-agent.

  Returns `{headers, clearance_attached?}`. The flag is true when clearance
  cookies went into the cookie header, so the caller can keep them off a
  redirect without looking the clearance up a second time.
  """
  @spec build([{term(), term()}] | nil, String.t(), [String.t()]) ::
          {[{String.t(), String.t()}], boolean()}
  def build(definition_headers, url, session_pairs) do
    clearance =
      case ClearanceCache.lookup(url) do
        {:ok, clearance} -> clearance
        :none -> nil
      end

    {defined_ua, defined_cookie, other_headers} = split_headers(definition_headers)

    # A solved clearance is bound to the user-agent that solved it, so it wins.
    user_agent = (clearance && clearance.user_agent) || defined_ua || @default_user_agent

    clearance_pairs =
      if clearance, do: Enum.map(clearance.cookies, fn {n, v} -> "#{n}=#{v}" end), else: []

    # One cookie header only: a second one beside the definition's own is
    # dropped or mangled by some servers.
    cookie_header =
      [defined_cookie | session_pairs ++ clearance_pairs]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("; ")

    headers =
      [{"user-agent", user_agent} | other_headers] ++
        if(cookie_header == "", do: [], else: [{"cookie", cookie_header}])

    {headers, clearance_pairs != []}
  end

  defp split_headers(headers) do
    Enum.reduce(headers || [], {nil, nil, []}, fn {name, value}, {ua, cookie, rest} ->
      value = if is_list(value), do: Enum.join(value, "; "), else: to_string(value)

      case String.downcase(to_string(name)) do
        "user-agent" -> {value, cookie, rest}
        "cookie" -> {ua, value, rest}
        _ -> {ua, cookie, rest ++ [{name, value}]}
      end
    end)
  end
end
