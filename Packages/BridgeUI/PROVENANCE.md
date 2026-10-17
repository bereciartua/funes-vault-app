# Provenance

Tier-2 code copied from EK Bridge (`bereciartua/ek-bridge`) under [ADR-0013](../../spec/architecture/decisions/0013-shared-bridgekit-core.md), to be extracted as `BridgeKitUI` after Funes v0.1. Diff each file against EK Bridge before every Funes release.

- `Upstream/` holds the files exactly as they were at the source commit. They aren't compiled.
- `Sources/BridgeUI/` holds the adapted versions the app uses. Adapting a file moves it from "—" to a path below.

| EK Bridge file | Source commit | BridgeUI |
|---|---|---|
| `Sources/ApprovalCenter.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/ApprovalQueue.swift (adapted: generic PanelItem, "1 of 3", countdown, exactly-once) |
| `Sources/ApprovalPanel.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/ApprovalPanel.swift (adapted: checkbox rows with badges, facts, countdown, Share N) |
| `Sources/ActivityStore.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/ActivityStore.swift (adapted: generic row type, retention as a parameter) |
| `Sources/AccessRequests.swift` | `9c726f2` (v0.11.1) | — (Phase 3: Funes's access requests) |
| `Sources/ActivityView.swift` | `9c726f2` (v0.11.1) | — (Phase 3: Activity screen) |
| `Sources/AgentDetection.swift` | `9c726f2` (v0.11.1) | — (Phase 3: Add-agent sheet) |
| `Sources/AgentSetup.swift` | `9c726f2` (v0.11.1) | — (Phase 3: agent setup snippets; SetupJSON/SetupTOML are in BridgeKitCore) |
| `Sources/ConnectAgentView.swift` | `9c726f2` (v0.11.1) | — (Phase 3) |
| `Sources/OneClickSetup.swift` | `9c726f2` (v0.11.1) | — (Phase 3; uses BridgeKitCore's AgentConfigWriter) |
| `Sources/Updates.swift` | `9c726f2` (v0.11.1) | — (Phase 4: updates) |
| `Sources/SparkleUpdater.swift` | `9c726f2` (v0.11.1) | — (Phase 4: Sparkle wrapper) |
| `Sources/AppMover.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/AppMover.swift (adapted: the app's names as `AppMover.Identity`, no live-test isolation) |
| `Sources/InstallLocation.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/InstallLocation.swift (public, otherwise unchanged) |
| `Sources/Notifications.swift` | `9c726f2` (v0.11.1) | — (Phase 3) |
| `Sources/UIComponents.swift` | `9c726f2` (v0.11.1) | — (Phase 3) |
| `Sources/StatusMenuController.swift` | `9c726f2` (v0.11.1) | — (Funes's menu is written fresh in Apps/FunesMac/MenuBar) |
| `Sources/MainWindowController.swift` | `9c726f2` (v0.11.1) | — (Funes's windows are written fresh in Apps/FunesMac/Window) |

Full source commit: `9c726f2c903a190d5303c28c1c6e7464544905fa`.
