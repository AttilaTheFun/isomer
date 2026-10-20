"""Parse skip-ui's README 'Supported SwiftUI' table into skip_supported.json:
[{"api": "<code text>", "level": "full|high|medium|low"}]. SkipUI is a
SwiftUI-on-Compose reimplementation; its table is a curated list of what apps
ask for."""
import html, json, os, re
t = open(os.path.expanduser("~/Developer/skiptools/skip-ui/README.md")).read()
start = t.index('## Supported SwiftUI'); end = t.index('## Supported UIKit')
sec = t[start:end]
levels = {'✅': 'full', '🟢': 'high', '🟡': 'medium', '🟠': 'low'}
out = []
for row in re.findall(r'<tr>(.*?)</tr>', sec, re.S):
    m = re.search(r'<td>\s*(✅|🟢|🟡|🟠)\s*</td>', row)
    c = re.search(r'<code>(.*?)</code>', row, re.S)
    if m and c:
        out.append({'api': html.unescape(c.group(1)).strip(), 'level': levels[m.group(1)]})
json.dump(out, open('/tmp/swiftui_audit/skip_supported.json', 'w'), indent=1)
print(len(out)); print([o['api'] for o in out][:400])
