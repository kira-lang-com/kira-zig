---
name: apple-runner
description: "macOS/iOS platform runner rules for Kira: real runtime/UI/graphics path required, the kira-graphics dependency, and the basic-foundation-app screenshot-verified done bar. Read before touching a macOS/iOS runner or claiming Apple platform work is complete."
---

# Apple platform runners

macOS/iOS runners are real Kira runners. Host code may create AppKit/UIKit
shells, Metal-backed views/surfaces, display links, input forwarding, log
capture — never render placeholder Swift/AppKit/UIKit content and call it
Kira success.

Kira Graphics owns real frame submission. Repo: `../kira-graphics`; clone
`https://github.com/kira-lang-com/kira-graphics.git` if missing.

## Done bar for `basic-foundation-app`

Must run visibly through the real Kira runtime, UI Foundation, layout,
render-command, and Kira Graphics path on intended targets, including the iOS
Simulator target.

App launch, simulator install, or window open is NOT success. Success
requires Kira-owned runtime/UI/graphics evidence the app actually rendered —
capture, attach, and inspect a screenshot for obvious issues before claiming
done.
