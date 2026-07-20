{
  description = "straps.nvim — a self-extending coding agent inside Neovim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkStraps = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "straps.nvim";
        version = self.shortRev or self.dirtyShortRev or "dev";
        src = self;
        # Runtime helpers the builtin tools shell out to: curl (fn.provider),
        # ripgrep (tool.grep, with a vimgrep fallback when absent). Not
        # wrapped into the plugin — surface them via the nixvim module's
        # extraPackages or your own PATH.
        meta = {
          description = "Self-extending coding agent inside Neovim; every tool, hook and prompt layer is a live registry entry";
          license = nixpkgs.lib.licenses.mit;
        };
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        straps-nvim = mkStraps pkgs;
        default = straps-nvim;
      });

      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // { straps-nvim = mkStraps final; };
      };

      # Import into a nixvim configuration:
      #   imports = [ straps.nixvimModules.default ];
      #   plugins.straps.enable = true;
      #   plugins.straps.settings = { model = "claude-sonnet-5"; };
      nixvimModules = rec {
        straps = { lib, config, pkgs, ... }:
          let
            cfg = config.plugins.straps;
          in
          {
            options.plugins.straps = {
              enable = lib.mkEnableOption "straps.nvim, the self-extending coding agent";
              package = lib.mkOption {
                type = lib.types.package;
                default = mkStraps pkgs;
                defaultText = lib.literalExpression ''straps.packages.''${system}.default'';
                description = "The straps.nvim plugin package.";
              };
              settings = lib.mkOption {
                type = with lib.types; attrsOf anything;
                default = { };
                example = {
                  model = "claude-sonnet-5";
                  instructions_files = [ ".notes/conventions.md" ];
                  tools_expanded = true;
                };
                description = ''
                  Passed verbatim to require("straps").setup(). See the
                  config table in lua/straps/init.lua for every key.
                '';
              };
            };
            config = lib.mkIf cfg.enable {
              extraPlugins = [ cfg.package ];
              # curl: fn.provider's streaming HTTP; ripgrep: tool.grep's
              # fast path (it degrades to vimgrep without it).
              extraPackages = [ pkgs.curl pkgs.ripgrep ];
              extraConfigLua = ''
                require("straps").setup(${lib.generators.toLua { } cfg.settings})
              '';
            };
          };
        default = straps;
      };

      checks = forAllSystems (pkgs: {
        tests = pkgs.stdenvNoCC.mkDerivation {
          name = "straps-tests";
          src = self;
          nativeBuildInputs = [ pkgs.neovim pkgs.git pkgs.ripgrep pkgs.curl ];
          dontBuild = true;
          doCheck = true;
          checkPhase = ''
            export HOME=$TMPDIR
            export XDG_DATA_HOME=$TMPDIR/data XDG_STATE_HOME=$TMPDIR/state XDG_CACHE_HOME=$TMPDIR/cache
            for t in tests/run_*.lua; do
              echo "== $t"
              nvim --headless -l "$t"
            done
          '';
          installPhase = "touch $out";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.neovim pkgs.ripgrep pkgs.curl ];
        };
      });
    };
}
