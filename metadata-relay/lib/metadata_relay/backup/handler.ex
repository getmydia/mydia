defmodule MetadataRelay.Backup.Handler do
  @moduledoc """
  HTTP surface of the end-to-end encrypted player backup, mounted at
  `/backup/v1`. The wire format is documented in `docs/backup.md`.

  Bodies are read here, not by `Plug.Parsers`, because the signature covers
  the exact bytes. JSON bodies therefore use `application/vnd.mydia.backup`
  (a `+json` type would be consumed by the endpoint's JSON parser) and slot
  bodies `application/octet-stream`; the router lets both pass unread.
  Request bodies are never logged.

  Authorization order for vault routes: the `Authorization` header is parsed
  first, then the body is read under its cap, then the signature is verified
  over `conn.request_path` (which `forward` leaves whole), then the vault
  must exist (404 `vault_not_found`), then the signer must be a member (403).
  """

  use Plug.Router

  alias MetadataRelay.Backup
  alias MetadataRelay.Backup.Auth
  alias MetadataRelay.{ClientIp, RateLimiter}

  @max_json_bytes 65_536
  @max_slot_bytes 4_194_304
  @hour_ms 3_600_000
  @create_limit 10
  @lookup_limit 30
  @max_lookup_bytes 1024

  plug(:match)
  plug(:dispatch)

  post "/vaults" do
    with :ok <- limit(conn, "create", @create_limit),
         {:ok, body, conn} <- read_body_capped(conn, @max_json_bytes),
         {:ok, attrs} <- decode_create(body),
         {:ok, vault_id} <- Backup.create_vault(attrs) do
      json(conn, 201, %{vault_id: vault_id})
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  # The handle travels in the body, not the URL, so it stays out of access
  # logs and proxy caches. Unsigned: the handle is the credential.
  post "/lookup" do
    with :ok <- limit(conn, "lookup", @lookup_limit),
         {:ok, body, conn} <- read_body_capped(conn, @max_lookup_bytes),
         {:ok, m} <- decode_json(body),
         {:ok, handle} <- text(m, "handle"),
         {:ok, vault_id} <- lookup_handle(handle) do
      json(conn, 200, %{vault_id: vault_id})
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  get "/vaults/:id" do
    with {:ok, signer, conn} <- authorize(conn, id),
         {:ok, manifest, etag} <- Backup.manifest(id, signer) do
      if etag_match?(conn, etag) do
        conn |> put_resp_header("etag", etag) |> send_resp(304, "")
      else
        conn |> put_resp_header("etag", etag) |> json(200, encode_manifest(manifest))
      end
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  delete "/vaults/:id" do
    with {:ok, _signer, conn} <- authorize(conn, id) do
      Backup.delete_vault(id)
      send_resp(conn, 204, "")
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  put "/vaults/:id/slots/:slot" do
    with {:ok, signer, conn} <- authorize(conn, id, @max_slot_bytes),
         {:ok, if_match} <- parse_if_match(conn),
         {:ok, epoch} <- parse_epoch(conn),
         {:ok, seq} <- Backup.put_slot(id, signer, slot, conn.assigns.raw_body, if_match, epoch) do
      conn |> put_resp_header("etag", etag_for(seq)) |> json(200, %{seq: seq})
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  get "/vaults/:id/slots/:slot" do
    with {:ok, _signer, conn} <- authorize(conn, id),
         {:ok, body, seq} <- Backup.get_slot(id, slot) do
      conn = put_resp_header(conn, "etag", etag_for(seq))

      if etag_match?(conn, etag_for(seq)) do
        send_resp(conn, 304, "")
      else
        conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)
      end
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  post "/vaults/:id/members" do
    with {:ok, signer, conn} <- authorize(conn, id, @max_json_bytes),
         {:ok, change} <- decode_change(conn.assigns.raw_body),
         :ok <- Backup.charge_write(id),
         {:ok, epoch} <- Backup.update_members(id, signer, change) do
      json(conn, 200, %{epoch: epoch})
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  # ---- authorization -------------------------------------------------------

  defp authorize(conn, vault_id, cap \\ 0) do
    header = conn |> get_req_header("authorization") |> List.first()

    with {:ok, parsed} <- Auth.parse(header),
         {:ok, body, conn} <- read_body_capped(conn, cap),
         :ok <- Auth.verify(parsed, conn.method, conn.request_path, body, now_ms()),
         :ok <- vault_exists(vault_id),
         :ok <- membership(vault_id, parsed.signer) do
      {:ok, parsed.signer, assign(conn, :raw_body, body)}
    end
  end

  defp vault_exists(vault_id),
    do: if(Backup.vault_exists?(vault_id), do: :ok, else: {:error, :vault_not_found})

  defp membership(vault_id, signer),
    do: if(Backup.member?(vault_id, signer), do: :ok, else: {:error, :not_member})

  # Reads at most `cap` bytes. A declared Content-Length over the cap is
  # refused without reading anything. `cap` 0 is for bodiless requests: any
  # body at all is too large.
  defp read_body_capped(conn, cap) do
    declared = conn |> get_req_header("content-length") |> List.first()

    cond do
      declared != nil and over?(declared, cap) ->
        {:error, :too_large}

      true ->
        case read_body(conn, length: max(cap, 1), read_length: 1_048_576) do
          {:ok, body, conn} when byte_size(body) <= cap -> {:ok, body, conn}
          {:ok, _body, _conn} -> {:error, :too_large}
          {:more, _partial, _conn} -> {:error, :too_large}
          {:error, _} -> {:error, :invalid}
        end
    end
  end

  defp over?(declared, cap) do
    case Integer.parse(declared) do
      {n, ""} -> n > cap
      _ -> false
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  # ---- rate limits ---------------------------------------------------------

  # Off unless `backup.address_limits` is true (RELAY_BACKUP_ADDRESS_LIMITS).
  # Behind Cloudflare `ClientIp.resolve/1` sees a shared edge or Traefik
  # address, so these limits would be one bucket for every install: the
  # eleventh install of the hour could not turn backup on. They wait for the
  # same precondition as `MetadataRelay.Plug.ProxyRateLimit`. Meanwhile a
  # vault is a small row the idle sweep removes, and a lookup handle is a
  # 256-bit secret, so neither limit is what keeps the data safe.
  defp limit(conn, name, max) do
    if Backup.config(:address_limits) == true do
      key = "backup:#{name}:#{ClientIp.resolve(conn)}"

      case RateLimiter.check_rate_limit(key, limit: max, window_ms: @hour_ms) do
        {:ok, _} -> :ok
        {:error, :rate_limited} -> {:error, :rate_limited}
      end
    else
      :ok
    end
  end

  # ---- request decoding ----------------------------------------------------

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :invalid}
    end
  end

  # A handle that is not base64url finds nothing, like a miss.
  defp lookup_handle(handle) do
    case decode_b64(handle) do
      {:ok, raw} -> Backup.lookup(raw)
      {:error, :invalid} -> {:error, :not_found}
    end
  end

  defp decode_create(body) do
    with {:ok, m} <- decode_json(body),
         {:ok, vault_id} <- text(m, "vault_id"),
         {:ok, signer} <- bin(m, "signer"),
         {:ok, envelope} <- bin(m, "envelope"),
         {:ok, box_pub} <- bin(m, "box_pub"),
         {:ok, recovery_signer} <- bin(m, "recovery_signer"),
         {:ok, recovery_envelope} <- bin(m, "recovery_envelope"),
         {:ok, recovery_box_pub} <- bin(m, "recovery_box_pub"),
         {:ok, slot_id} <- text(m, "slot_id"),
         {:ok, recovery_slot_id} <- text(m, "recovery_slot_id"),
         {:ok, lookup_hash} <- text(m, "lookup_hash") do
      {:ok,
       %{
         vault_id: vault_id,
         signer: signer,
         slot_id: slot_id,
         envelope: envelope,
         box_pub: box_pub,
         recovery_signer: recovery_signer,
         recovery_slot_id: recovery_slot_id,
         recovery_envelope: recovery_envelope,
         recovery_box_pub: recovery_box_pub,
         lookup_hash: lookup_hash
       }}
    end
  end

  defp decode_change(body) do
    with {:ok, m} <- decode_json(body),
         {:ok, expected} <- int(m, "expected_epoch"),
         {:ok, new} <- int(m, "new_epoch", expected),
         {:ok, add} <- list_of(m["add"], &decode_added/1),
         {:ok, remove} <- list_of(m["remove"], &decode_b64/1),
         {:ok, envelopes} <- decode_envelopes(m["envelopes"]),
         {:ok, recovery} <- decode_recovery(m["recovery"]) do
      {:ok,
       %{
         expected_epoch: expected,
         new_epoch: new,
         add: add,
         remove: remove,
         envelopes: envelopes,
         recovery: recovery
       }}
    end
  end

  defp decode_added(%{} = m) do
    with {:ok, signer} <- bin(m, "signer"),
         {:ok, box_pub} <- bin(m, "box_pub"),
         {:ok, slot_id} <- text(m, "slot_id") do
      {:ok, %{signer: signer, slot_id: slot_id, box_pub: box_pub}}
    end
  end

  defp decode_added(_), do: {:error, :invalid}

  defp decode_envelopes(nil), do: {:ok, %{}}

  defp decode_envelopes(%{} = m) do
    Enum.reduce_while(m, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, signer} <- decode_b64(k),
           {:ok, envelope} <- decode_b64(v) do
        {:cont, {:ok, Map.put(acc, signer, envelope)}}
      else
        _ -> {:halt, {:error, :invalid}}
      end
    end)
  end

  defp decode_envelopes(_), do: {:error, :invalid}

  defp decode_recovery(nil), do: {:ok, nil}

  defp decode_recovery(%{} = m) do
    with {:ok, signer} <- bin(m, "signer"),
         {:ok, envelope} <- bin(m, "envelope"),
         {:ok, box_pub} <- bin(m, "box_pub"),
         {:ok, slot_id} <- text(m, "slot_id"),
         {:ok, lookup_hash} <- text(m, "lookup_hash") do
      {:ok,
       %{
         signer: signer,
         slot_id: slot_id,
         envelope: envelope,
         box_pub: box_pub,
         lookup_hash: lookup_hash
       }}
    end
  end

  defp decode_recovery(_), do: {:error, :invalid}

  defp list_of(nil, _fun), do: {:ok, []}

  defp list_of(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        _ -> {:halt, {:error, :invalid}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp list_of(_, _), do: {:error, :invalid}

  defp bin(map, key) do
    case map[key] do
      v when is_binary(v) -> decode_b64(v)
      _ -> {:error, :invalid}
    end
  end

  defp text(map, key) do
    case map[key] do
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, :invalid}
    end
  end

  defp int(map, key, default \\ nil) do
    case map[key] do
      v when is_integer(v) -> {:ok, v}
      nil when is_integer(default) -> {:ok, default}
      _ -> {:error, :invalid}
    end
  end

  defp decode_b64(text) when is_binary(text) do
    case Base.url_decode64(String.trim_trailing(text, "="), padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid}
    end
  end

  defp decode_b64(_), do: {:error, :invalid}

  defp parse_if_match(conn) do
    case get_req_header(conn, "if-match") do
      [] -> {:ok, nil}
      [value | _] -> parse_seq(value)
    end
  end

  defp parse_seq(value) do
    case value |> String.trim() |> String.trim("\"") |> Integer.parse() do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :precondition_failed}
    end
  end

  defp parse_epoch(conn) do
    with [value | _] <- get_req_header(conn, "x-backup-epoch"),
         {n, ""} <- Integer.parse(String.trim(value)) do
      {:ok, n}
    else
      _ -> {:error, :invalid}
    end
  end

  # ---- responses -----------------------------------------------------------

  defp encode_manifest(m) do
    %{
      epoch: m.epoch,
      members:
        Enum.map(m.members, fn member ->
          %{
            signer: enc(member.signer),
            box_pub: enc(member.box_pub),
            slot_id: member.slot_id,
            recovery: member.recovery?
          }
        end),
      envelope: enc(m.envelope),
      recovery_signer: enc(m.recovery_signer),
      slots:
        Enum.map(m.slots, fn s ->
          %{
            slot_id: s.slot_id,
            seq: s.seq,
            epoch: s.epoch,
            size: s.size,
            updated_at: DateTime.to_unix(s.updated_at, :millisecond)
          }
        end)
    }
  end

  defp enc(bin), do: Base.url_encode64(bin, padding: false)

  defp etag_for(seq), do: "\"#{seq}\""

  defp etag_match?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.any?(&(&1 == etag or &1 == "*"))
  end

  defp reject(conn, :skew) do
    conn
    |> put_resp_header("x-backup-server-time", Integer.to_string(now_ms()))
    |> json(401, %{error: "skew"})
  end

  defp reject(conn, :rate_limited) do
    conn
    |> put_resp_header("retry-after", "3600")
    |> json(429, %{error: "rate_limited"})
  end

  defp reject(conn, reason) when is_atom(reason),
    do: json(conn, status(reason), %{error: Atom.to_string(reason)})

  defp status(reason) when reason in [:missing, :malformed, :bad_signature], do: 401
  defp status(reason) when reason in [:not_member, :not_owner], do: 403
  defp status(reason) when reason in [:vault_not_found, :not_found], do: 404
  defp status(:precondition_failed), do: 412
  defp status(reason) when reason in [:conflict, :stale_epoch, :vault_taken], do: 409
  defp status(:too_large), do: 413
  defp status(reason) when reason in [:invalid, :lookup_taken, :too_many_members], do: 422
  defp status(_storage), do: 503

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
