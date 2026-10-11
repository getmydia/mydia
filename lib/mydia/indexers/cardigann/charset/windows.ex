defmodule Mydia.Indexers.Cardigann.Charset.Windows do
  @moduledoc false
  # Upper halves (0x80..0xFF) of the Windows code pages Cardigann definitions
  # declare, generated from the Unicode Consortium's VENDORS/MICSFT/WINDOWS
  # mapping tables. They live here instead of in Codepagex because compiling
  # them into Codepagex needs `config :codepagex, :encodings`, which a
  # dependency built in isolation (the Nix package) never sees. U+FFFD marks a
  # byte the code page leaves undefined. Bytes below 0x80 are ASCII.

  @tables Map.new(
            %{
              "WINDOWS1250" =>
                "\u{20AC}\u{FFFD}\u{201A}\u{FFFD}\u{201E}\u{2026}\u{2020}\u{2021}\u{FFFD}\u{2030}\u{160}\u{2039}\u{15A}\u{164}\u{17D}\u{179}\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}\u{FFFD}\u{2122}\u{161}\u{203A}\u{15B}\u{165}\u{17E}\u{17A}\u{A0}\u{2C7}\u{2D8}\u{141}\u{A4}\u{104}\u{A6}\u{A7}\u{A8}\u{A9}\u{15E}\u{AB}\u{AC}\u{AD}\u{AE}\u{17B}\u{B0}\u{B1}\u{2DB}\u{142}\u{B4}\u{B5}\u{B6}\u{B7}\u{B8}\u{105}\u{15F}\u{BB}\u{13D}\u{2DD}\u{13E}\u{17C}\u{154}\u{C1}\u{C2}\u{102}\u{C4}\u{139}\u{106}\u{C7}\u{10C}\u{C9}\u{118}\u{CB}\u{11A}\u{CD}\u{CE}\u{10E}\u{110}\u{143}\u{147}\u{D3}\u{D4}\u{150}\u{D6}\u{D7}\u{158}\u{16E}\u{DA}\u{170}\u{DC}\u{DD}\u{162}\u{DF}\u{155}\u{E1}\u{E2}\u{103}\u{E4}\u{13A}\u{107}\u{E7}\u{10D}\u{E9}\u{119}\u{EB}\u{11B}\u{ED}\u{EE}\u{10F}\u{111}\u{144}\u{148}\u{F3}\u{F4}\u{151}\u{F6}\u{F7}\u{159}\u{16F}\u{FA}\u{171}\u{FC}\u{FD}\u{163}\u{2D9}",
              "WINDOWS1251" =>
                "\u{402}\u{403}\u{201A}\u{453}\u{201E}\u{2026}\u{2020}\u{2021}\u{20AC}\u{2030}\u{409}\u{2039}\u{40A}\u{40C}\u{40B}\u{40F}\u{452}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}\u{FFFD}\u{2122}\u{459}\u{203A}\u{45A}\u{45C}\u{45B}\u{45F}\u{A0}\u{40E}\u{45E}\u{408}\u{A4}\u{490}\u{A6}\u{A7}\u{401}\u{A9}\u{404}\u{AB}\u{AC}\u{AD}\u{AE}\u{407}\u{B0}\u{B1}\u{406}\u{456}\u{491}\u{B5}\u{B6}\u{B7}\u{451}\u{2116}\u{454}\u{BB}\u{458}\u{405}\u{455}\u{457}\u{410}\u{411}\u{412}\u{413}\u{414}\u{415}\u{416}\u{417}\u{418}\u{419}\u{41A}\u{41B}\u{41C}\u{41D}\u{41E}\u{41F}\u{420}\u{421}\u{422}\u{423}\u{424}\u{425}\u{426}\u{427}\u{428}\u{429}\u{42A}\u{42B}\u{42C}\u{42D}\u{42E}\u{42F}\u{430}\u{431}\u{432}\u{433}\u{434}\u{435}\u{436}\u{437}\u{438}\u{439}\u{43A}\u{43B}\u{43C}\u{43D}\u{43E}\u{43F}\u{440}\u{441}\u{442}\u{443}\u{444}\u{445}\u{446}\u{447}\u{448}\u{449}\u{44A}\u{44B}\u{44C}\u{44D}\u{44E}\u{44F}",
              "WINDOWS1252" =>
                "\u{20AC}\u{FFFD}\u{201A}\u{192}\u{201E}\u{2026}\u{2020}\u{2021}\u{2C6}\u{2030}\u{160}\u{2039}\u{152}\u{FFFD}\u{17D}\u{FFFD}\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}\u{2DC}\u{2122}\u{161}\u{203A}\u{153}\u{FFFD}\u{17E}\u{178}\u{A0}\u{A1}\u{A2}\u{A3}\u{A4}\u{A5}\u{A6}\u{A7}\u{A8}\u{A9}\u{AA}\u{AB}\u{AC}\u{AD}\u{AE}\u{AF}\u{B0}\u{B1}\u{B2}\u{B3}\u{B4}\u{B5}\u{B6}\u{B7}\u{B8}\u{B9}\u{BA}\u{BB}\u{BC}\u{BD}\u{BE}\u{BF}\u{C0}\u{C1}\u{C2}\u{C3}\u{C4}\u{C5}\u{C6}\u{C7}\u{C8}\u{C9}\u{CA}\u{CB}\u{CC}\u{CD}\u{CE}\u{CF}\u{D0}\u{D1}\u{D2}\u{D3}\u{D4}\u{D5}\u{D6}\u{D7}\u{D8}\u{D9}\u{DA}\u{DB}\u{DC}\u{DD}\u{DE}\u{DF}\u{E0}\u{E1}\u{E2}\u{E3}\u{E4}\u{E5}\u{E6}\u{E7}\u{E8}\u{E9}\u{EA}\u{EB}\u{EC}\u{ED}\u{EE}\u{EF}\u{F0}\u{F1}\u{F2}\u{F3}\u{F4}\u{F5}\u{F6}\u{F7}\u{F8}\u{F9}\u{FA}\u{FB}\u{FC}\u{FD}\u{FE}\u{FF}",
              "WINDOWS1255" =>
                "\u{20AC}\u{FFFD}\u{201A}\u{192}\u{201E}\u{2026}\u{2020}\u{2021}\u{2C6}\u{2030}\u{FFFD}\u{2039}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}\u{2DC}\u{2122}\u{FFFD}\u{203A}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{A0}\u{A1}\u{A2}\u{A3}\u{20AA}\u{A5}\u{A6}\u{A7}\u{A8}\u{A9}\u{D7}\u{AB}\u{AC}\u{AD}\u{AE}\u{AF}\u{B0}\u{B1}\u{B2}\u{B3}\u{B4}\u{B5}\u{B6}\u{B7}\u{B8}\u{B9}\u{F7}\u{BB}\u{BC}\u{BD}\u{BE}\u{BF}\u{5B0}\u{5B1}\u{5B2}\u{5B3}\u{5B4}\u{5B5}\u{5B6}\u{5B7}\u{5B8}\u{5B9}\u{FFFD}\u{5BB}\u{5BC}\u{5BD}\u{5BE}\u{5BF}\u{5C0}\u{5C1}\u{5C2}\u{5C3}\u{5F0}\u{5F1}\u{5F2}\u{5F3}\u{5F4}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{5D0}\u{5D1}\u{5D2}\u{5D3}\u{5D4}\u{5D5}\u{5D6}\u{5D7}\u{5D8}\u{5D9}\u{5DA}\u{5DB}\u{5DC}\u{5DD}\u{5DE}\u{5DF}\u{5E0}\u{5E1}\u{5E2}\u{5E3}\u{5E4}\u{5E5}\u{5E6}\u{5E7}\u{5E8}\u{5E9}\u{5EA}\u{FFFD}\u{FFFD}\u{200E}\u{200F}\u{FFFD}",
              "WINDOWS1256" =>
                "\u{20AC}\u{67E}\u{201A}\u{192}\u{201E}\u{2026}\u{2020}\u{2021}\u{2C6}\u{2030}\u{679}\u{2039}\u{152}\u{686}\u{698}\u{688}\u{6AF}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}\u{6A9}\u{2122}\u{691}\u{203A}\u{153}\u{200C}\u{200D}\u{6BA}\u{A0}\u{60C}\u{A2}\u{A3}\u{A4}\u{A5}\u{A6}\u{A7}\u{A8}\u{A9}\u{6BE}\u{AB}\u{AC}\u{AD}\u{AE}\u{AF}\u{B0}\u{B1}\u{B2}\u{B3}\u{B4}\u{B5}\u{B6}\u{B7}\u{B8}\u{B9}\u{61B}\u{BB}\u{BC}\u{BD}\u{BE}\u{61F}\u{6C1}\u{621}\u{622}\u{623}\u{624}\u{625}\u{626}\u{627}\u{628}\u{629}\u{62A}\u{62B}\u{62C}\u{62D}\u{62E}\u{62F}\u{630}\u{631}\u{632}\u{633}\u{634}\u{635}\u{636}\u{D7}\u{637}\u{638}\u{639}\u{63A}\u{640}\u{641}\u{642}\u{643}\u{E0}\u{644}\u{E2}\u{645}\u{646}\u{647}\u{648}\u{E7}\u{E8}\u{E9}\u{EA}\u{EB}\u{649}\u{64A}\u{EE}\u{EF}\u{64B}\u{64C}\u{64D}\u{64E}\u{F4}\u{64F}\u{650}\u{F7}\u{651}\u{F9}\u{652}\u{FB}\u{FC}\u{200E}\u{200F}\u{6D2}",
              "WINDOWS874" =>
                "\u{20AC}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{2026}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{A0}\u{E01}\u{E02}\u{E03}\u{E04}\u{E05}\u{E06}\u{E07}\u{E08}\u{E09}\u{E0A}\u{E0B}\u{E0C}\u{E0D}\u{E0E}\u{E0F}\u{E10}\u{E11}\u{E12}\u{E13}\u{E14}\u{E15}\u{E16}\u{E17}\u{E18}\u{E19}\u{E1A}\u{E1B}\u{E1C}\u{E1D}\u{E1E}\u{E1F}\u{E20}\u{E21}\u{E22}\u{E23}\u{E24}\u{E25}\u{E26}\u{E27}\u{E28}\u{E29}\u{E2A}\u{E2B}\u{E2C}\u{E2D}\u{E2E}\u{E2F}\u{E30}\u{E31}\u{E32}\u{E33}\u{E34}\u{E35}\u{E36}\u{E37}\u{E38}\u{E39}\u{E3A}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{E3F}\u{E40}\u{E41}\u{E42}\u{E43}\u{E44}\u{E45}\u{E46}\u{E47}\u{E48}\u{E49}\u{E4A}\u{E4B}\u{E4C}\u{E4D}\u{E4E}\u{E4F}\u{E50}\u{E51}\u{E52}\u{E53}\u{E54}\u{E55}\u{E56}\u{E57}\u{E58}\u{E59}\u{E5A}\u{E5B}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"
            },
            fn {name, chars} ->
              {name,
               chars
               |> String.to_charlist()
               |> Enum.map(&if(&1 == 0xFFFD, do: nil, else: &1))
               |> List.to_tuple()}
            end
          )

  @doc "The code page names this module can convert."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@tables)

  @doc "Decodes single-byte `bytes` of code page `name` to UTF-8; undefined bytes become U+FFFD."
  @spec decode(binary(), String.t()) :: String.t()
  def decode(bytes, name) do
    table = Map.fetch!(@tables, name)

    for <<byte <- bytes>>, into: "" do
      cond do
        byte < 0x80 -> <<byte>>
        cp = elem(table, byte - 0x80) -> <<cp::utf8>>
        true -> <<0xFFFD::utf8>>
      end
    end
  end

  @doc "Encodes UTF-8 `value` into code page `name`, or `:error` when a character has no byte."
  @spec encode(String.t(), String.t()) :: {:ok, binary()} | :error
  def encode(value, name) do
    reverse = Map.fetch!(reverse_tables(), name)

    value
    |> String.to_charlist()
    |> Enum.reduce_while([], fn
      cp, acc when cp < 0x80 ->
        {:cont, [cp | acc]}

      cp, acc ->
        case reverse do
          %{^cp => byte} -> {:cont, [byte | acc]}
          _ -> {:halt, :error}
        end
    end)
    |> case do
      :error -> :error
      bytes -> {:ok, bytes |> Enum.reverse() |> :binary.list_to_bin()}
    end
  end

  defp reverse_tables do
    :persistent_term.get({__MODULE__, :reverse}, nil) || build_reverse()
  end

  defp build_reverse do
    reverse =
      Map.new(@tables, fn {name, table} ->
        {name,
         table
         |> Tuple.to_list()
         |> Enum.with_index(0x80)
         |> Enum.reject(fn {cp, _} -> is_nil(cp) end)
         |> Map.new()}
      end)

    :persistent_term.put({__MODULE__, :reverse}, reverse)
    reverse
  end
end
