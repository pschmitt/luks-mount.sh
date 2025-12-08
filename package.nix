{
  lib,
  stdenv,
  makeWrapper,
  yq-go,
}:

stdenv.mkDerivation {
  pname = "luks-mount";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp $src/luks-mount.sh $out/bin/luks-mount
    chmod +x $out/bin/luks-mount
    # Assuming you might need to wrap the script to include dependencies:
    wrapProgram $out/bin/luks-mount --prefix PATH : ${lib.makeBinPath [ yq-go ]}
  '';

  meta = with lib; {
    description = "Quick and dirty mount script for removable LUKS devices using a config file";
    homepage = "https://github.com/pschmitt/luks-mount.sh";
    license = licenses.gpl3Only;
    maintainers = with maintainers; [ pschmitt ];
    mainProgram = "luks-mount";
    platforms = platforms.all;
  };
}
