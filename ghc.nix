# Usage examples:
#
#   nix-shell path/to/ghc.nix/ --pure --run './boot && ./configure && make -j4'
#   nix-shell path/to/ghc.nix/        --run 'hadrian/build -c -j4 --flavour=quickest'
#   nix-shell path/to/ghc.nix/        --run 'THREADS=4 ./validate --slow'
#
let
  pkgsFor = nixpkgs: system: nixpkgs.legacyPackages.${system};
  hadrianPath =
    if builtins.hasAttr "getEnv" builtins
    then "${builtins.getEnv "PWD"}/hadrian/hadrian.cabal"
    else null;
in
{ system ? builtins.currentSystem
, nixpkgs
, all-cabal-hashes
, bootghc ? "ghc96"
, version ? "9.9"
, hadrianCabal ? hadrianPath
, useClang ? false  # use Clang for C compilation
, withLlvm ? false
, withDocs ? true
, withGhcid ? false
, withIde ? false
, withHadrianDeps ? false
, withDwarf ? (pkgsFor nixpkgs system).stdenv.isLinux  # enable libdw unwinding support
, withNuma ? (pkgsFor nixpkgs system).stdenv.isLinux
, withDtrace ? (pkgsFor nixpkgs system).stdenv.isLinux
, withGrind ? !((pkgsFor nixpkgs system).valgrind.meta.broken or false)
, withSystemLibffi ? false
, withEMSDK ? false                    # load emscripten for js-backend
, withWasiSDK ? false                  # load the toolchain for wasm backend
, withFindNoteDef ? true              # install a shell script `find_note_def`;
  # `find_note_def "Adding a language extension"`
  # will point to the definition of the Note "Adding a language extension"
, wasi-sdk
, wasmtime
}:

let
  overlay = self: super: {
    haskell = super.haskell // {
      packages = super.haskell.packages // {
        ${bootghc} = super.haskell.packages.${bootghc}.override (old: {
          inherit all-cabal-hashes;
          overrides =
            self.lib.composeExtensions
              (old.overrides or (_: _: { }))
              (_hself: hsuper: {
                ormolu =
                  if self.system == "aarch64-darwin"
                  then
                    self.haskell.lib.overrideCabal
                      hsuper.ormolu
                      (_: { enableSeparateBinOutput = false; })
                  else
                    hsuper.ormolu;
              });
        });
      };
    };
  };

  pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
in

with pkgs;

let
  llvmForGhc =
    if lib.versionAtLeast version "9.1"
    then llvm_10
    else llvm_9;

  stdenv =
    if useClang
    then pkgs.clangStdenv
    else pkgs.stdenv;
  noTest = haskell.lib.dontCheck;

  hspkgs = pkgs.haskell.packages.${bootghc};

  ourtexlive =
    pkgs.texlive.combine {
      inherit (pkgs.texlive)
        scheme-medium collection-xetex fncychap titlesec tabulary varwidth
        framed capt-of wrapfig needspace dejavu-otf helvetic upquote;
    };
  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  docsPackages = if withDocs then [ python3Packages.sphinx ourtexlive ] else [ ];

  depsSystem = with lib; (
    [
      autoconf
      automake
      m4
      less
      gmp.dev
      gmp.out
      glibcLocales
      ncurses.dev
      ncurses.out
      perl
      git
      file
      which
      python3
      xorg.lndir # for source distribution generation
      zlib.out
      zlib.dev
      hlint
    ]
    ++ docsPackages
    ++ optional withLlvm llvmForGhc
    ++ optional withGrind valgrind
    ++ optional withEMSDK emscripten
    ++ optionals withWasiSDK [ wasi-sdk wasmtime ]
    ++ optional withNuma numactl
    ++ optional withDwarf elfutils
    ++ optional withGhcid ghcid
    ++ optional withIde hspkgs.haskell-language-server
    ++ optional withIde clang-tools # N.B. clang-tools for clangd
    ++ optional withDtrace linuxPackages.systemtap
    ++ (if (! stdenv.isDarwin)
    then [ pxz ]
    else [
      libiconv
      darwin.libobjc
      darwin.apple_sdk.frameworks.Foundation
    ])
  );

  happy =
    if lib.versionAtLeast version "9.1"
    then noTest (hspkgs.callHackage "happy" "1.20.1.1" { })
    else noTest (haskell.packages.ghc865Binary.callHackage "happy" "1.19.12" { });

  alex =
    if lib.versionAtLeast version "9.1"
    then noTest (hspkgs.callHackage "alex" "3.2.6" { })
    else noTest (hspkgs.callHackage "alex" "3.2.5" { });

  # Convenient tools
  configureGhc = writeShellScriptBin "configure_ghc" "./configure $CONFIGURE_ARGS $@";
  validateGhc = writeShellScriptBin "validate_ghc" "config_args='$CONFIGURE_ARGS' ./validate $@";
  depsTools = [
    happy
    alex
    hspkgs.cabal-install
    configureGhc
    validateGhc
  ]
  ++ lib.optional withFindNoteDef findNoteDef
  ;

  hadrianCabalExists = !(builtins.isNull hadrianCabal) && builtins.pathExists hadrianCabal;
  hsdrv =
    if (withHadrianDeps &&
      builtins.trace "checking if ${toString hadrianCabal} is present:  ${if hadrianCabalExists then "yes" else "no"}"
        hadrianCabalExists)
    then hspkgs.callCabal2nix "hadrian" hadrianCabal { }
    else
      (hspkgs.mkDerivation {
        inherit version;
        pname = "ghc-buildenv";
        license = "BSD";
        src = builtins.filterSource (_: _: false) ./.;

        libraryHaskellDepends = with hspkgs; lib.optionals withHadrianDeps [
          extra
          QuickCheck
          shake
          unordered-containers
          cryptohash-sha256
          base16-bytestring
        ];
        librarySystemDepends = depsSystem;
      });

  findNoteDef = writeShellScriptBin "find_note_def" ''
    ret=$(${pkgs.ripgrep}/bin/rg  --no-messages --vimgrep -i --engine pcre2 "^ ?[{\\-#*]* *\QNote [$1]\E\s*$")
    n_defs=$(echo "$ret" | sed '/^$/d' | wc -l)
    while IFS= read -r line; do
      if [[ $line =~ ^([^:]+) ]] ; then
        file=''${BASH_REMATCH[1]}
        if [[ $line =~ hs:([0-9]+): ]] ; then
          pos=''${BASH_REMATCH[1]}
          if cat $file | head -n $(($pos+1)) | tail -n 1 | grep --quiet "~~~" ; then
            echo $file:$pos
          fi
        fi
      fi
    done <<< "$ret"
    if [[ $n_defs -ne 1 ]]; then
      exit 42
    fi
    exit 0
  '';
