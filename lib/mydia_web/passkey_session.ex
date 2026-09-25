defmodule MydiaWeb.PasskeySession do
  @moduledoc """
  Request-side plumbing for passkeys: which relying party a request belongs
  to, and the WebAuthn challenge held in the session between the options
  request and the verification request.

  The relying-party ID is the request's own host. `conn.host` comes from the
  client's Host header (see the comment above `Plug.RewriteOn` in
  `MydiaWeb.Endpoint`), and that is safe here: a passkey is only accepted
  when the origin inside the browser-signed client data, the relying-party
  hash inside the authenticator data, and the host stored with the passkey
  all match this host. A forged Host header changes the host we expect, so
  no genuine passkey matches it.

  Browsers only allow WebAuthn in a secure context, and never with an IP
  address as the relying-party ID, so plain-http hosts other than localhost
  and every IP address are `:unavailable`.
  """

  import Plug.Conn

  defstruct [:rp_id, :origin]

  @type t :: %__MODULE__{rp_id: String.t(), origin: String.t()}

  @challenge_key :webauthn_challenge
  @purposes [:login, :second_factor]

  @spec relying_party(Plug.Conn.t() | String.t() | nil) :: {:ok, t()} | :unavailable
  def relying_party(%Plug.Conn{scheme: scheme, host: host, port: port}),
    do: build(to_string(scheme), host, port)

  def relying_party(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        build(scheme, host, port)

      _ ->
        :unavailable
    end
  end

  def relying_party(_other), do: :unavailable

  @spec put_challenge(Plug.Conn.t(), :login | :second_factor, Wax.Challenge.t()) ::
          Plug.Conn.t()
  def put_challenge(conn, purpose, %Wax.Challenge{} = challenge) when purpose in @purposes do
    put_session(conn, @challenge_key, %{
      "purpose" => Atom.to_string(purpose),
      "challenge" => challenge
    })
  end

  @doc """
  Takes the pending challenge out of the session. It is removed whether or
  not the purpose matches, so every challenge is single-use.
  """
  @spec pop_challenge(Plug.Conn.t(), :login | :second_factor) ::
          {Wax.Challenge.t() | nil, Plug.Conn.t()}
  def pop_challenge(conn, purpose) when purpose in @purposes do
    stored = get_session(conn, @challenge_key)
    conn = delete_session(conn, @challenge_key)
    expected = Atom.to_string(purpose)

    case stored do
      %{"purpose" => ^expected, "challenge" => %Wax.Challenge{} = challenge} -> {challenge, conn}
      _ -> {nil, conn}
    end
  end

  @spec credential_param(map()) :: map()
  def credential_param(%{"credential" => %{} = credential}), do: credential
  def credential_param(_params), do: %{}

  @spec json_error(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  def json_error(conn, status, message) do
    conn |> put_status(status) |> Phoenix.Controller.json(%{error: message})
  end

  defp build(scheme, host, port) when is_binary(host) and host != "" do
    host = String.downcase(host)

    cond do
      ip_address?(host) ->
        :unavailable

      scheme == "https" ->
        {:ok, %__MODULE__{rp_id: host, origin: origin(scheme, host, port)}}

      scheme == "http" and localhost?(host) ->
        {:ok, %__MODULE__{rp_id: host, origin: origin(scheme, host, port)}}

      true ->
        :unavailable
    end
  end

  defp build(_scheme, _host, _port), do: :unavailable

  defp origin("https", host, 443), do: "https://#{host}"
  defp origin("http", host, 80), do: "http://#{host}"
  defp origin(scheme, host, nil), do: "#{scheme}://#{host}"
  defp origin(scheme, host, port), do: "#{scheme}://#{host}:#{port}"

  defp localhost?(host), do: host == "localhost" or String.ends_with?(host, ".localhost")

  defp ip_address?(host) do
    case host
         |> String.trim_leading("[")
         |> String.trim_trailing("]")
         |> String.to_charlist()
         |> :inet.parse_address() do
      {:ok, _} -> true
      _ -> false
    end
  end
end
