{
  description = "elaztic - A Zig Elasticsearch client library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zigpkgs = zig.packages.${system};

        zigStable = pkgs.zig;
        zigMaster = zigpkgs.master;

        # ── ZincSearch helpers ──────────────────────────────────────────────
        # ZincSearch runs on port 4080 (not 9200). It is used for smoke tests
        # only (M1–M2). Do NOT use it to validate query DSL correctness.
        zincDataDir = ".zinc-data";
        zincPort = "4080";
        zincUser = "admin";
        zincPass = "Complexpass#123";

        zinc-start = pkgs.writeShellScriptBin "zinc-start" ''
          set -euo pipefail
          if pgrep -f "zinc server" > /dev/null 2>&1; then
            echo "ZincSearch is already running on port ${zincPort}"
            exit 0
          fi
          mkdir -p ${zincDataDir}
          echo "Starting ZincSearch on port ${zincPort}..."
          ZINC_FIRST_ADMIN_USER=${zincUser} \
          ZINC_FIRST_ADMIN_PASSWORD="${zincPass}" \
          ZINC_DATA_PATH=${zincDataDir} \
          ZINC_SERVER_PORT=${zincPort} \
            ${pkgs.zincsearch}/bin/zincsearch server &> .zinc.log &
          echo $! > .zinc.pid
          # Wait for it to be ready
          for i in $(seq 1 20); do
            if curl -sf -u "${zincUser}:${zincPass}" \
                http://localhost:${zincPort}/healthz > /dev/null 2>&1; then
              echo "ZincSearch ready at http://localhost:${zincPort}"
              echo "Credentials: ${zincUser} / ${zincPass}"
              echo "UI:          http://localhost:${zincPort}"
              exit 0
            fi
            sleep 0.5
          done
          echo "ZincSearch did not start in time. Check .zinc.log"
          exit 1
        '';

        zinc-stop = pkgs.writeShellScriptBin "zinc-stop" ''
          set -euo pipefail
          if [ -f .zinc.pid ]; then
            PID=$(cat .zinc.pid)
            if kill "$PID" 2>/dev/null; then
              echo "Stopped ZincSearch (pid $PID)"
            else
              echo "Process $PID was not running"
            fi
            rm -f .zinc.pid
          else
            pkill -f "zinc server" 2>/dev/null && echo "Stopped ZincSearch" \
              || echo "ZincSearch was not running"
          fi
        '';

        zinc-status = pkgs.writeShellScriptBin "zinc-status" ''
          if curl -sf -u "${zincUser}:${zincPass}" \
              http://localhost:${zincPort}/healthz > /dev/null 2>&1; then
            echo "ZincSearch is running on port ${zincPort}"
            curl -s -u "${zincUser}:${zincPass}" \
              http://localhost:${zincPort}/healthz
          else
            echo "ZincSearch is not running"
            exit 1
          fi
        '';

        # ── Elasticsearch Docker helpers ────────────────────────────────────
        # Real ES 8.x is required for M3+ (Query DSL, Scroll, PIT, etc.).
        # Requires Docker to be installed on the host (not managed by Nix).
        esPort = "9200";
        esImage = "docker.elastic.co/elasticsearch/elasticsearch:8.13.0";
        esContainer = "elaztic-es";

        es-start = pkgs.writeShellScriptBin "es-start" ''
          set -euo pipefail
          if ! command -v docker &> /dev/null; then
            echo "Docker is required for ES integration tests. Install Docker first."
            exit 1
          fi
          if docker ps --format '{{.Names}}' | grep -q "^${esContainer}$"; then
            echo "Elasticsearch is already running on port ${esPort}"
            exit 0
          fi
          # Remove stopped container if it exists
          docker rm -f ${esContainer} 2>/dev/null || true
          echo "Starting Elasticsearch 8.x on port ${esPort}..."
          docker run -d \
            --name ${esContainer} \
            -p ${esPort}:9200 \
            -e "discovery.type=single-node" \
            -e "xpack.security.enabled=false" \
            -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
            --health-cmd "curl -sf http://localhost:9200/_cluster/health | grep -v '\"status\":\"red\"'" \
            --health-interval 5s \
            --health-timeout 3s \
            --health-retries 20 \
            ${esImage} > /dev/null
          echo -n "Waiting for Elasticsearch to be ready"
          for i in $(seq 1 40); do
            if curl -sf http://localhost:${esPort}/_cluster/health > /dev/null 2>&1; then
              echo ""
              echo "Elasticsearch ready at http://localhost:${esPort}"
              echo "Set ES_URL=http://localhost:${esPort} to run integration tests"
              exit 0
            fi
            echo -n "."
            sleep 2
          done
          echo ""
          echo "Elasticsearch did not become healthy. Check: docker logs ${esContainer}"
          exit 1
        '';

        es-stop = pkgs.writeShellScriptBin "es-stop" ''
          set -euo pipefail
          if docker ps --format '{{.Names}}' | grep -q "^${esContainer}$"; then
            docker stop ${esContainer} > /dev/null
            docker rm ${esContainer} > /dev/null
            echo "Stopped and removed Elasticsearch container"
          else
            echo "Elasticsearch container is not running"
          fi
        '';

        es-logs = pkgs.writeShellScriptBin "es-logs" ''
          docker logs -f ${esContainer}
        '';

        es-status = pkgs.writeShellScriptBin "es-status" ''
          if curl -sf http://localhost:${esPort}/_cluster/health 2>/dev/null; then
            echo ""
          else
            echo "Elasticsearch is not running on port ${esPort}"
            exit 1
          fi
        '';

        # ── All helper scripts bundled ──────────────────────────────────────
        testHelpers = [
          zinc-start
          zinc-stop
          zinc-status
          es-start
          es-stop
          es-logs
          es-status
        ];

        # ── Common build inputs ─────────────────────────────────────────────
        buildInputs = [ ];

        nativeBuildInputs =
          with pkgs;
          [ pkg-config ]
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            gdb
            valgrind
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ lldb ];

        # ── Library derivation ──────────────────────────────────────────────
        elaztic =
          zigCompiler:
          pkgs.stdenv.mkDerivation {
            pname = "elaztic";
            version = "0.0.0";
            src = ./.;
            nativeBuildInputs = [ zigCompiler ] ++ nativeBuildInputs;
            inherit buildInputs;
            buildPhase = ''
              export HOME=$TMPDIR
              zig build --cache-dir /tmp/zig-cache \
                        --global-cache-dir /tmp/zig-global-cache \
                        -Doptimize=ReleaseSafe
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/elaztic $out/bin/
            '';
            meta = with pkgs.lib; {
              description = "elaztic - Zig Elasticsearch client";
              license = licenses.mit;
              platforms = platforms.all;
            };
          };

      in
      {
        # ── Dev shells ────────────────────────────────────────────────────
        devShells = {
          default = pkgs.mkShell {
            buildInputs = [
              zigStable
              pkgs.zincsearch
            ]
            ++ buildInputs
            ++ testHelpers;
            nativeBuildInputs =
              nativeBuildInputs
              ++ (with pkgs; [
                git
                just
                zls
                curl # used by health check scripts
              ]);

            shellHook = ''
              echo "⚡ elaztic dev environment"
              echo "Zig:  $(zig version)"
              echo "Zinc: $(zinc --version 2>/dev/null | head -1 || echo 'available')"
              echo ""
              echo "── Build ──────────────────────────────────"
              echo "  zig build              build (debug)"
              echo "  zig build test         unit tests"
              echo "  nix build              reproducible build"
              echo ""
              echo "── Smoke tests (ZincSearch, M1-M2) ────────"
              echo "  zinc-start             start ZincSearch on :4080"
              echo "  zinc-stop              stop ZincSearch"
              echo "  zinc-status            check ZincSearch health"
              echo "  zig build test-smoke   run smoke tests"
              echo ""
              echo "── Integration tests (real ES, M3+) ────────"
              echo "  es-start               docker run ES 8.x on :9200"
              echo "  es-stop                stop ES container"
              echo "  es-logs                tail ES logs"
              echo "  zig build test-integration  run integration tests"
              echo ""
              echo "── Shortcuts ───────────────────────────────"
              echo "  just fmt               zig fmt"
              echo "  just clean             rm build artifacts"
              echo "────────────────────────────────────────────"
              echo ""
              echo "⚠️  ZincSearch is for smoke tests only (M1-M2)."
              echo "    Use es-start for M3+ query DSL / integration tests."
              echo ""
            '';
          };

          nightly = pkgs.mkShell {
            buildInputs = [
              zigMaster
              pkgs.zincsearch
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
              echo "🌙 elaztic nightly dev environment"
              echo "Zig: $(zig version)"
              echo "⚠️  Nightly Zig — expect potential instability"
              echo ""
            '';
          };

          ci = pkgs.mkShell {
            buildInputs = [ zigStable ] ++ testHelpers;
            nativeBuildInputs = with pkgs; [
              git
              curl
            ];
          };
        };

        # ── Packages ──────────────────────────────────────────────────────
        packages = {
          default = elaztic zigStable;
          nightly = elaztic zigMaster;
          elaztic = elaztic zigStable;
          elaztic-nightly = elaztic zigMaster;
        };

        # ── Apps ──────────────────────────────────────────────────────────
        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/elaztic";
          };
          elaztic = {
            type = "app";
            program = "${self.packages.${system}.elaztic}/bin/elaztic";
          };
          nightly = {
            type = "app";
            program = "${self.packages.${system}.nightly}/bin/elaztic";
          };
        };

        formatter = pkgs.alejandra;

        checks = {
          build = self.packages.${system}.default;
          format = pkgs.runCommand "format-check" { nativeBuildInputs = [ pkgs.alejandra ]; } ''
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