in
hspkgs.shellFor rec {
  packages = _pkgset: [ hsdrv ];
  nativeBuildInputs = depsTools;
  buildInputs = depsSystem;
  passthru.pkgs = pkgs;

  hardeningDisable = [ "fortify" ]; ## Effectuated by cc-wrapper
  # Without this, we see a whole bunch of warnings about LANG, LC_ALL and locales in general.
  # In particular, this makes many tests fail because those warnings show up in test outputs too...
  # The solution is from: https://github.com/NixOS/nix/issues/318#issuecomment-52986702
  LOCALE_ARCHIVE = if stdenv.isLinux then "${glibcLocales}/lib/locale/locale-archive" else "";
  CONFIGURE_ARGS = [
    "--with-gmp-includes=${gmp.dev}/include"
    "--with-gmp-libraries=${gmp}/lib"
    "--with-curses-includes=${ncurses.dev}/include"
    "--with-curses-libraries=${ncurses.out}/lib"
  ] ++ lib.optionals withNuma [
    "--with-libnuma-includes=${numactl}/include"
    "--with-libnuma-libraries=${numactl}/lib"
  ] ++ lib.optionals withDwarf [
    "--with-libdw-includes=${elfutils.dev}/include"
    "--with-libdw-libraries=${elfutils.out}/lib"
    "--enable-dwarf-unwind"
  ] ++ lib.optionals withSystemLibffi [
    "--with-system-libffi"
    "--with-ffi-includes=${libffi.dev}/include"
    "--with-ffi-libraries=${libffi.out}/lib"
  ];

  shellHook = ''
    # somehow, CC gets overridden so we set it again here.
    export CC=${stdenv.cc}/bin/cc
    export GHC=$NIX_GHC
    export GHCPKG=$NIX_GHCPKG
    export HAPPY=${happy}/bin/happy
    export ALEX=${alex}/bin/alex
    ${lib.optionalString withEMSDK "export EMSDK=${emscripten}"}
    ${lib.optionalString withEMSDK "export EMSDK_LLVM=${emscripten}/bin/emscripten-llvm"}
    ${ # prevents sub word sized atomic operations not available issues
       # see: https://gitlab.haskell.org/ghc/ghc/-/wikis/javascript-backend/building#configure-fails-with-sub-word-sized-atomic-operations-not-available
      lib.optionalString withEMSDK ''
      cp -Lr ${emscripten}/share/emscripten/cache .emscripten_cache
      chmod u+rwX -R .emscripten_cache
      export EM_CACHE=.emscripten_cache
    ''}
    ${lib.optionalString withLlvm "export LLC=${llvmForGhc}/bin/llc"}
    ${lib.optionalString withLlvm "export OPT=${llvmForGhc}/bin/opt"}

    # "nix-shell --pure" resets LANG to POSIX, this breaks "make TAGS".
    export LANG="en_US.UTF-8"
    export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${lib.makeLibraryPath depsSystem}"
    unset LD

    ${lib.optionalString withDocs "export FONTCONFIG_FILE=${fonts}"}

    # N.B. This overrides CC, CONFIGURE_ARGS, etc. to configure the cross-compiler.
    ${lib.optionalString withWasiSDK "addWasiSDKHook"}

    >&2 echo "Recommended ./configure arguments (found in \$CONFIGURE_ARGS:"
    >&2 echo "or use the configure_ghc command):"
    >&2 echo ""
    >&2 echo "  ${lib.concatStringsSep "\n  " CONFIGURE_ARGS}"
  '';
}
