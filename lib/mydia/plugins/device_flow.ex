defmodule Mydia.Plugins.DeviceFlow do
  @moduledoc """
  Host-run OAuth device (PIN) flow for plugin connections (U8).

  The host — never the guest — drives the flow declared by a plugin's manifest
  `connection` descriptor: it requests a user code, the user enters it at the
  provider's verification URL, and the host polls until a token comes back. All
  HTTP goes through the SSRF egress gate (`Mydia.Plugins.Net.Gate`) under the
  plugin's `net:http` allowlist, so the connect flow can reach only the hosts the
  admin already approved (and the manifest validated the descriptor URLs against).

  Shapes are tolerant of the Simkl PIN flow (200 with `result: "OK"/"KO"`) and the
  standard OAuth device grant (4xx with an `error` code). The guest never
  executes during connect and never sees the token — on success the caller stores
  it via `Mydia.Plugins.Connections`.

  ## Options (both functions)

    * `:allowed_hosts` (required) - the plugin's granted `net:http` hosts
    * `:slug` - plugin slug, for the gate's egress audit
    * `:allow_private` / `:resolver` - gate test seams (never set in production)
  """

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Net.Gate

  @user_agent "mydia-plugin-connect"

  @type code_result :: %{
          user_code: String.t(),
          device_code: String.t() | nil,
          verification_url: String.t() | nil,
          interval_ms: pos_integer(),
          expires_in_s: pos_integer()
        }

  @type codes :: %{
          optional(:user_code) => String.t() | nil,
          optional(:device_code) => String.t() | nil
        }

  @type poll_result ::
          {:ok, %{access_token: String.t(), external_user_id: String.t() | nil}}
          | :pending
          | :slow_down
          | :expired
          | :denied
          | {:error, term()}

  @doc """
  Requests a user code from the descriptor's `code_url`.

  Returns the user code (shown to the user), the poll token (used to poll), the
  verification URL, and the provider's suggested interval/expiry.
  """
  @spec request_code(map(), String.t(), keyword()) :: {:ok, code_result()} | {:error, term()}
  def request_code(descriptor, client_id, opts) when is_map(descriptor) do
    url = render(descriptor["code_url"], client_id, %{})

    with {:ok, %{status: 200, body: body}} <- get(url, opts),
         {:ok, data} when is_map(data) <- Jason.decode(body),
         user_code when is_binary(user_code) <- data["user_code"] do
      {:ok,
       %{
         user_code: user_code,
         # Both codes are carried verbatim; the descriptor's `poll_url` picks which
         # one it polls by (`{user_code}` for Simkl, `{device_code}` for a standard
         # device grant). Simkl returns a literal "DEVICE_CODE" placeholder here,
         # so the host must never assume device_code is the thing to poll.
         device_code: data["device_code"],
         verification_url: data["verification_url"] || descriptor["verification_url"],
         interval_ms: max((data["interval"] || 5) * 1000, 1000),
         expires_in_s: data["expires_in"] || 900
       }}
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      nil -> {:error, :no_user_code}
      {:error, %Error{}} = err -> err
      _ -> {:error, :bad_response}
    end
  end

  @doc """
  Polls the descriptor's `poll_url` once, returning the token, a transient state
  (`:pending` / `:slow_down`), or a terminal failure (`:expired` / `:denied`).
  """
  @spec poll(map(), codes(), String.t(), keyword()) :: poll_result()
  def poll(descriptor, codes, client_id, opts) when is_map(descriptor) and is_map(codes) do
    url = render(descriptor["poll_url"], client_id, codes)

    case get(url, opts) do
      {:ok, %{status: 200, body: body}} -> classify_200(body)
      {:ok, %{status: 429}} -> :slow_down
      {:ok, %{status: status, body: body}} when status in 400..499 -> classify_4xx(body)
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A 200 either carries a token (authorized) or signals still-pending.
  defp classify_200(body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => token} = data} when is_binary(token) and token != "" ->
        {:ok, %{access_token: token, external_user_id: data["account"]["id"] |> to_id()}}

      {:ok, %{"error" => err}} ->
        classify_error(err)

      _ ->
        :pending
    end
  end

  # A 4xx in the standard device grant carries an `error` code; otherwise treat
  # it as still pending (Simkl returns non-200 while the code is unredeemed).
  defp classify_4xx(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => err}} -> classify_error(err)
      _ -> :pending
    end
  end

  defp classify_error("authorization_pending"), do: :pending
  defp classify_error("slow_down"), do: :slow_down
  defp classify_error("expired_token"), do: :expired
  defp classify_error("access_denied"), do: :denied
  defp classify_error(_), do: :pending

  defp to_id(nil), do: nil
  defp to_id(id), do: to_string(id)

  defp get(url, opts) do
    gate_opts =
      [
        allowed_hosts: Keyword.fetch!(opts, :allowed_hosts),
        slug: Keyword.get(opts, :slug),
        method: "GET",
        headers: %{"user-agent" => @user_agent, "accept" => "application/json"}
      ] ++ Keyword.take(opts, [:allow_private, :resolver, :timeout])

    Gate.request(url, gate_opts)
  end

  defp render(nil, _client_id, _codes), do: ""

  defp render(template, client_id, codes) do
    template
    |> String.replace("{client_id}", client_id || "")
    |> String.replace("{user_code}", Map.get(codes, :user_code) || "")
    |> String.replace("{device_code}", Map.get(codes, :device_code) || "")
  end
end
