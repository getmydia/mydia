defmodule Mydia.Indexers.Cardigann.Charset do
  @moduledoc """
  Converts between UTF-8 and the single-byte charset a Cardigann definition
  declares in `encoding:`.

  Responses are decoded before parsing: lexbor and SweetXml both expect UTF-8,
  and raw windows-1251 bytes used to crash the HTML parser outright. Outgoing
  keywords are encoded the other way, because a windows-1251 tracker reads
  `%D0%9F` (UTF-8 for "П") as two unrelated characters.

  The ISO 8859 pages come from Codepagex, which compiles all of them by
  default. The Windows pages are tables in `Charset.Windows`, because getting
  them into Codepagex takes `config :codepagex, :encodings`, and a dependency
  built in isolation (the Nix package) never sees this project's config.
  """

  require Logger

  alias Mydia.Indexers.Cardigann.Charset.Windows

  @names %{
    "ISO88591" => "ISO8859/8859-1",
    "LATIN1" => "ISO8859/8859-1",
    "ISO88592" => "ISO8859/8859-2",
    "TIS620" => "ISO8859/8859-11",
    "ISO885911" => "ISO8859/8859-11",
    "WINDOWS874" => {:windows, "WINDOWS874"},
    "WINDOWS1250" => {:windows, "WINDOWS1250"},
    "WINDOWS1251" => {:windows, "WINDOWS1251"},
    "WINDOWS1252" => {:windows, "WINDOWS1252"},
    "CP1252" => {:windows, "WINDOWS1252"},
    "WINDOWS1255" => {:windows, "WINDOWS1255"},
    "WINDOWS1256" => {:windows, "WINDOWS1256"}
  }

  @doc """
  Decodes `body` from `encoding` to UTF-8.

  Returns `body` unchanged when the encoding is nil, UTF-8 or not supported
  (the unsupported case logs a warning once per encoding) or when decoding
  fails, so on those paths the result is not guaranteed to be valid UTF-8.
  Bytes with no mapping in the charset become U+FFFD.
  """
  @spec decode(binary(), String.t() | nil) :: String.t()
  def decode(body, encoding) when is_binary(body) do
    case codepage(encoding) do
      :utf8 ->
        body

      nil ->
        warn_unsupported_once(encoding)
        body

      {:windows, name} ->
        Windows.decode(body, name)

      name ->
        case Codepagex.to_string(body, name, Codepagex.use_utf_replacement()) do
          {:ok, utf8, _replaced} ->
            utf8

          {:error, reason, _acc} ->
            Logger.warning("Cardigann: could not decode #{encoding}: #{inspect(reason)}")
            body
        end
    end
  end

  @doc """
  Encodes a UTF-8 `value` into `encoding`, the inverse of `decode/2`.

  Returns `value` unchanged when the encoding is nil, UTF-8 or unsupported, and
  when the value holds a character the charset cannot represent.
  """
  @spec encode(String.t(), String.t() | nil) :: binary()
  def encode(value, encoding) when is_binary(value) do
    case codepage(encoding) do
      {:windows, name} ->
        case Windows.encode(value, name) do
          {:ok, bytes} -> bytes
          :error -> value
        end

      name when is_binary(name) ->
        case Codepagex.from_string(value, name) do
          {:ok, bytes} -> bytes
          {:error, _} -> value
        end

      _ ->
        value
    end
  end

  defp warn_unsupported_once(encoding) do
    key = {__MODULE__, :unsupported, encoding}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)
      Logger.warning("Cardigann: unsupported encoding #{inspect(encoding)}, using the raw body")
    end

    :ok
  end

  defp codepage(nil), do: :utf8

  defp codepage(encoding) when is_binary(encoding) do
    normalized = encoding |> String.upcase() |> String.replace(["-", "_"], "")

    if normalized in ["UTF8", ""] do
      :utf8
    else
      case Map.get(@names, normalized) do
        {:windows, _} = windows ->
          windows

        name when is_binary(name) ->
          # Codepagex resolves string names with String.to_existing_atom/1, so
          # its mapping module (which defines those atoms) must be loaded first.
          Code.ensure_loaded(Codepagex.Mappings)
          name

        nil ->
          nil
      end
    end
  end
end
