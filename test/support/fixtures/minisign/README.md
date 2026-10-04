# minisign fixtures

Generated with the minisign CLI (0.12) so `Mydia.Plugins.Index.Signature` is
checked against the real tool, not only against our own test signer.

`test.key` is a throwaway, unencrypted test key. It signs nothing outside this
directory. To regenerate:

    nix shell nixpkgs#minisign -c minisign -G -W -p test.pub -s test.key
    printf '%s' '{"version":2,"name":"Fixture Plugins","plugins":[]}' > catalog.json
    minisign -S -s test.key -m catalog.json -x catalog.json.ED.minisig -t "fixture prehashed"
    minisign -S -l -s test.key -m catalog.json -x catalog.json.Ed.minisig -t "fixture legacy"
