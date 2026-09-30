defmodule MydiaWeb.PluginPageController do
  @moduledoc """
  Serves `/plugins/:slug/app/*` by calling the plugin's `on-http` export as the
  user named in the frame token.

  The host only transports these bytes: it reads the raw body itself (the
  endpoint skips body parsing for these paths), never parses or logs it, and
  never re-encodes it. The acting user, role and session come from the verified
  token and the database, never from the request body or the guest. Pages are
  text only, because the guest's response body is a string. The host sets the
  security headers itself and forwards only `content-type` and `cache-control`
  from the guest, so a plugin cannot set cookies, relax the CSP or frame itself
  elsewhere.
  """
  use MydiaWeb, :controller

  alias Mydia.Accounts
  alias Mydia.Plugins
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Plugin
  alias MydiaWeb.PluginFrameToken

  @forwarded_request_headers ~w(content-type accept accept-language)
  @kept_response_headers ~w(content-type)
  @default_content_type "text/plain; charset=utf-8"
  @max_body_bytes 1_048_576
  @retry_after_seconds "2"

  @csp Enum.join(
         [
           "default-src 'self' 'unsafe-inline'",
           "connect-src 'self'",
           "img-src 'self' data: https://image.tmdb.org https://artworks.thetvdb.com",
           "sandbox allow-scripts allow-forms",
           "frame-ancestors 'self'",
           "form-action 'self'",
           "base-uri 'none'"
         ],
         "; "
       )

  def preflight(conn, _params) do
    conn
    |> cors()
    |> put_resp_header("access-control-allow-methods", "GET, POST")
    |> put_resp_header("access-control-allow-headers", "content-type, x-mydia-frame-token")
    |> put_resp_header("access-control-max-age", "600")
    |> send_resp(204, "")
  end

  def serve(conn, %{"slug" => slug} = params) do
    with {:ok, claims} <- verify(conn),
         :ok <- check(claims.slug == slug, :unauthorized),
         {:ok, user} <- fetch_user(claims.user_id),
         :ok <- check(PluginFrameToken.current?(claims, user), :unauthorized),
         {:ok, %Plugin{enabled: true} = plugin} <- fetch_plugin(slug),
         :ok <- check(Plugin.granted?(plugin, "surfaces:page"), :not_found),
         {:ok, body, conn} <- read_page_body(conn),
         :ok <- check(String.valid?(body), :unsupported_body) do
      payload = %{
        "method" => conn.method,
        "path" => "/" <> Enum.join(List.wrap(Map.get(params, "path")), "/"),
        "query" => strip_token(conn.query_string),
        "headers" => forwarded_headers(conn),
        "body" => if(body == "", do: nil, else: body),
        "config" => plugin_config(slug)
      }

      slug
      |> Host.call("on-http", payload,
        handler: :on_http,
        acting_user_id: user.id,
        role: user.role,
        session_id: claims.session_id
      )
      |> respond(conn)
    else
      {:error, :too_large} -> fail(conn, 413)
      {:error, :unsupported_body} -> fail(conn, 415)
      {:error, :not_found} -> fail(conn, 404)
      {:error, _} -> fail(conn, 401)
    end
  end

  defp respond({:ok, %{status: status, headers: headers, body: body}}, conn)
       when status in 200..599 do
    conn
    |> harden()
    |> put_resp_header("content-type", @default_content_type)
    |> put_guest_headers(headers)
    |> send_resp(status, body)
  end

  defp respond({:ok, _malformed}, conn), do: fail(conn, 502)

  defp respond({:error, %Error{type: :busy}}, conn) do
    conn |> put_resp_header("retry-after", @retry_after_seconds) |> fail(503)
  end

  defp respond({:error, %Error{type: :timeout}}, conn), do: fail(conn, 504)
  defp respond({:error, %Error{type: :not_found}}, conn), do: fail(conn, 404)
  defp respond({:error, _error}, conn), do: fail(conn, 502)

  # Failures carry no detail: nothing from the guest or host internals reaches
  # the page.
  defp fail(conn, status) do
    conn |> harden() |> send_resp(status, "")
  end

  defp check(true, _reason), do: :ok
  defp check(_, reason), do: {:error, reason}

  defp verify(conn) do
    token =
      conn.query_params[PluginFrameToken.param()] ||
        List.first(get_req_header(conn, "x-mydia-frame-token"))

    PluginFrameToken.verify(token)
  end

  defp fetch_user(user_id) do
    case Accounts.get_user_by_id(user_id) do
      %Accounts.User{} = user -> {:ok, user}
      nil -> {:error, :unauthorized}
    end
  end

  defp fetch_plugin(slug) do
    case Plugins.get_plugin(slug) do
      {:ok, %Plugin{enabled: true} = plugin} -> {:ok, plugin}
      _ -> {:error, :not_found}
    end
  end

  defp read_page_body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _} -> {:error, :unauthorized}
    end
  end

  # Drops the frame token from the query the guest sees, leaving every other
  # pair byte-for-byte as sent. Keys are compared percent-decoded, because the
  # token is accepted under an encoded key too.
  defp strip_token(query_string) do
    query_string
    |> String.split("&", trim: true)
    |> Enum.reject(fn pair ->
      [key | _] = String.split(pair, "=", parts: 2)
      decoded_key(key) == PluginFrameToken.param()
    end)
    |> Enum.join("&")
  end

  defp decoded_key(key) do
    URI.decode_www_form(key)
  rescue
    ArgumentError -> key
  end

  defp forwarded_headers(conn) do
    for {k, v} <- conn.req_headers, k in @forwarded_request_headers, do: {k, v}
  end

  defp plugin_config(slug) do
    case Mydia.Settings.get_plugin_config_by_slug(slug) do
      %{settings: %{} = settings} -> settings
      _ -> %{}
    end
  end

  defp harden(conn) do
    conn
    |> cors()
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "private, no-store")
  end

  defp cors(conn), do: put_resp_header(conn, "access-control-allow-origin", "*")

  defp put_guest_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc ->
      k = String.downcase(k)

      if k in @kept_response_headers and not String.contains?(v, ["\r", "\n"]),
        do: put_resp_header(acc, k, v),
        else: acc
    end)
  end
end
