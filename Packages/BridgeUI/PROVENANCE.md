# Provenance

Tier-2 code copied from EK Bridge (`bereciartua/ek-bridge`) under [ADR-0013](../../spec/architecture/decisions/0013-shared-bridgekit-core.md), to be extracted as `BridgeKitUI` after Funes v0.1. Diff each file against EK Bridge before every Funes release.

- `Upstream/` holds the files exactly as they were at the source commit. They aren't compiled.
- `Sources/BridgeUI/` holds the adapted versions the app uses. Adapting a file moves it from "—" to a path below.

| EK Bridge file | Source commit | BridgeUI |
|---|---|---|
| `Sources/ApprovalCenter.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/ApprovalQueue.swift (adapted: generic PanelItem, "1 of 3", countdown, exactly-once, asides) |
| `Sources/ApprovalPanel.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/ApprovalPanel.swift (adapted: checkbox rows with badges, facts, countdown, Share N, an aside line with a link) |
| `Sources/ActivityStore.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/ActivityStore.swift (adapted: generic row type, retention as a parameter) |
| `Sources/AccessRequests.swift` | `9c726f2` (v0.11.1) | — (Phase 3: Funes's access requests) |
| `Sources/ActivityView.swift` | `9c726f2` (v0.11.1) | — (Funes's Activity screen follows its layout in Apps/FunesMac/Activity) |
| `Sources/AgentDetection.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/AgentDetection.swift (adapted: `SetupAgent`, public probe; ConnectionAgentKinds dropped) |
| `Sources/AgentSetup.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/AgentSetup.swift (adapted: `SetupAgent`, the app's names in `SetupNames`, local agents only; Codex one-click; goldens in Tests/BridgeUITests/fixtures/agent-setup) |
| `Sources/ConnectAgentView.swift` | `9c726f2` (v0.11.1) | — (Funes's Connect tab is written fresh in Apps/FunesMac/Agents) |
| `Sources/OneClickSetup.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/OneClickSetup.swift (adapted: backup tag and app name as parameters; agents' commands run with HOME set to the configured home) |
| `Sources/Updates.swift` | `9c726f2` (v0.11.1) | — (Phase 4: updates) |
| `Sources/SparkleUpdater.swift` | `9c726f2` (v0.11.1) | — (Phase 4: Sparkle wrapper) |
| `Sources/AppMover.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/AppMover.swift (adapted: the app's names as `AppMover.Identity`, no live-test isolation) |
| `Sources/InstallLocation.swift` | `9c726f2` (v0.11.1) | Sources/BridgeUI/InstallLocation.swift (public, otherwise unchanged) |
| `Sources/Notifications.swift` | `9c726f2` (v0.11.1) | — (Phase 3) |
| `Sources/UIComponents.swift` | `9c726f2` (v0.11.1) | — (Phase 3) |
| `Sources/StatusMenuController.swift` | `9c726f2` (v0.11.1) | — (Funes's menu is written fresh in Apps/FunesMac/MenuBar) |
| `Sources/MainWindowController.swift` | `9c726f2` (v0.11.1) | — (Funes's windows are written fresh in Apps/FunesMac/Window) |
| `Sources/RemoteAccessView.swift` | `e753b22` (v0.11.2 + BridgeKit 0.1.1) | Apps/FunesMac/RemoteAccess/RemoteAccessPage.swift (the page, guide and rows), CloudTab.swift (the agent's Cloud section, from `CloudSection`), SignInPanel.swift (from `PairingSheet`, as a floating panel), RemoteComponents.swift; built on the app's own components |
| `Sources/TunnelSwitchView.swift` | `e753b22` | Apps/FunesMac/RemoteAccess/TunnelSwitchView.swift |
| `Sources/BridgeAppModel.swift` (its Remote Access part; not copied, read at `e753b22`) | `e753b22` | Sources/BridgeUI/RemoteAccessController.swift (generic: settings, guide, tunnel checks, Test, Switch Tunnel…, automatic turn-off, keep awake; the app's side through `RemoteAccessHost`) |
| `Sources/TunnelHealth.swift`, `Sources/TunnelSwitch.swift`, `Sources/RemoteAccessSupport.swift` | `e753b22` | Their logic moved to BridgeKitRemote; Sources/BridgeUI/RemoteWords.swift words its typed results (health, switch steps, probe failures) |
| `Sources/AgentSetup.swift` (the cloud setups and tunnel commands) | `9c726f2` (unchanged at `e753b22`) | Sources/BridgeUI/CloudSetup.swift and RemoteWords.swift (Funes's words, port 47627; goldens `cloud-*.txt`, `tunnel-*.txt`) |
| — (written for Funes; EK Bridge has the same setting) | — | Sources/BridgeUI/AppAppearance.swift (Settings ▸ General ▸ Appearance: Automatic, Light, Dark) |
| — (written for Funes, ADR-0029) | — | Sources/BridgeUI/MenuBarPanel.swift (the menu bar panel's Waiting for you cards and its Agents and Remote Access tiles) and PanelField.swift (its field: remember, search, ask, Esc's steps); generic, with no Funes types |

Full source commits: `9c726f2c903a190d5303c28c1c6e7464544905fa` (tier 2) and `e753b221a6646e6420eb2fe382780bea88493841` (the Remote Access views, Phase 4b). The cloud agent setups and tunnel commands are in `Upstream/AgentSetup.swift` (9c726f2; unchanged at e753b22 apart from code that moved to BridgeKit).
