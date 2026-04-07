{
  description = "elaztic - A Zig Elasticsearch client library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        zigpkgs = zig.packages.${system};

        zigStable = pkgs.zig;
        zigMaster = zigpkgs.master;

        # OpenSearch helpers
        # OpenSearch (Apache 2.0) is wire-compatible with ES 7.x and available
        # directly in nixpkgs. No Docker required. Used for all tests.
        esPort = "9200";
        esDataDir = ".opensearch-data";

        es-start = pkgs.writeShellScriptBin "es-start" ''
            set -euo pipefail
            if curl -sf http://localhost:${esPort}/_cluster/health > /dev/null 2>&1; then
              echo "OpenSearch is already running on port ${esPort}"
              exit 0
            fi

            DATA_DIR="$(pwd)/${esDataDir}"
            CONF_DIR="$DATA_DIR/config"
            mkdir -p "$DATA_DIR/data" "$DATA_DIR/logs"

            # Copy the entire default config directory from the Nix store.
            # This includes log4j2.properties, jvm.options, security configs, etc.
            # We use cp -rn so we don't clobber files from a previous run that
            # the user may have customised.
            cp -r ${pkgs.opensearch}/config/ "$CONF_DIR"
            chmod -R u+w "$CONF_DIR"

            # Overlay our local opensearch.yml on top of the default.
            cat > "$CONF_DIR/opensearch.yml" <<EOFCFG
          cluster.name: elaztic-dev
          discovery.type: single-node
          plugins.security.disabled: true
          http.port: ${esPort}
          path.data: $DATA_DIR/data
          path.logs: $DATA_DIR/logs
          EOFCFG

            # Patch jvm.options: replace relative log paths with absolute paths
            # pointing into our local data directory (Nix store is read-only).
            sed -i.bak \
              -e "s|file=logs/|file=$DATA_DIR/logs/|g" \
              -e "s|-Xloggc:logs/|-Xloggc:$DATA_DIR/logs/|g" \
              -e "s|ErrorFile=logs/|ErrorFile=$DATA_DIR/logs/|g" \
              "$CONF_DIR/jvm.options"
            rm -f "$CONF_DIR/jvm.options.bak"

            # Point OpenSearch at our local config dir (not OPENSEARCH_HOME)
            export OPENSEARCH_PATH_CONF="$CONF_DIR"
            export OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m"

            echo "Starting OpenSearch on port ${esPort}..."
            ${pkgs.opensearch}/bin/opensearch > .opensearch.log 2>&1 &
            echo $! > .opensearch.pid

            echo -n "Waiting for OpenSearch to be ready"
            for i in $(seq 1 40); do
              if curl -sf http://localhost:${esPort}/_cluster/health > /dev/null 2>&1; then
                echo ""
                echo "OpenSearch ready at http://localhost:${esPort}"
                echo "Set ES_URL=http://localhost:${esPort} to run tests"
                exit 0
              fi
              echo -n "."
              sleep 2
            done
            echo ""
            echo "OpenSearch did not start in time. Check .opensearch.log"
            exit 1
        '';

        es-stop = pkgs.writeShellScriptBin "es-stop" ''
          set -euo pipefail
          if [ -f .opensearch.pid ]; then
            PID=$(cat .opensearch.pid)
            if kill "$PID" 2>/dev/null; then
              echo "Stopped OpenSearch (pid $PID)"
            else
              echo "Process $PID was not running"
            fi
            rm -f .opensearch.pid
          else
            pkill -f opensearch 2>/dev/null && echo "Stopped OpenSearch" \
              || echo "OpenSearch was not running"
          fi
        '';

        es-status = pkgs.writeShellScriptBin "es-status" ''
          if curl -sf http://localhost:${esPort}/_cluster/health 2>/dev/null; then
            echo ""
          else
            echo "OpenSearch is not running on port ${esPort}"
            exit 1
          fi
        '';

        es-logs = pkgs.writeShellScriptBin "es-logs" ''
          tail -f .opensearch.log
        '';

        # All helper scripts bundled
        testHelpers = [
          es-start
          es-stop
          es-status
          es-logs
        ];

        # Common build inputs
        buildInputs = [];

        nativeBuildInputs = with pkgs;
          [pkg-config]
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            gdb
            valgrind
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [lldb];

        # Library derivation — runs unit tests and installs source as a Zig package
        elaztic = zigCompiler:
          pkgs.stdenv.mkDerivation {
            pname = "elaztic";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [zigCompiler] ++ nativeBuildInputs;
            inherit buildInputs;
            buildPhase = ''
              export HOME=$TMPDIR
              zig build test \
                --cache-dir /tmp/zig-cache \
                --global-cache-dir /tmp/zig-global-cache
            '';
            installPhase = ''
              mkdir -p $out/lib/zig
              cp -r src $out/lib/zig/elaztic
              cp build.zig build.zig.zon $out/lib/zig/
              cp LICENSE $out/lib/zig/ 2>/dev/null || true
              cp README.md $out/lib/zig/ 2>/dev/null || true
            '';
            meta = with pkgs.lib; {
              description = "elaztic - Production-grade Elasticsearch client library for Zig";
              license = licenses.agpl3Only;
              platforms = platforms.all;
            };
          };
      in {
        # Dev shells
        devShells = {
          default = pkgs.mkShell {
            buildInputs =
              [
                zigStable
                pkgs.opensearch
                pkgs.jdk21
              ]
              ++ buildInputs
              ++ testHelpers;
            nativeBuildInputs =
              nativeBuildInputs
              ++ (with pkgs; [
                git
                just
                zls
                curl
              ]);

            shellHook = ''
              echo "elaztic dev environment"
              echo "Zig: $(zig version)"
              echo ""
              echo "-- Build ------------------------------------------"
              echo "  zig build              build (debug)"
              echo "  nix build              reproducible build"
              echo ""
              echo "-- ES (OpenSearch on :9200) ------------------------"
              echo "  es-start               start OpenSearch on :9200"
              echo "  es-stop                stop OpenSearch"
              echo "  es-status              check OpenSearch health"
              echo "  es-logs                tail OpenSearch logs"
              echo ""
              echo "-- Tests -------------------------------------------"
              echo "  zig build test         unit tests"
              echo "  zig build test-smoke   smoke tests (requires ES_URL)"
              echo ""
              echo "-- Shortcuts ---------------------------------------"
              echo "  just fmt               zig fmt"
              echo "  just clean             rm build artifacts"
              echo "----------------------------------------------------"
              echo ""
            '';
          };

          nightly = pkgs.mkShell {
            buildInputs =
              [
                zigMaster
                pkgs.opensearch
                pkgs.jdk21
              ]
              ++ buildInputs
              ++ testHelpers;
            nativeBuildInputs =
              nativeBuildInputs
              ++ (with pkgs; [
                git
                zls
                curl
                just
              ]);

            shellHook = ''
              echo "elaztic nightly dev environment"
              echo "Zig: $(zig version)"
              echo "Nightly Zig -- expect potential instability"
              echo ""
            '';
          };

          ci = pkgs.mkShell {
            buildInputs =
              [
                zigStable
                pkgs.opensearch
                pkgs.jdk21
              ]
              ++ testHelpers;
            nativeBuildInputs = with pkgs; [
              git
              curl
            ];
          };
        };

        # Packages
        packages = {
          default = elaztic zigStable;
          nightly = elaztic zigMaster;
          elaztic = elaztic zigStable;
          elaztic-nightly = elaztic zigMaster;
        };

        formatter = pkgs.alejandra;

        checks = {
          build = self.packages.${system}.default;
          format = pkgs.runCommand "format-check" {nativeBuildInputs = [pkgs.alejandra];} ''
            alejandra --check ${./.}
            touch $out
          '';
        };
      }
    )
    // {
      overlays.default = final: prev: {
        elaztic = self.packages.${prev.system}.default;
      };

      templates = {
        default = {
          path = ./.;
          description = "Zig Elasticsearch client with Nix flake dev env";
        };
      };
    };
}
