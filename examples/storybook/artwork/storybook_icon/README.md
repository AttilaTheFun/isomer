# Storybook icon

`Storybook.icon` is the Icon Composer document for the Storybook: an open
book on a deep indigo ground, code on its left page and the controls it
makes on its right, in the Playground's orange, blue and purple. The iOS
and Mac apps compile it through `app_icons`. `Storybook-1024.png` is its
1024 px export for the web site's favicon and touch icon, and
`ic_launcher.png` that at 192 px for Android; regenerate them after an edit
with Icon Composer's own ictool (the one in Xcode's usr/bin rejects these
flags):

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
      Storybook.icon --export-image --output-file Storybook-1024.png \
      --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
    sips -z 192 192 Storybook-1024.png --out ic_launcher.png
