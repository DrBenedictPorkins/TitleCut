# TitleCut

Native macOS app: timed styled titles, still frames and zooms on a video, exported to MP4. Includes an MCP bridge for Claude Code.

- The full plan is in `PLAN.qmd`. Read it before writing any code.
- Build milestones in order (§12). Stop after each one so the user can QA it.
- The open decisions in §13 are the user's to make. Ask before building anything that depends on one.
- `project.yml` (XcodeGen) is the source of truth. Regenerate the Xcode project with `xcodegen generate`. Never hand-edit the `.xcodeproj`.
- The user runs all git commands.
