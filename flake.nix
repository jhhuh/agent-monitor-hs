{
  description = "TUI dashboard for Claude Code subagent hierarchy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        haskellPackages = pkgs.haskellPackages;
        agent-monitor-hs = haskellPackages.callCabal2nix "agent-monitor-hs" ./. { };
      in
      {
        packages.default = agent-monitor-hs;
        packages.agent-monitor-hs = agent-monitor-hs;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            haskellPackages.ghc
            haskellPackages.cabal-install
            pkg-config
            zlib
          ];
        };
      }
    );
}
