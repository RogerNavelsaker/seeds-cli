# seeds-cli

Nix packaging scaffold for `@os-eco/seeds-cli`.

This repository is intentionally stubbed for later Flox integration.

## Layout

- `flake.nix`: package and dev shell entrypoint
- `nix/package.nix`: Bun-wrapped Nix derivation template
- `nix/package-manifest.json`: upstream package metadata to fill in later

## Next steps

1. Replace the placeholder version, tarball URL, hash, and entrypoint in `nix/package-manifest.json`.
2. Set `"stubbed": false`.
3. Build with `nix build`.
