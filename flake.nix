{
  description = "straps.nvim — a self-extending coding agent inside Neovim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The transcript-format grammar (tree-sitter-straps/). generate = false:
      # the committed src/parser.c is authoritative, so the build needs only a
      # C compiler, not a tree-sitter CLI whose output could drift by version.
      mkGrammar = pkgs: pkgs.tree-sitter.buildGrammar {
        language = "straps";
        version = self.shortRev or self.dirtyShortRev or "dev";
        src = "${self}/tree-sitter-straps";
        generate = false;
      };

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
        # Ship the compiled grammars on the plugin's own rtp: with the straps
        # parser present, ftplugin/straps.lua starts treesitter highlighting
        # (injected markdown/JSON) instead of the legacy syntax file. json
        # rides along because Neovim does not bundle it and the tool-body
        # injection silently renders plain without it; a json parser earlier
        # on the user's rtp (user site dir, nvim-treesitter) still wins.
        postInstall = ''
          install -Dm755 ${mkGrammar pkgs}/parser $out/parser/straps.so
          install -Dm755 ${pkgs.tree-sitter-grammars.tree-sitter-json}/parser $out/parser/json.so
        '';
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        straps-nvim = mkStraps pkgs;
        tree-sitter-straps = mkGrammar pkgs;
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
          # busted + nlua: `busted --lua nlua` (via .busted) runs each spec
          # inside a headless Neovim, so the specs see vim.* like the plugin does.
          # procps: agent_ux_spec's process-tree kill cases poll pgrep/pkill.
          nativeBuildInputs = [
            pkgs.neovim pkgs.git pkgs.ripgrep pkgs.curl pkgs.procps
            pkgs.luajitPackages.busted pkgs.luajitPackages.nlua
          ];
          dontBuild = true;
          doCheck = true;
          checkPhase = ''
            export HOME=$TMPDIR
            export XDG_DATA_HOME=$TMPDIR/data XDG_STATE_HOME=$TMPDIR/state XDG_CACHE_HOME=$TMPDIR/cache
            # stdenvNoCC has no C compiler, so treesitter_spec.lua's local
            # compile fallback cannot run here — without this parser it would
            # silently SKIP and the grammar would go untested in CI. The json
            # parser is not bundled with Neovim (markdown is); provide it so
            # the tool-body injection assertions run instead of skipping.
            install -Dm755 ${mkGrammar pkgs}/parser parser/straps.so
            install -Dm755 ${pkgs.tree-sitter-grammars.tree-sitter-json}/parser parser/json.so
            # Both parsers were just installed above, so treesitter_spec.lua's
            # soft skip-on-missing-parser paths must be hard failures here —
            # a broken install must not leave the grammar untested with CI
            # green. The test enforces that itself when this is set.
            export STRAPS_TS_REQUIRED=1
            # One busted process (one headless Neovim) per spec: the specs
            # assume a fresh editor — buffers, autocmds, PATH, the registry
            # singleton — and would leak state into each other otherwise.
            fail=0
            for t in tests/*_spec.lua; do
              echo "== $t"
              busted "$t" || fail=1
            done
            [ "$fail" = 0 ]
          '';
          installPhase = "touch $out";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim pkgs.ripgrep pkgs.curl
            pkgs.luajitPackages.busted pkgs.luajitPackages.nlua
          ];
        };
      });
    };
}
