{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
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

    ecto = buildMix rec {
      name = "ecto";
      version = "3.14.3";

      src = fetchHex {
        pkg = "ecto";
        version = "${version}";
        sha256 = "da2548bd3ced0f56c27d54255389bbbb8f110150ce15cffc95ec0cafa364465c";
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

      beamDeps = [ db_connection decimal ecto telemetry ];
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

    error_tracker = buildMix rec {
      name = "error_tracker";
      version = "0.9.0";

      src = fetchHex {
        pkg = "error_tracker";
        version = "${version}";
        sha256 = "1de7d89ec9034c3b7282b6bd2d0584ca98cddc51e87bf0979ba71f6182803ac4";
      };

      beamDeps = [ ecto ecto_sql ecto_sqlite3 jason phoenix_ecto phoenix_live_view plug ];
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
      version = "0.2.0";

      src = fetchHex {
        pkg = "fine";
        version = "${version}";
        sha256 = "6f69a9e8dadbfd017b27f611b000362870683ae65f28aec904f36ec4c5058db5";
      };

      beamDeps = [];
    };

    gen_smtp = buildRebar3 rec {
      name = "gen_smtp";
      version = "1.3.0";

      src = fetchHex {
        pkg = "gen_smtp";
        version = "${version}";
        sha256 = "0b73fbf069864ecbce02fe653b16d3f35fd889d0fdd4e14527675565c39d84e6";
      };

      beamDeps = [ ranch ];
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

    idna = buildRebar3 rec {
      name = "idna";
      version = "7.1.0";

      src = fetchHex {
        pkg = "idna";
        version = "${version}";
        sha256 = "6ae959a025bf36df61a8cab8508d9654891b5426a84c44d82deaffd6ddf8c71f";
      };

      beamDeps = [];
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

    lazy_html = buildMix rec {
      name = "lazy_html";
      version = "0.1.14";

      src = fetchHex {
        pkg = "lazy_html";
        version = "${version}";
        sha256 = "99210889b0cc591398d006def761f2faef438d1ac77d045a527791733571dc0c";
      };

      beamDeps = [ cc_precompiler elixir_make fine ];
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

    nimble_options = buildMix rec {
      name = "nimble_options";
      version = "1.2.0";

      src = fetchHex {
        pkg = "nimble_options";
        version = "${version}";
        sha256 = "3a784a75ef9e407619c8c9e98239b1acd29216deb737044a8c1063e2671ce6d9";
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

    phoenix = buildMix rec {
      name = "phoenix";
      version = "1.8.16";

      src = fetchHex {
        pkg = "phoenix";
        version = "${version}";
        sha256 = "e7355c35889305bc539eb09dae2393abcbaf0f65f6874a3f0dcb5f0ec53737fe";
      };

      beamDeps = [ bandit jason phoenix_pubsub phoenix_template plug plug_crypto telemetry websock_adapter ];
    };

    phoenix_ecto = buildMix rec {
      name = "phoenix_ecto";
      version = "4.7.0";

      src = fetchHex {
        pkg = "phoenix_ecto";
        version = "${version}";
        sha256 = "1d75011e4254cb4ddf823e81823a9629559a1be93b4321a6a5f11a5306fbf4cc";
      };

      beamDeps = [ ecto phoenix_html plug ];
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

    ranch = buildRebar3 rec {
      name = "ranch";
      version = "2.4.0";

      src = fetchHex {
        pkg = "ranch";
        version = "${version}";
        sha256 = "64d98b8c61d39b7b9a2e2cf92ae659b8623a69766f415ae13dc726864ec04ab9";
      };

      beamDeps = [];
    };

    redix = buildMix rec {
      name = "redix";
      version = "1.10.0";

      src = fetchHex {
        pkg = "redix";
        version = "${version}";
        sha256 = "a5e383ecbf7b4364a710167e0c1a34edb157aeb00f722367a66c320664f33dec";
      };

      beamDeps = [ nimble_options telemetry ];
    };

    req = buildMix rec {
      name = "req";
      version = "0.7.5";

      src = fetchHex {
        pkg = "req";
        version = "${version}";
        sha256 = "576853c4bf403faa3c1fa5d093e0759227083b78f8a6864c67d62c0a9c45514d";
      };

      beamDeps = [ finch jason mime plug ];
    };

    swoosh = buildMix rec {
      name = "swoosh";
      version = "1.29.3";

      src = fetchHex {
        pkg = "swoosh";
        version = "${version}";
        sha256 = "844719cc70ba28b1c042461ddafbbd5088c485ccd89aa84ef5bfc65b84345d20";
      };

      beamDeps = [ bandit finch gen_smtp idna jason mime plug req telemetry ];
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

      beamDeps = [ bandit plug websock ];
    };
  };
in self

