# SwiftUI API audit

The scripts behind docs/swiftui_api_audit.md: they read SwiftUI's
`.swiftinterface` files from the installed Xcode, Isomer's sources (this
repo), and for comparison OpenSwiftUI and skip-ui checkouts beside it
(`~/Developer/OpenSwiftUI`, `~/Developer/skiptools/skip-ui`), and write their
data to /tmp/swiftui_audit and the report to /tmp/swiftui_api_audit.md.

    mkdir -p /tmp/swiftui_audit
    python3 extract_all.py   # the declarations: apple_api.json, isomer_api.json, ...
    python3 skip_readme.py   # skip-ui's supported list
    python3 usage.py         # how often apps here use each API
    python3 noops.py         # Isomer API that takes arguments and ignores them
    python3 compare.py       # results.json, gaps_full.tsv
    python3 report.py        # the report

Section 7 of the report describes the method.
