{
  description = "nim-entrypoints - alternative entry points into a Nim program's main module";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";

    # Optional dependency: the modules `entrypoints/clispec` and
    # `entrypoints/describe` import clispec. Its sources only; the tests put
    # them on the Nim path (`ENTRYPOINTS_CLISPEC_PATH`).
    nim-cli-spec = {
      url = "github:metacraft-labs/nim-cli-spec/agents";
      flake = false;
    };

    # What the nim-testutils compatibility test builds against: the real
    # nim-testutils and the packages its `moduletests` and `fuzzing` modules
    # import. Sources only. The library itself needs none of them.
    nim-testutils = {
      url = "github:status-im/nim-testutils";
      flake = false;
    };
    nim-unittest2 = {
      url = "github:status-im/nim-unittest2";
      flake = false;
    };
    nim-stew = {
      url = "github:status-im/nim-stew";
      flake = false;
    };
    nim-results = {
      url = "github:arnetheduck/nim-results";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          version = builtins.replaceStrings [ "\n" "\r" ] [ "" "" ] (builtins.readFile ./version.txt);
          # A second, newer Nim for `just lint`'s cross-OS check only: the
          # metacraft-labs/nim fork (Nim 2.3.1 devel). Its standard library
          # differs from 2.2's on Windows, so code that type-checks for
          # Windows with 2.2 can fail with it. It is taken from the reprobuild
          # flake that `nixos-modules` already pins, so this repository
          # defines no second build of it and follows that pin when
          # `nix flake update nixos-modules` moves it. The main compiler stays
          # nixpkgs' `nim`.
          nimFork = inputs.nixos-modules.inputs.reprobuild.packages.${system}.nim-fork;
        in
        {
          # The dev env `repro.nim`'s `devEnv` activates (`useFlakeDevShell()`)
          # and CI enters through setup-dev-env. It must stand on its own: CI
          # checks this repository out without the workspace around it.
          #
          # `mkShell`'s stdenv supplies the C back-end `nim c` shells out to
          # (gcc on Linux, clang on macOS), matching the `uses:` floor in
          # `repro.nim`.
          #
          # No shellHook installs git hooks. The rules live in the committed
          # `.pre-commit-config.yaml` (the flake provides the tools, the
          # committed config provides the rules), installed with
          # `prek install`.
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nim
              just
              git
              # pre-commit tooling for the committed config
              prek
              uv
              editorconfig-checker
              nixfmt
              prettier
            ];
            # The further compilers `just lint` runs its cross-OS check with
            # (see the Justfile); the recipe refuses to run without one.
            ENTRYPOINTS_EXTRA_NIM = "${nimFork}/bin/nim";
            # Where the tests find the optional dependency and the packages
            # of the compatibility test (see tests/harness.nim).
            ENTRYPOINTS_CLISPEC_PATH = "${inputs.nim-cli-spec}/src";
            ENTRYPOINTS_TESTUTILS_PATH = "${inputs.nim-testutils}";
            ENTRYPOINTS_NIM_PATHS = "${inputs.nim-unittest2}:${inputs.nim-stew}:${inputs.nim-results}";
          };

          # The library is source: consumers put `src/` on their Nim path
          # (and `compat/` ahead of nim-testutils, to use the compatibility
          # modules).
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "nim-entrypoints";
            inherit version;
            src = ./.;
            dontBuild = true;
            installPhase = ''
              mkdir -p $out
              cp -R src compat entrypoints.nimble version.txt README.md LICENSE $out/
            '';
          };
        };
    };
}
