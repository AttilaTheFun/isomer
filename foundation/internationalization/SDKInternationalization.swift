// Compiled when a build asks for `--@isomer//foundation:internationalization`
// on Android or the web (BUILD.bazel): there Foundation is the Swift SDK's,
// and only Isomer's -i18n SDK has FoundationInternationalization in it.
#if !canImport(IsomerFoundationInternationalization)
#error("--@isomer//foundation:internationalization: this platform's Swift SDK has no FoundationInternationalization. Register Isomer's -i18n SDK for it (swift-6.4.2-RELEASE_<platform>-i18n.artifactbundle.tar.gz; isomer's README, \"Upgrading isomer\").")
#endif
