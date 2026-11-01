{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    absinthe = buildMix rec {
      name = "absinthe";
      version = "1.12.0";

      src = fetchHex {
        pkg = "absinthe";
        version = "${version}";
        sha256 = "b0672939fa75c24b6286c784edc01bec1bedfbe58885acdda5d097c7053b03c6";
      };

      beamDeps = [ dataloader decimal nimble_parsec telemetry ];
    };

    absinthe_plug = buildMix rec {
      name = "absinthe_plug";
      version = "1.5.10";

      src = fetchHex {
        pkg = "absinthe_plug";
        version = "${version}";
        sha256 = "489ac1951c8e4128571141c60a0669a720619bc161f801a8c6be8cfaf7ab0979";
      };

      beamDeps = [ absinthe plug ];
    };

    absinthe_relay = buildMix rec {
      name = "absinthe_relay";
      version = "1.6.0";

      src = fetchHex {
        pkg = "absinthe_relay";
        version = "${version}";
        sha256 = "32d6397a7af3fd02678ef9bc8e2f574487f14593cb3e4f9110fb1c695d4d2ac0";
      };

      beamDeps = [ absinthe ecto ];
    };

    argon2_elixir = buildMix rec {
      name = "argon2_elixir";
      version = "4.1.3";

      src = fetchHex {
        pkg = "argon2_elixir";
        version = "${version}";
        sha256 = "7c295b8d8e0eaf6f43641698f962526cdf87c6feb7d14bd21e599271b510608c";
      };

      beamDeps = [ comeonin elixir_make ];
    };

    asn1_compiler = buildMix rec {
      name = "asn1_compiler";
      version = "0.1.1";

      src = fetchHex {
        pkg = "asn1_compiler";
        version = "${version}";
        sha256 = "c250d24c22f1a3f305d88864400f9ac2df55c6886e1e3a030e2946efeb94695e";
      };

      beamDeps = [];
    };

    bandit = buildMix rec {
      name = "bandit";
      version = "1.14.1";

      src = fetchHex {
        pkg = "bandit";
        version = "${version}";
        sha256 = "87c7ee5e08fb5f22d4e072e681e1101266a21432889b08ef8d0cb0c1450f8bba";
      };

      beamDeps = [ hpax plug telemetry thousand_island websock ];
    };

    bcrypt_elixir = buildMix rec {
      name = "bcrypt_elixir";
      version = "3.3.2";

      src = fetchHex {
        pkg = "bcrypt_elixir";
        version = "${version}";
        sha256 = "471be5151874ae7931911057d1467d908955f93554f7a6cd1b7d804cac8cef53";
      };

      beamDeps = [ comeonin elixir_make ];
    };

    bunt = buildMix rec {
      name = "bunt";
      version = "1.0.0";

      src = fetchHex {
        pkg = "bunt";
        version = "${version}";
        sha256 = "dc5f86aa08a5f6fa6b8096f0735c4e76d54ae5c9fa2c143e5a1fc7c1cd9bb6b5";
      };

      beamDeps = [];
    };

    bypass = buildMix rec {
      name = "bypass";
      version = "2.1.0";

      src = fetchHex {
        pkg = "bypass";
        version = "${version}";
        sha256 = "d9b5df8fa5b7a6efa08384e9bbecfe4ce61c77d28a4282f79e02f1ef78d96b80";
      };

      beamDeps = [ plug plug_cowboy ranch ];
    };

    cbor = buildMix rec {
      name = "cbor";
      version = "1.0.2";

      src = fetchHex {
        pkg = "cbor";
        version = "${version}";
        sha256 = "edbc9b4a16eb93a582437b9b249c340a75af03958e338fb43d8c1be9fc65b864";
      };

      beamDeps = [];
    };

    cc_precompiler = buildMix rec {
      name = "cc_precompiler";
      version = "0.1.11";

      src = fetchHex {
        pkg = "cc_precompiler";
        version = "${version}";
        sha256 = "3427232caf0835f94680e5bcf082408a70b48ad68a5f5c0b02a3bea9f3a075b9";
      };

      beamDeps = [ elixir_make ];
    };

    certifi = buildRebar3 rec {
      name = "certifi";
      version = "2.15.0";

      src = fetchHex {
        pkg = "certifi";
        version = "${version}";
        sha256 = "b147ed22ce71d72eafdad94f055165c1c182f61a2ff49df28bcc71d1d5b94a60";
      };

      beamDeps = [];
    };

    codepagex = buildMix rec {
      name = "codepagex";
      version = "0.2.0";

      src = fetchHex {
        pkg = "codepagex";
        version = "${version}";
        sha256 = "fbe30e7058f2b6d06b9eaa6267f8ad5241f7315cdac186b6da414da92fb8ee1a";
      };

      beamDeps = [];
    };

    combine = buildMix rec {
      name = "combine";
      version = "0.10.0";

      src = fetchHex {
        pkg = "combine";
        version = "${version}";
        sha256 = "1b1dbc1790073076580d0d1d64e42eae2366583e7aecd455d1215b0d16f2451b";
      };

      beamDeps = [];
    };

    comeonin = buildMix rec {
      name = "comeonin";
      version = "5.5.1";

      src = fetchHex {
        pkg = "comeonin";
        version = "${version}";
        sha256 = "65aac8f19938145377cee73973f192c5645873dcf550a8a6b18187d17c13ccdb";
      };

      beamDeps = [];
    };

    corsica = buildMix rec {
      name = "corsica";
      version = "2.1.3";

      src = fetchHex {
        pkg = "corsica";
        version = "${version}";
        sha256 = "616c08f61a345780c2cf662ff226816f04d8868e12054e68963e95285b5be8bc";
      };

      beamDeps = [ plug telemetry ];
    };

    cowboy = buildErlangMk rec {
      name = "cowboy";
      version = "2.20.0";

      src = fetchHex {
        pkg = "cowboy";
        version = "${version}";
        sha256 = "a0be47464a2887f71c061ce90723dc17441c9b81ba9569cd9b596eb0367d1edd";
      };

      beamDeps = [ cowlib ranch ];
    };

    cowboy_telemetry = buildRebar3 rec {
      name = "cowboy_telemetry";
      version = "0.4.0";

      src = fetchHex {
        pkg = "cowboy_telemetry";
        version = "${version}";
        sha256 = "7d98bac1ee4565d31b62d59f8823dfd8356a169e7fcbb83831b8a5397404c9de";
      };

      beamDeps = [ cowboy telemetry ];
    };

    cowlib = buildRebar3 rec {
      name = "cowlib";
      version = "2.21.0";

      src = fetchHex {
        pkg = "cowlib";
        version = "${version}";
        sha256 = "0960248773762a5319b3c17285028bc76f54f58ef0f9451367401bdf67b46274";
      };

      beamDeps = [];
    };

    credo = buildMix rec {
      name = "credo";
      version = "1.7.19";

      src = fetchHex {
        pkg = "credo";
        version = "${version}";
        sha256 = "2d8bc95d5a7bb99dd2613621d4f08c6a3575c3fd4b62e6a2b48a100352a557b8";
      };

      beamDeps = [ bunt file_system jason ];
    };

    crontab = buildMix rec {
      name = "crontab";
      version = "1.2.1";

      src = fetchHex {
        pkg = "crontab";
        version = "${version}";
        sha256 = "ab550a005380d30c05038a1abff66989591e7703b2cc0d83f446a86fab258150";
      };

      beamDeps = [ ecto ];
    };

    dataloader = buildMix rec {
      name = "dataloader";
      version = "2.0.2";

      src = fetchHex {
        pkg = "dataloader";
        version = "${version}";
        sha256 = "4c6cabc0b55e96e7de74d14bf37f4a5786f0ab69aa06764a1f39dda40079b098";
      };

      beamDeps = [ ecto telemetry ];
    };

    db_connection = buildMix rec {
      name = "db_connection";
      version = "2.10.2";

      src = fetchHex {
        pkg = "db_connection";
        version = "${version}";
        sha256 = "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93";
      };

      beamDeps = [ telemetry ];
    };

    decimal = buildMix rec {
      name = "decimal";
      version = "3.2.0";

      src = fetchHex {
        pkg = "decimal";
        version = "${version}";
        sha256 = "190bca80580ce61aa69bb0eacadd7677710205c770225c2c2c07e32a5c31b234";
      };

      beamDeps = [];
    };

    dialyxir = buildMix rec {
      name = "dialyxir";
      version = "1.4.8";

      src = fetchHex {
        pkg = "dialyxir";
        version = "${version}";
        sha256 = "cbd5a851571e5dfeb32aaf2e840bfa98b7864cb3071bf2ef5d95d1276b12e072";
      };

      beamDeps = [ erlex ];
    };

    dns_cluster = buildMix rec {
      name = "dns_cluster";
      version = "0.3.1";

      src = fetchHex {
        pkg = "dns_cluster";
        version = "${version}";
        sha256 = "afa60bbbd84463e977eeeecc0c564d8c5ddea260beccdb8d5f45cbb860846627";
      };

      beamDeps = [];
    };

    earmark = buildMix rec {
      name = "earmark";
      version = "1.4.49";

      src = fetchHex {
        pkg = "earmark";
        version = "${version}";
        sha256 = "ffad0257b92ac342b236d1744f7f19793da77bbd7281f32ccdfb44c047a05bf2";
      };

      beamDeps = [];
    };

    ecto = buildMix rec {
      name = "ecto";
      version = "3.14.2";

      src = fetchHex {
        pkg = "ecto";
        version = "${version}";
        sha256 = "25d60b8c816a07d19d85b80bdf60978bd8b102209dda198d768cd7c6745339a6";
      };

      beamDeps = [ decimal jason telemetry ];
    };

    ecto_sql = buildMix rec {
      name = "ecto_sql";
      version = "3.14.0";

      src = fetchHex {
        pkg = "ecto_sql";
        version = "${version}";
        sha256 = "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949";
      };

      beamDeps = [ db_connection decimal ecto postgrex telemetry ];
    };

    ecto_sqlite3 = buildMix rec {
      name = "ecto_sqlite3";
      version = "0.26.0";

      src = fetchHex {
        pkg = "ecto_sqlite3";
        version = "${version}";
        sha256 = "e04d69e185f27a604dd116144a1bad36595666546d753e9341a3f3736ee64772";
      };

      beamDeps = [ decimal ecto ecto_sql exqlite ];
    };

    elixir_make = buildMix rec {
      name = "elixir_make";
      version = "0.10.1";

      src = fetchHex {
        pkg = "elixir_make";
        version = "${version}";
        sha256 = "ce1eaa234bc87f0279718e793fd6f8ad35b4e8ee8d412329e3879eee8d40adba";
      };

      beamDeps = [];
    };

    eqrcode = buildMix rec {
      name = "eqrcode";
      version = "0.2.1";

      src = fetchHex {
        pkg = "eqrcode";
        version = "${version}";
        sha256 = "d5828a222b904c68360e7dc2a40c3ef33a1328b7c074583898040f389f928025";
      };

      beamDeps = [];
    };

    erlex = buildMix rec {
      name = "erlex";
      version = "0.2.9";

      src = fetchHex {
        pkg = "erlex";
        version = "${version}";
        sha256 = "8cfffc0ec7159e6d73de2ab28a588064de80f88b2798d5cbe4482cbbc200178b";
      };

      beamDeps = [];
    };

    error_tracker = buildMix rec {
      name = "error_tracker";
      version = "0.9.0";

      src = fetchHex {
        pkg = "error_tracker";
        version = "${version}";
        sha256 = "1de7d89ec9034c3b7282b6bd2d0584ca98cddc51e87bf0979ba71f6182803ac4";
      };

      beamDeps = [ ecto ecto_sql ecto_sqlite3 jason phoenix_ecto phoenix_live_view plug postgrex ];
    };

    esbuild = buildMix rec {
      name = "esbuild";
      version = "0.10.1";

      src = fetchHex {
        pkg = "esbuild";
        version = "${version}";
        sha256 = "890f251330052dcacafa40c409769e7c42e3876fb0ae450707bde831be7b34ea";
      };

      beamDeps = [ jason ];
    };

    ex_machina = buildMix rec {
      name = "ex_machina";
      version = "2.8.2";

      src = fetchHex {
        pkg = "ex_machina";
        version = "${version}";
        sha256 = "42f551b2a3a26d138788160d44e391a6bf31266af48125c2b935f24521ebd644";
      };

      beamDeps = [ ecto ecto_sql ];
    };

    expo = buildMix rec {
      name = "expo";
      version = "1.1.1";

      src = fetchHex {
        pkg = "expo";
        version = "${version}";
        sha256 = "5fb308b9cb359ae200b7e23d37c76978673aa1b06e2b3075d814ce12c5811640";
      };

      beamDeps = [];
    };

    exqlite = buildMix rec {
      name = "exqlite";
      version = "0.43.0";

      src = fetchHex {
        pkg = "exqlite";
        version = "${version}";
        sha256 = "aa9996f5f582b01f641076632a03bfe139655606b2ba2c86bf528656adf22a5a";
      };

      beamDeps = [ cc_precompiler db_connection elixir_make ];
    };

    file_system = buildMix rec {
      name = "file_system";
      version = "1.1.1";

      src = fetchHex {
        pkg = "file_system";
        version = "${version}";
        sha256 = "7a15ff97dfe526aeefb090a7a9d3d03aa907e100e262a0f8f7746b78f8f87a5d";
      };

      beamDeps = [];
    };

    finch = buildMix rec {
      name = "finch";
      version = "0.24.0";

      src = fetchHex {
        pkg = "finch";
        version = "${version}";
        sha256 = "33ba40069c3587c2f99f9125b766e19dad87d6d54be3c6961db2304df04cef00";
      };

      beamDeps = [ mime mint nimble_options nimble_pool telemetry ];
    };

    fine = buildMix rec {
      name = "fine";
      version = "0.1.6";

      src = fetchHex {
        pkg = "fine";
        version = "${version}";
        sha256 = "5638eb4495488e885ebec167fa57973e5c35e1a50c344eb7666c90ec1c4e3b12";
      };

      beamDeps = [];
    };

    floki = buildMix rec {
      name = "floki";
      version = "0.38.4";

      src = fetchHex {
        pkg = "floki";
        version = "${version}";
        sha256 = "bdb34645eee8e79845c7edaca2d4099a52804ee4d4a3ecc683a69451f0244973";
      };

      beamDeps = [];
    };

    gettext = buildMix rec {
      name = "gettext";
      version = "0.26.2";

      src = fetchHex {
        pkg = "gettext";
        version = "${version}";
        sha256 = "aa978504bcf76511efdc22d580ba08e2279caab1066b76bb9aa81c4a1e0a32a5";
      };

      beamDeps = [ expo ];
    };

    guardian = buildMix rec {
      name = "guardian";
      version = "2.5.0";

      src = fetchHex {
        pkg = "guardian";
        version = "${version}";
        sha256 = "bc75cc9374825194060b0cd3230ce4440df23d8509d1f17472b210d3ee525790";
      };

      beamDeps = [ jose plug ];
    };

    hackney = buildRebar3 rec {
      name = "hackney";
      version = "1.25.0";

      src = fetchHex {
        pkg = "hackney";
        version = "${version}";
        sha256 = "7209bfd75fd1f42467211ff8f59ea74d6f2a9e81cbcee95a56711ee79fd6b1d4";
      };

      beamDeps = [ certifi idna metrics mimerl parse_trans ssl_verify_fun unicode_util_compat ];
    };

    hpax = buildMix rec {
      name = "hpax";
      version = "1.1.0";

      src = fetchHex {
        pkg = "hpax";
        version = "${version}";
        sha256 = "0b8d0f05832f55571d65ac720f79bf8994138ffbb133209dc4685eae0ad456a8";
      };

      beamDeps = [];
    };

    httpoison = buildMix rec {
      name = "httpoison";
      version = "2.3.0";

      src = fetchHex {
        pkg = "httpoison";
        version = "${version}";
        sha256 = "d388ee70be56d31a901e333dbcdab3682d356f651f93cf492ba9f06056436a2c";
      };

      beamDeps = [ hackney ];
    };

    idna = buildRebar3 rec {
      name = "idna";
      version = "6.1.1";

      src = fetchHex {
        pkg = "idna";
        version = "${version}";
        sha256 = "92376eb7894412ed19ac475e4a86f7b413c1b9fbb5bd16dccd57934157944cea";
      };

      beamDeps = [ unicode_util_compat ];
    };

    jason = buildMix rec {
      name = "jason";
      version = "1.4.5";

      src = fetchHex {
        pkg = "jason";
        version = "${version}";
        sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
      };

      beamDeps = [ decimal ];
    };

    jose = buildMix rec {
      name = "jose";
      version = "1.11.12";

      src = fetchHex {
        pkg = "jose";
        version = "${version}";
        sha256 = "31e92b653e9210b696765cdd885437457de1add2a9011d92f8cf63e4641bab7b";
      };

      beamDeps = [];
    };

    lazy_html = buildMix rec {
      name = "lazy_html";
      version = "0.1.13";

      src = fetchHex {
        pkg = "lazy_html";
        version = "${version}";
        sha256 = "9a8405d6785fe6f8423b86e0ec5f21806ef79941fe853eac3d14fbbb173c34e9";
      };

      beamDeps = [ cc_precompiler elixir_make fine ];
    };

    libgraph = buildMix rec {
      name = "libgraph";
      version = "0.16.0";

      src = fetchHex {
        pkg = "libgraph";
        version = "${version}";
        sha256 = "41ca92240e8a4138c30a7e06466acc709b0cbb795c643e9e17174a178982d6bf";
      };

      beamDeps = [];
    };

    metrics = buildRebar3 rec {
      name = "metrics";
      version = "1.0.1";

      src = fetchHex {
        pkg = "metrics";
        version = "${version}";
        sha256 = "69b09adddc4f74a40716ae54d140f93beb0fb8978d8636eaded0c31b6f099f16";
      };

      beamDeps = [];
    };

    mime = buildMix rec {
      name = "mime";
      version = "2.0.7";

      src = fetchHex {
        pkg = "mime";
        version = "${version}";
        sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
      };

      beamDeps = [];
    };

    mimerl = buildRebar3 rec {
      name = "mimerl";
      version = "1.5.0";

      src = fetchHex {
        pkg = "mimerl";
        version = "${version}";
        sha256 = "db648ce065bae14ea84ca8b5dd123f42f49417cef693541110bf6f9e9be9ecc4";
      };

      beamDeps = [];
    };

    mint = buildMix rec {
      name = "mint";
      version = "1.11.0";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "c6279ba2d6aa3a383a1d4cfbe7b59f42e6efd400f58d8e2acfeac48a438693ab";
      };

      beamDeps = [ hpax ];
    };

    mix_unused = buildMix rec {
      name = "mix_unused";
      version = "0.4.1";

      src = fetchHex {
        pkg = "mix_unused";
        version = "${version}";
        sha256 = "fa21f688a88e0710e3d96ac1c8e5a6181aea8a75c8a4214f0edcfeb069b831a3";
      };

      beamDeps = [ libgraph ];
    };

    nimble_csv = buildMix rec {
      name = "nimble_csv";
      version = "1.3.0";

      src = fetchHex {
        pkg = "nimble_csv";
        version = "${version}";
        sha256 = "41ccdc18f7c8f8bb06e84164fc51635321e80d5a3b450761c4997d620925d619";
      };

      beamDeps = [];
    };

    nimble_options = buildMix rec {
      name = "nimble_options";
      version = "1.1.1";

      src = fetchHex {
        pkg = "nimble_options";
        version = "${version}";
        sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
      };

      beamDeps = [];
    };

    nimble_parsec = buildMix rec {
      name = "nimble_parsec";
      version = "1.4.2";

      src = fetchHex {
        pkg = "nimble_parsec";
        version = "${version}";
        sha256 = "4b21398942dda052b403bbe1da991ccd03a053668d147d53fb8c4e0efe09c973";
      };

      beamDeps = [];
    };

    nimble_pool = buildMix rec {
      name = "nimble_pool";
      version = "1.1.0";

      src = fetchHex {
        pkg = "nimble_pool";
        version = "${version}";
        sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
      };

      beamDeps = [];
    };

    nimble_totp = buildMix rec {
      name = "nimble_totp";
      version = "1.0.0";

      src = fetchHex {
        pkg = "nimble_totp";
        version = "${version}";
        sha256 = "6ce5e4c068feecdb782e85b18237f86f66541523e6bad123e02ee1adbe48eda9";
      };

      beamDeps = [];
    };

    oban = buildMix rec {
      name = "oban";
      version = "2.24.2";

      src = fetchHex {
        pkg = "oban";
        version = "${version}";
        sha256 = "605a3b61d554ab416e0cf462b5ea060f7d19ae3dbf1516ec6b5ee30aeb1a5d0b";
      };

      beamDeps = [ ecto_sql ecto_sqlite3 jason postgrex telemetry ];
    };

    oidcc = buildMix rec {
      name = "oidcc";
      version = "3.6.0";

      src = fetchHex {
        pkg = "oidcc";
        version = "${version}";
        sha256 = "99b26b1db95d617150416b18a7a84bb09525007fdbbcf963a60edb6156c6a1ce";
      };

      beamDeps = [ jose telemetry telemetry_registry ];
    };

    parse_trans = buildRebar3 rec {
      name = "parse_trans";
      version = "3.4.1";

      src = fetchHex {
        pkg = "parse_trans";
        version = "${version}";
        sha256 = "620a406ce75dada827b82e453c19cf06776be266f5a67cff34e1ef2cbb60e49a";
      };

      beamDeps = [];
    };

    peep = buildMix rec {
      name = "peep";
      version = "5.0.1";

      src = fetchHex {
        pkg = "peep";
        version = "${version}";
        sha256 = "21969af7920b0ad7f17a8532489768c87cc26b759de964e6f7538ff886e95331";
      };

      beamDeps = [ nimble_options plug telemetry telemetry_metrics ];
    };

    phoenix = buildMix rec {
      name = "phoenix";
      version = "1.8.16";

      src = fetchHex {
        pkg = "phoenix";
        version = "${version}";
        sha256 = "e7355c35889305bc539eb09dae2393abcbaf0f65f6874a3f0dcb5f0ec53737fe";
      };

      beamDeps = [ bandit jason phoenix_pubsub phoenix_template plug plug_cowboy plug_crypto telemetry websock_adapter ];
    };

    phoenix_ecto = buildMix rec {
      name = "phoenix_ecto";
      version = "4.7.0";

      src = fetchHex {
        pkg = "phoenix_ecto";
        version = "${version}";
        sha256 = "1d75011e4254cb4ddf823e81823a9629559a1be93b4321a6a5f11a5306fbf4cc";
      };

      beamDeps = [ ecto phoenix_html plug postgrex ];
    };

    phoenix_html = buildMix rec {
      name = "phoenix_html";
      version = "4.4.0";

      src = fetchHex {
        pkg = "phoenix_html";
        version = "${version}";
        sha256 = "94832038da7ab8f86d4c0d36f7797a269fd06fe611f25c69f55108c075505228";
      };

      beamDeps = [];
    };

    phoenix_live_dashboard = buildMix rec {
      name = "phoenix_live_dashboard";
      version = "0.9.1";

      src = fetchHex {
        pkg = "phoenix_live_dashboard";
        version = "${version}";
        sha256 = "de25e1a28cfb64413d8bdaf3ba5b64da1a19e0ed44a02320119523cc45da051d";
      };

      beamDeps = [ ecto mime phoenix_live_view telemetry_metrics ];
    };

    phoenix_live_reload = buildMix rec {
      name = "phoenix_live_reload";
      version = "1.7.0";

      src = fetchHex {
        pkg = "phoenix_live_reload";
        version = "${version}";
        sha256 = "dc9f44271aa6fc4ab7797f2aa374ba096ef2c87520586280eb095626b7387a68";
      };

      beamDeps = [ file_system phoenix ];
    };

    phoenix_live_view = buildMix rec {
      name = "phoenix_live_view";
      version = "1.2.13";

      src = fetchHex {
        pkg = "phoenix_live_view";
        version = "${version}";
        sha256 = "a5cd2a3df10552bce6b7e68e5d376ff3b46cca3ca62d6c43bd4398d80c197fbe";
      };

      beamDeps = [ jason lazy_html phoenix phoenix_html phoenix_template plug telemetry ];
    };

    phoenix_pubsub = buildMix rec {
      name = "phoenix_pubsub";
      version = "2.4.1";

      src = fetchHex {
        pkg = "phoenix_pubsub";
        version = "${version}";
        sha256 = "352fba7a87bf61395b6e97da66944ad9b1bfe5459e5981039f60d68270bd9700";
      };

      beamDeps = [];
    };

    phoenix_template = buildMix rec {
      name = "phoenix_template";
      version = "1.1.0";

      src = fetchHex {
        pkg = "phoenix_template";
        version = "${version}";
        sha256 = "eba70070de79b2c3501ef205a74a69f98ab352f3785aa15da9ed161f9fe0fd5d";
      };

      beamDeps = [ phoenix_html ];
    };

    plug = buildMix rec {
      name = "plug";
      version = "1.20.3";

      src = fetchHex {
        pkg = "plug";
        version = "${version}";
        sha256 = "be266aee1b8536ef6409d58cf39a3121319f0ec47cfa1b24024485aa0e76ad76";
      };

      beamDeps = [ mime plug_crypto telemetry ];
    };

    plug_cowboy = buildMix rec {
      name = "plug_cowboy";
      version = "2.9.0";

      src = fetchHex {
        pkg = "plug_cowboy";
        version = "${version}";
        sha256 = "2002bafba4f3a45b55a58e68d70211b153a7ed18d37edb1ceb6e96e7a92c422e";
      };

      beamDeps = [ cowboy cowboy_telemetry plug ];
    };

    plug_crypto = buildMix rec {
      name = "plug_crypto";
      version = "2.2.1";

      src = fetchHex {
        pkg = "plug_crypto";
        version = "${version}";
        sha256 = "4417ccbd8f85e627321cd07d2ab9c4b621f1fd883b9905af241f9b4b780b94b6";
      };

      beamDeps = [];
    };

    postgrex = buildMix rec {
      name = "postgrex";
      version = "0.22.4";

      src = fetchHex {
        pkg = "postgrex";
        version = "${version}";
        sha256 = "4aae45a2d60e35b04eea2602440be152fae332901f1fc7a60fc7cb7f0f9a9c5a";
      };

      beamDeps = [ db_connection decimal jason ];
    };

    ranch = buildRebar3 rec {
      name = "ranch";
      version = "1.8.1";

      src = fetchHex {
        pkg = "ranch";
        version = "${version}";
        sha256 = "aed58910f4e21deea992a67bf51632b6d60114895eb03bb392bb733064594dd0";
      };

      beamDeps = [];
    };

    req = buildMix rec {
      name = "req";
      version = "0.7.5";

      src = fetchHex {
        pkg = "req";
        version = "${version}";
        sha256 = "576853c4bf403faa3c1fa5d093e0759227083b78f8a6864c67d62c0a9c45514d";
      };

      beamDeps = [ finch jason mime nimble_csv plug ];
    };

    rustler = buildMix rec {
      name = "rustler";
      version = "0.38.0";

      src = fetchHex {
        pkg = "rustler";
        version = "${version}";
        sha256 = "704c03c1bf66be12b031c5a389347b91c81c5cb819a24b068b0de36fe4a5652a";
      };

      beamDeps = [ jason ];
    };

    rustler_precompiled = buildMix rec {
      name = "rustler_precompiled";
      version = "0.9.0";

      src = fetchHex {
        pkg = "rustler_precompiled";
        version = "${version}";
        sha256 = "471d97315bd3bf7b64623418b3693eedd8e47de3d1cb79a0ac8f9da7d770d94c";
      };

      beamDeps = [ rustler ];
    };

    ssl_verify_fun = buildRebar3 rec {
      name = "ssl_verify_fun";
      version = "1.1.7";

      src = fetchHex {
        pkg = "ssl_verify_fun";
        version = "${version}";
        sha256 = "fe4c190e8f37401d30167c8c405eda19469f34577987c76dde613e838bbc67f8";
      };

      beamDeps = [];
    };

    sweet_xml = buildMix rec {
      name = "sweet_xml";
      version = "0.7.5";

      src = fetchHex {
        pkg = "sweet_xml";
        version = "${version}";
        sha256 = "193b28a9b12891cae351d81a0cead165ffe67df1b73fe5866d10629f4faefb12";
      };

      beamDeps = [];
    };

    tailwind = buildMix rec {
      name = "tailwind";
      version = "0.5.2";

      src = fetchHex {
        pkg = "tailwind";
        version = "${version}";
        sha256 = "e0e5fd9799fb9231b97e52ce074d9ff509043d1946713a71fbc608e81eff7e66";
      };

      beamDeps = [];
    };

    telemetry = buildRebar3 rec {
      name = "telemetry";
      version = "1.4.2";

      src = fetchHex {
        pkg = "telemetry";
        version = "${version}";
        sha256 = "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1";
      };

      beamDeps = [];
    };

    telemetry_metrics = buildMix rec {
      name = "telemetry_metrics";
      version = "1.2.0";

      src = fetchHex {
        pkg = "telemetry_metrics";
        version = "${version}";
        sha256 = "71dde12fc29b58b9c77ec17ec319109e5ca848d010fc1965ed4463bba1837c07";
      };

      beamDeps = [ telemetry ];
    };

    telemetry_poller = buildRebar3 rec {
      name = "telemetry_poller";
      version = "1.3.0";

      src = fetchHex {
        pkg = "telemetry_poller";
        version = "${version}";
        sha256 = "51f18bed7128544a50f75897db9974436ea9bfba560420b646af27a9a9b35211";
      };

      beamDeps = [ telemetry ];
    };

    telemetry_registry = buildMix rec {
      name = "telemetry_registry";
      version = "0.3.2";

      src = fetchHex {
        pkg = "telemetry_registry";
        version = "${version}";
        sha256 = "e7ed191eb1d115a3034af8e1e35e4e63d5348851d556646d46ca3d1b4e16bab9";
      };

      beamDeps = [ telemetry ];
    };

    tesla = buildMix rec {
      name = "tesla";
      version = "1.20.0";

      src = fetchHex {
        pkg = "tesla";
        version = "${version}";
        sha256 = "3ecb41cb458772332752c3acdfe983e23abb991f5a43cfd69a64e9ea3f4b0061";
      };

      beamDeps = [ finch hackney jason mime mint telemetry ];
    };

    thousand_island = buildMix rec {
      name = "thousand_island";
      version = "1.6.0";

      src = fetchHex {
        pkg = "thousand_island";
        version = "${version}";
        sha256 = "4d4720470f091fc21a1311777c2ac66916c43621bffc068590c9f9bb3cd057a3";
      };

      beamDeps = [ telemetry ];
    };

    timex = buildMix rec {
      name = "timex";
      version = "3.7.13";

      src = fetchHex {
        pkg = "timex";
        version = "${version}";
        sha256 = "09588e0522669328e973b8b4fd8741246321b3f0d32735b589f78b136e6d4c54";
      };

      beamDeps = [ combine gettext tzdata ];
    };

    tower = buildMix rec {
      name = "tower";
      version = "0.8.8";

      src = fetchHex {
        pkg = "tower";
        version = "${version}";
        sha256 = "5181dff69126283b4b2fb259bd1fcbd221d6555078817bc894712e34ac3cd572";
      };

      beamDeps = [ bandit telemetry uuid_v7 ];
    };

    tzdata = buildMix rec {
      name = "tzdata";
      version = "1.1.4";

      src = fetchHex {
        pkg = "tzdata";
        version = "${version}";
        sha256 = "ab48888699de8ff4a255522fd858abe81bac2e64690a375e6cb590112cf4a24e";
      };

      beamDeps = [ hackney ];
    };

    ueberauth = buildMix rec {
      name = "ueberauth";
      version = "0.11.0";

      src = fetchHex {
        pkg = "ueberauth";
        version = "${version}";
        sha256 = "59bc851cddc77a1697e65536ee54250930e93cc3bef0a0b547b3f42bb757bffd";
      };

      beamDeps = [ plug ];
    };

    ueberauth_oidcc = buildMix rec {
      name = "ueberauth_oidcc";
      version = "0.4.2";

      src = fetchHex {
        pkg = "ueberauth_oidcc";
        version = "${version}";
        sha256 = "b9ea3c981464a5052e4f4fbf0a3c716e124da056aca30b9754654c5c6f90f8c2";
      };

      beamDeps = [ oidcc plug ueberauth ];
    };

    unicode_util_compat = buildRebar3 rec {
      name = "unicode_util_compat";
      version = "0.7.1";

      src = fetchHex {
        pkg = "unicode_util_compat";
        version = "${version}";
        sha256 = "b3a917854ce3ae233619744ad1e0102e05673136776fb2fa76234f3e03b23642";
      };

      beamDeps = [];
    };

    uuid_v7 = buildMix rec {
      name = "uuid_v7";
      version = "0.6.0";

      src = fetchHex {
        pkg = "uuid_v7";
        version = "${version}";
        sha256 = "1dc401134e61da847a7b2a3b28d2593893f457b9f2704893b1ba3ff7946ce91f";
      };

      beamDeps = [ ecto ];
    };

    wallaby = buildMix rec {
      name = "wallaby";
      version = "0.31.0";

      src = fetchHex {
        pkg = "wallaby";
        version = "${version}";
        sha256 = "a3e7a5f13c1db49d32c17dafe8d4654fe556987efd12d422673b902455871c50";
      };

      beamDeps = [ ecto_sql httpoison jason phoenix_ecto web_driver_client ];
    };

    wasmex = buildMix rec {
      name = "wasmex";
      version = "0.15.1";

      src = fetchHex {
        pkg = "wasmex";
        version = "${version}";
        sha256 = "d34a765811a2cec520299978072f0a4c0b697148c43430d6c414e350a5e9c954";
      };

      beamDeps = [ rustler rustler_precompiled ];
    };

    wax_ = buildMix rec {
      name = "wax_";
      version = "0.7.0";

      src = fetchHex {
        pkg = "wax_";
        version = "${version}";
        sha256 = "473b3378608418747e67746b7164576f1690a4ed1e044a4c8085a754269d21ce";
      };

      beamDeps = [ asn1_compiler cbor jason x509 ];
    };

    web_driver_client = buildMix rec {
      name = "web_driver_client";
      version = "0.3.0";

      src = fetchHex {
        pkg = "web_driver_client";
        version = "${version}";
        sha256 = "f89a43505b4fa5e1d5dc50818980a4d2703e390dca29fa0ad39911b0eb46b65a";
      };

      beamDeps = [ hackney jason tesla ];
    };

    websock = buildMix rec {
      name = "websock";
      version = "0.5.3";

      src = fetchHex {
        pkg = "websock";
        version = "${version}";
        sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
      };

      beamDeps = [];
    };

    websock_adapter = buildMix rec {
      name = "websock_adapter";
      version = "0.7.0";

      src = fetchHex {
        pkg = "websock_adapter";
        version = "${version}";
        sha256 = "a7243f803540425d4890e4c7bc0af9b2519e3935b6c01d9a924ba63527549d65";
      };

      beamDeps = [ bandit plug plug_cowboy websock ];
    };

    websockex = buildMix rec {
      name = "websockex";
      version = "0.5.1";

      src = fetchHex {
        pkg = "websockex";
        version = "${version}";
        sha256 = "8ef39576ed56bc3804c9cd8626f8b5d6b5721848d2726c0ccd4f05385a3c9f14";
      };

      beamDeps = [ telemetry ];
    };

    x509 = buildMix rec {
      name = "x509";
      version = "0.9.2";

      src = fetchHex {
        pkg = "x509";
        version = "${version}";
        sha256 = "4c5ede75697e565d4b0f5be04c3b71bb1fd3a090ea243af4bd7dae144e48cfc7";
      };

      beamDeps = [];
    };

    yamerl = buildRebar3 rec {
      name = "yamerl";
      version = "0.10.0";

      src = fetchHex {
        pkg = "yamerl";
        version = "${version}";
        sha256 = "346adb2963f1051dc837a2364e4acf6eb7d80097c0f53cbdc3046ec8ec4b4e6e";
      };

      beamDeps = [];
    };

    yaml_elixir = buildMix rec {
      name = "yaml_elixir";
      version = "2.12.2";

      src = fetchHex {
        pkg = "yaml_elixir";
        version = "${version}";
        sha256 = "e7c1b10122f973e6558462d51c39026ba0e14afbc6745318e990ea82cfe9e159";
      };

      beamDeps = [ yamerl ];
    };

    ymlr = buildMix rec {
      name = "ymlr";
      version = "5.1.6";

      src = fetchHex {
        pkg = "ymlr";
        version = "${version}";
        sha256 = "b36d7c72384d2cb2094d2a3c8b0c3b12303e0ccd1b7b12333b81d75b1fe0b53a";
      };

      beamDeps = [];
    };
  };
in self

