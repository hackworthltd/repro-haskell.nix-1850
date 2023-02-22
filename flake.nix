{
  description = "A reproducer for https://github.com/input-output-hk/haskell.nix/issues/1850.";

  inputs = {
    haskell-nix.url = github:input-output-hk/haskell.nix;

    # Let haskell.nix dictate the nixpkgs we use, as that will ensure
    # better haskell.nix cache hits.
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";

    # Pin hacknix, as versions after this one have a compatibility
    # issue with the `nixpkgs-unstable` pin that haskell.nix uses.
    hacknix.url = github:hackworthltd/hacknix/a7f4ac0d42c185d753ed4ad193876da08e0e2a03;

    flake-compat.url = github:edolstra/flake-compat;
    flake-compat.flake = false;

    pre-commit-hooks-nix.url = github:cachix/pre-commit-hooks.nix;
    pre-commit-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@ { flake-parts, ... }:
    let
      # A flake can get its git revision via `self.rev` if its working
      # tree is clean and its index is empty, so we use that for the
      # program version when it's available.
      #
      # When the working tree is modified or the index is not empty,
      # evaluating `self.rev` is an error. However, we *can* use
      # `self.lastModifiedDate` in that case, which is at least a bit
      # more helpful than returning "unknown" or some other static
      # value. (This should only happen when you `nix run` in a
      # modified repo. Hydra builds will always be working from a
      # clean git repo, of course.)
      version =
        let
          v = inputs.self.rev or inputs.self.lastModifiedDate;
        in
        builtins.trace "Nix repro version is ${v}" "git-${v}";
      ghcVersion = "ghc926";

      # We must keep the weeder version in sync with the version of
      # GHC we're using.
      weederVersion = "2.4.0";

      # Fourmolu updates often alter formatting arbitrarily, and we want to
      # have more control over this.
      fourmoluVersion = "0.10.1.0";

      allOverlays = [
        inputs.haskell-nix.overlay
        inputs.self.overlays.default
      ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      debug = true;

      imports = [
        inputs.pre-commit-hooks-nix.flakeModule
        ./nix/flake-parts/benchmarks.nix
      ];
      systems = [ "x86_64-linux" "aarch64-darwin" ];

      perSystem = { config, pkgs, system, ... }:
        let
          # haskell.nix does a lot of heavy lifiting for us and gives us a
          # flake for our Cabal project with the following attributes:
          # `checks`, `apps`, and `packages`.
          reproFlake = pkgs.repro.flake { };

          weeder =
            let
              weederTool = pkgs.haskell-nix.tool ghcVersion "weeder" weederVersion;
              getLibHIE = package:
                pkgs.lib.optional (package.components ? library)
                  { name = "${package.identifier.name}-library"; path = package.components.library.hie; };
              getHIE = package: component: pkgs.lib.lists.map
                (cn: {
                  name = "${package.identifier.name}-${component}-${cn}";
                  path = package.components.${component}.${cn}.hie;
                })
                (builtins.attrNames package.components.${component});
              getHIEs = package:
                getLibHIE package
                ++ pkgs.lib.concatMap (getHIE package)
                  [ "benchmarks" "exes" "sublibs" "tests" ];
              repro-packages = pkgs.haskell-nix.haskellLib.selectProjectPackages pkgs.repro;
            in
            pkgs.runCommand "weeder"
              {
                weederConfig = ./weeder.dhall;
                allHieFiles = pkgs.linkFarm
                  "repro-hie-files"
                  (pkgs.lib.concatMap getHIEs (builtins.attrValues repro-packages));
              }
              ''
                export XDG_CACHE_HOME=$(mktemp -d)
                ${weederTool}/bin/weeder --config $weederConfig --hie-directory $allHieFiles
                echo "No issues found."
                touch $out
              '';

          # Filter out any file in this repo that doesn't affect a Cabal
          # build or Haskell-related check. (Note: this doesn't need to be
          # 100% accurate, it's just an optimization to cut down on
          # extraneous Nix builds.)
          onlyHaskellSrc =
            let
              inherit (pkgs.haskell-nix) haskellSourceFilter;
              inherit (pkgs.haskell-nix.haskellLib) cleanGit cleanSourceWith;

              extraSourceFilter = name: type:
                let baseName = baseNameOf (toString name);
                in ! (
                  baseName == ".buildkite" ||
                  baseName == ".github" ||
                  pkgs.lib.hasPrefix "cabal.project.local" baseName ||
                  baseName == "flake.lock" ||
                  baseName == "flake.nix" ||
                  baseName == "README.md" ||
                  baseName == "docs" ||
                  baseName == "nix" ||
                  baseName == "nixos-tests"
                );
            in
            cleanSourceWith {
              filter = haskellSourceFilter;
              name = "repro-src";
              src = cleanSourceWith
                {
                  filter = extraSourceFilter;
                  src = cleanGit
                    {
                      src = ./.;
                    };
                };
            };
        in
        {
          # We need a `pkgs` that includes our own overlays within
          # `perSystem`. This isn't done by default, so we do this
          # workaround. See:
          #
          # https://github.com/hercules-ci/flake-parts/issues/106#issuecomment-1399041045
          _module.args.pkgs = import inputs.nixpkgs
            {
              inherit system;
              config = {
                allowUnfree = true;
                allowBroken = true;
              };
              overlays = allOverlays;
            };

          pre-commit =
            let
              # Override the default nix-pre-commit-hooks tools with the version
              # we're using.
              haskellNixTools = pkgs.haskell-nix.tools ghcVersion {
                hlint = "latest";
                fourmolu = fourmoluVersion;
                cabal-fmt = "latest";
              };
            in
            {
              check.enable = true;
              settings = {
                src = ./.;
                hooks = {
                  hlint.enable = true;
                  fourmolu.enable = true;
                  cabal-fmt.enable = true;
                  nixpkgs-fmt.enable = true;

                  actionlint = {
                    enable = true;
                    name = "actionlint";
                    entry = "${pkgs.actionlint}/bin/actionlint";
                    language = "system";
                    files = "^.github/workflows/";
                  };
                };

                # We need to force these due to
                #
                # https://github.com/cachix/pre-commit-hooks.nix/issues/204
                tools = {
                  nixpkgs-fmt = pkgs.lib.mkForce pkgs.nixpkgs-fmt;
                  hlint = pkgs.lib.mkForce haskellNixTools.hlint;
                  fourmolu = pkgs.lib.mkForce haskellNixTools.fourmolu;
                  cabal-fmt = pkgs.lib.mkForce haskellNixTools.cabal-fmt;
                };

                excludes = [
                  "repro/test/outputs"
                  ".buildkite/"
                ];
              };
            };

          packages = reproFlake.packages;

          checks = {
            inherit weeder;
          }
          # Broken on NixOS. See:
          # https://github.com/hackworthltd/primer/issues/632
          // (pkgs.lib.optionalAttrs (system == "aarch64-darwin") {

            # Make sure HLS can typecheck our project.
            check-hls = pkgs.callPackage ./nix/pkgs/check-hls {
              src = onlyHaskellSrc;

              # Don't use the flake's version here; we only want to run
              # this HLS check when the Haskell source files have
              # changed, not on every commit to this repo.
              version = "1.0";

              # This is a bit of a hack, but we don't know a better way.
              inherit (reproFlake) devShell;
            };
          })
          // reproFlake.checks;

          apps =
            let
              mkApp = pkg: script: {
                type = "app";
                program = "${pkg}/bin/${script}";
              };
            in
            (pkgs.lib.mapAttrs (name: pkg: mkApp pkg name) {
              inherit (pkgs) repro-benchmark;
            })
            // reproFlake.apps;

          devShells.default = reproFlake.devShell;

          # This is a non-standard flake output, but we don't want to
          # include benchmark runs in `packages`, because we don't
          # want them to be part of the `hydraJobs` or `ciJobs`
          # attrsets. The benchmarks need to be run in a more
          # controlled environment, and this gives us that
          # flexibility.
          benchmarks = {
            inherit (pkgs) repro-benchmark-results-html;
            inherit (pkgs) repro-benchmark-results-json;
            inherit (pkgs) repro-benchmark-results-github-action-benchmark;
          };
        };

      flake =
        let
          # See above, we need to use our own `pkgs` within the flake.
          pkgs = import inputs.nixpkgs
            {
              system = "x86_64-linux";
              config = {
                allowUnfree = true;
                allowBroken = true;
              };
              overlays = allOverlays;
            };

          benchmarkJobs = {
            inherit (inputs.self.benchmarks) x86_64-linux;

            required-benchmarks = pkgs.releaseTools.aggregate {
              name = "required-benchmarks";
              constituents = builtins.map builtins.attrValues (with inputs.self; [
                benchmarks.x86_64-linux
              ]);
              meta.description = "Required CI benchmarks";
            };
          };
        in
        {
          overlays.default = (final: prev:
            let
              repro = final.haskell-nix.cabalProject {
                compiler-nix-name = ghcVersion;
                src = ./.;
                modules = [
                  {
                    # We want -Werror for Nix builds (primarily for CI).
                    packages =
                      let
                        # Tell Tasty to detect missing golden tests,
                        # rather than silently ignoring them.
                        #
                        # Until upstream addresses the issue, this is a
                        # workaround for
                        # https://github.com/hackworthltd/primer/issues/298
                        preCheckTasty = ''
                          export TASTY_NO_CREATE=true
                        '';
                      in
                      {
                        repro = {
                          ghcOptions = [ "-Werror" ];
                          preCheck = preCheckTasty;
                        };
                      };
                  }
                  {
                    # Build everything with -O2.
                    configureFlags = [ "-O2" ];

                    # Generate HIE files for everything.
                    writeHieFiles = true;

                    # Generate nice Haddocks & a Hoogle index for
                    # everything.
                    doHaddock = true;
                    doHyperlinkSource = true;
                    doQuickjump = true;
                    doHoogle = true;
                  }
                  {
                    # These packages don't generate HIE files. See:
                    # https://github.com/input-output-hk/haskell.nix/issues/1242
                    packages.mtl-compat.writeHieFiles = false;
                    packages.bytestring-builder.writeHieFiles = false;
                  }
                  {
                    #TODO This shouldn't be necessary - see the commented-out `build-tool-depends` in repro.cabal.
                    packages.repro.components.tests.repro-test.build-tools = [ final.haskell-nix.snapshots."lts-19.9".tasty-discover ];
                  }
                  (
                    let
                      # This makes it a lot easier to see which test is the culprit when CI fails.
                      hide-successes = [ "--hide-successes" ];
                      #TODO Haskell.nix would ideally pick this up from `cabal.project`.
                      # See: https://github.com/input-output-hk/haskell.nix/issues/1149#issuecomment-946664684
                      size-cutoff = [ ]; #"--size-cutoff=32768" ];
                    in
                    {
                      packages.repro.components.tests.repro-test.testFlags = hide-successes ++ size-cutoff;
                    }
                  )
                ];

                shell = {
                  exactDeps = true;
                  withHoogle = true;

                  tools = {
                    ghcid = "latest";
                    haskell-language-server = "latest";
                    implicit-hie = "latest";

                    cabal = "latest";
                    hlint = "latest";
                    weeder = weederVersion;

                    fourmolu = fourmoluVersion;

                    cabal-fmt = "latest";

                    #TODO Explicitly requiring tasty-discover shouldn't be necessary - see the commented-out `build-tool-depends` in repro.cabal.
                    tasty-discover = "latest";
                  };

                  buildInputs = (with final; [
                    nixpkgs-fmt
                  ]);

                  shellHook = ''
                    gen-hie > hie.yaml
                    export HIE_HOOGLE_DATABASE="$(cat $(${final.which}/bin/which hoogle) | sed -n -e 's|.*--database \(.*\.hoo\).*|\1|p')"
                  '';
                };
              };

              reproFlake = repro.flake { };

              # Note: these benchmarks should only be run (in CI) on a
              # "benchmark" machine. This is enforced for our CI system
              # via Nix's `requiredSystemFeatures`.
              #
              # The `lastEnvChange` value is an impurity that we can
              # modify when we want to force a new benchmark run
              # despite the benchmarking code not having changed, as
              # otherwise Nix will cache the results. It's intended to
              # be used to track changes to the benchmarking
              # environment, such as changes to hardware, that Nix
              # doesn't know about.
              #
              # The value should be formatted as an ISO date, followed
              # by a "." and a 2-digit monotonic counter, to allow for
              # multiple changes on the same date. We store this value
              # in a `lastEnvChange` file in the derivation output, so
              # that we can examine results in the Nix store and know
              # which benchmarking environment was used to generate
              # them.
              benchmarks =
                let
                  lastEnvChange = "20230130.01";
                in
                final.callPackage ./nix/pkgs/benchmarks {
                  inherit lastEnvChange;
                };
            in
            {
              lib = (prev.lib or { }) // {
                repro = (prev.lib.repro or { }) // {
                  inherit version;
                };
              };

              inherit repro;

              # Note to the reader: these derivations run benchmarks
              # and collect the results in various formats. They're
              # part of the flake's overlay, so they appear in any
              # `pkgs` that uses this overlay. Hoewver, we do *not*
              # include these in the flake's `packages` output,
              # because we don't want them to be built/run when CI
              # evaluates the `hydraJobs` or `ciJobs` outputs.
              inherit (benchmarks) repro-benchmark-results-html;
              inherit (benchmarks) repro-benchmark-results-json;
              inherit (benchmarks) repro-benchmark-results-github-action-benchmark;
            }
          );

          nixosModules.default = {
            nixpkgs.overlays = allOverlays;
          };

          hydraJobs = {
            inherit (inputs.self) packages;
            inherit (inputs.self) checks;
            inherit (inputs.self) devShells;

            required-ci = pkgs.releaseTools.aggregate {
              name = "required-ci";
              constituents = builtins.map builtins.attrValues (with inputs.self.hydraJobs; [
                packages.x86_64-linux
                packages.aarch64-darwin
                checks.x86_64-linux
                checks.aarch64-darwin
              ]);
              meta.description = "Required CI builds";
            };
          };

          ciJobs = inputs.hacknix.lib.flakes.recurseIntoHydraJobs inputs.self.hydraJobs;
          ciBenchmarks = inputs.hacknix.lib.flakes.recurseIntoHydraJobs benchmarkJobs;
        };
    };
}
