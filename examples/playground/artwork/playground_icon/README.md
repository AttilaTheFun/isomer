# Playground icon

`Playground.icon` is the Icon Composer document for the Playground: three
flush ribbons folding into a play triangle on a deep navy ground. The iOS
app compiles it through `app_icons`. `Playground-1024.png` is its 1024 px
export for the web sites' favicon and touch icon; regenerate it after an
edit with Icon Composer's own ictool (the one in Xcode's usr/bin rejects
these flags):

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
      Playground.icon --export-image --output-file Playground-1024.png \
      --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
