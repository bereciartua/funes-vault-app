# Privacy

**Funes Vault v0.1 (public preview), and Funes Vault for iPhone (v0.2, in testing) · Last updated 22 October 2026**

Funes Vault keeps your memories on your Mac. It has no accounts, no servers of its own, no analytics and no telemetry. This page lists everything that can leave your Mac, and when, and what the iPhone companion keeps and sends ([below](#funes-vault-for-iphone)). Questions: [open an issue](https://github.com/bereciartua/funes-vault-app/issues).

## In short

| What | Where it goes | When |
|---|---|---|
| Memory text you allow an agent to have | The AI agent on your Mac that asked, and from there that agent's own AI provider | Only when its access allows it, or you approve the request |
| Memory text you allow a cloud agent to have | That cloud agent's vendor (for example Anthropic for claude.ai, OpenAI for ChatGPT), through the tunnel you run | Only with **Remote Access** on (off by default), for an agent you allowed cloud access, under the same access and approvals |
| A request to a cloud app's metadata address | That cloud app (for example claude.ai or ChatGPT) | Only while you have pairing open, when that app signs in. No credential or memory is sent |
| One request to your tunnel's address | Your tunnel, and back to Funes Vault | When you save your tunnel's address, and when you click **Test** or **Try Again** on the Remote Access page |
| An update check: the app's name and version | GitHub (the Funes Vault releases) | Once a day, if **Check for updates every day** is on, and when you click **Check Now** or **Check for Updates…** |
| Capture text (from your Mac or your iPhone), with your category names and descriptions | An AI provider you added and chose for Classification | Only if you add one and choose it, never above your cloud limit, never when it looks like a secret, and at most your daily number of cloud requests |
| Captures, searches, edits, Inbox and approval answers from your iPhone, and the Mac's replies | Between your iPhone and your own Mac only, end-to-end encrypted, over your Wi-Fi, Tailscale or your tunnel | Only with **iPhone access** on (off by default), with an iPhone you paired |
| A "doorbell" record holding only a random tag | Your own private iCloud database (CloudKit), whose push wakes your iPhone | When an agent's request waits for you, if a paired iPhone has approvals on. Deleted once the request is answered or over |
| Anything else | Nowhere | No analytics, no crash reporting, no accounts |

## Your vault stays on your Mac

- Your memories, the Inbox, your agents and their keys, Activity and settings are stored in `~/Library/Application Support/FunesVault/` (folder mode 0700, files 0600) and the app's preferences. They aren't uploaded anywhere. There's no Funes Vault cloud, sync service or account.
- Search runs on your Mac. Memories, your searches and agents' requests are matched with a small embedding model built into the app (bge-small-en-v1.5, run with Core ML on the CPU), plus keyword search. Nothing is downloaded or sent for this.
- Funes Vault doesn't add its own database encryption. Your data at rest is protected by macOS and FileVault, like your other files. Other programs running as you can read it, as they can read most apps' data.
- The app's logs (macOS unified logging) hold ids, labels and error codes, never memory text, task text or keys. They stay on your Mac unless you share them yourself, for example in a system diagnostic report.
- Notifications are shown by macOS on your Mac. The optional ones are off until you turn them on in **Settings ▸ General**, and none includes memory or task text: they name agents and counts.
- Exports are files you save where you choose. They never contain agent keys, provider API keys or access settings.

## What AI agents receive

Agents connect to Funes Vault's MCP server, which listens only on `127.0.0.1` (port 47625 unless you change it), the loopback address of your Mac. Nothing on your network or the internet can reach it. Requests that arrive through a tunnel or a proxy, or from a web page, are refused. Cloud agents use a separate port, only if you turn on Remote Access ([below](#cloud-agents-remote-access-experimental)). Agents that talk to MCP servers over stdio run `funes-mcp`, a small launcher inside the app that relays to the same local server.

- **Each agent has its own key** and gets only what its access allows: a sensitivity ceiling, allowed and denied categories, read, suggest and save permissions, and an expiry date.
- **When an agent asks for context,** Funes Vault finds the relevant memories and keeps only those the agent may have. If you asked to approve its requests, you see the exact text first and decide. Nothing is sent before you approve. An agent that's refused learns how many memories were withheld and why, never which ones.
- **What you release goes to the agent and leaves Funes Vault's control.** The agent sends it to its own AI provider (for example Anthropic, OpenAI or Google) under that provider's terms. Funes Vault can't recall it later. Removing an agent or pausing it stops future access immediately.
- **Suggestions** an agent makes wait in your Inbox until you review them, unless you let that agent save without asking. Rejected ones leave only an id in Activity.
- **Activity** records which agent asked, when, what was decided and what was released (as ids and labels), on your Mac only.

## Cloud agents (Remote Access, experimental)

Remote Access is **off by default**. While you have it on, a second listener on `127.0.0.1` (port 47627 unless you change it) answers requests that a tunnel you run (Tailscale Funnel, Cloudflare Tunnel, ngrok or another) forwards from a public address. Funes Vault never starts, stops or changes a tunnel. While Remote Access is on, it asks the tunnel's own tool on your Mac whether it's running (the `tailscale` command, or cloudflared's or ngrok's status address on `127.0.0.1`); nothing leaves your Mac for this.

- **Only agents you allow cloud access** can be used from the internet, each with its own remote token or a cloud app you signed in with a code you compared on your Mac. A cloud agent gets exactly the access you set for it, with the same approvals as an agent on your Mac.
- **What you release goes to the cloud agent's vendor**, for example Anthropic or OpenAI, and may stay in their logs under their terms.
- **The tunnel provider may see the traffic.** With Tailscale Funnel, TLS ends on your Mac, so the relays can't read it. Cloudflare and ngrok end TLS at their edge, so they can read what passes, memory text included.
- **Funes Vault makes two kinds of outbound requests for Remote Access:** a test that fetches its own health address through your tunnel (when you save the address, and when you click **Test** or **Try Again**), and, only while you have pairing open, a fetch of the signing-in app's public metadata document (https only, to a public address, no credential, only the app's name and version as User-Agent, at most 16 KB).
- **What's kept on your Mac:** the remote token's file (mode 0600, the vault stores only its hash), the list of connected cloud apps with hashes of their tokens (`remote-connections.json`, mode 0600), and, in memory only, the tunnel and forwarded address of the last 50 remote requests. Nothing about your tunnel or cloud apps is sent anywhere else.
- **Turn Off Remote Access** in the menu bar closes the port at once.

## Funes Vault for iPhone

The iPhone app (v0.2) is a remote for your Mac: it captures, searches, edits, reviews the Inbox and answers agents' requests, all on the vault on your Mac. Its App Store privacy label is **Data Not Collected**: nothing it handles reaches us, or anyone but you and your Mac.

**What stays on the iPhone**
- **No copy of your vault.** Search results, memories, the Inbox and approval panels are fetched from your Mac when you open them and kept in memory only while they're on screen.
- **Captures waiting for your Mac,** in the app's own storage on the iPhone (shared with its share sheet, Shortcuts action and Control, protected until you first unlock the iPhone after a restart). Each one is deleted as soon as your Mac has it. A capture that looks like a password, key or card number is refused before it's saved.
- **The pairing:** your Mac's name and addresses, and this iPhone's keys, in the iPhone's Keychain, usable only on this device. The signing key is in the Secure Enclave where the iPhone has one. **Unpair This iPhone…** deletes them, and asks whether to keep or delete captures still waiting. Removing the iPhone on your Mac (**Settings ▸ iPhone**) makes its keys useless at once.

**What it sends, and where**
- **Only to your own Mac,** once paired by scanning a code your Mac shows. Every request and reply is end-to-end encrypted and signed for that Mac and that iPhone, so only they can read it. It travels over your Wi-Fi (the app looks for your Mac on the local network with Bonjour, which needs iOS's **Local Network** permission), over Tailscale, or through a tunnel you run. A tunnel or network operator sees only encrypted messages, their sizes and timing.
- **Approvals and iCloud.** When an agent's Share, Save or access request waits, your Mac saves a `Doorbell` record in **your own private iCloud database** (CloudKit, container `iCloud.com.funesvault`). It holds a single field, a random tag for your iPhone, under a random name: no memory text, titles, task, agent name or counts. Your iPhone subscribes to its tag, so Apple's push service wakes it. The app then asks your Mac, over the encrypted channel, what the request is, and words the notification on the iPhone ("Claude Code wants 3 memories"): it names the agent and the count or category, never memory text, because a locked screen shows it. The Mac deletes the record when the request is answered, expires or changes. Apple can see that your devices exchanged a record at a given time; we can't read your private database. This needs the same Apple Account, with iCloud, on the Mac and the iPhone. Turn approvals off on the iPhone in **Settings ▸ Approvals**, or for each iPhone on the Mac.
- **Nothing else.** No analytics, advertising or tracking code, no crash reporter, no accounts. The share sheet, the Shortcuts action and the Control only add to the captures waiting on the iPhone.

**Dictation.** On iOS 26 and later the mic button uses Apple's speech recognition on the iPhone. On earlier versions it opens the keyboard's dictation, which works under Apple's terms and your **Siri & Dictation** settings.

**Demo mode** shows every screen with a sample vault built into the app, for App Review and for trying the app before you pair. Nothing in it is sent anywhere, it never mixes with your data, and its edits and captures are discarded when you leave it.

**Crash reports and TestFlight.** If you choose to share analytics with app developers in iOS's **Settings ▸ Privacy & Security ▸ Analytics & Improvements**, Apple may pass us crash reports under [Apple's privacy policy](https://www.apple.com/legal/privacy/). TestFlight testers' feedback and crash reports reach us the same way, through Apple.

**On your Mac, iPhone access** (off by default, **Settings ▸ iPhone**) opens a listener on port 47626 that accepts only the network addresses of the modes you turn on (your local network, Tailscale, or your tunnel through `127.0.0.1`), and, for the local network, advertises a Funes service with Bonjour, under your Mac's name as file sharing and AirPlay do, so your iPhone can find it. Each paired iPhone's requests appear in Activity under that iPhone.

## Update checks

Funes Vault uses [Sparkle](https://sparkle-project.org) 2 to check for updates.

- **What it fetches:** `https://github.com/bereciartua/funes-vault-app/releases/latest/download/appcast.xml`, which GitHub serves from its release storage. When you install an update, it downloads the update archive from the same place. Every update is checked against Funes Vault's EdDSA signature before it's installed, and installing always takes your click.
- **What it sends:** an ordinary HTTPS request whose User-Agent names the app and its version (for example `Funes Vault/0.1.2 Sparkle/2.10.0`), plus the standard headers macOS's networking adds to every request, such as your preferred languages (`Accept-Language`). Sparkle's system profiling is off: no macOS version, Mac model, CPU or other system details are sent as feed parameters, and the feed URL has no parameters at all. GitHub sees your IP address, as with any request, under the [GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement). <!-- TODO(check): confirm the exact headers on the release build with a proxy (Proxyman or mitmproxy). -->
- **When:** once a day while **Check for updates every day** is on (it's on by default), and when you click **Check Now** in **Settings ▸ Updates** or **Check for Updates…** in the menu. Turn it off in **Settings ▸ Updates**. A copy built from source never checks: only the copies Funes Vault publishes, signed with its Developer ID, do.

## AI models

Funes Vault proposes a title, kind, categories and sensitivity for each new capture, which you review in the Inbox.

- **By default this happens on your Mac**, with Apple's on-device model (Apple Intelligence, on macOS 26 or later where it's available) or, when that isn't available, simple rules. Apple's on-device model runs locally; Funes Vault doesn't use Apple's Private Cloud Compute. You can turn proposals off in **Settings ▸ Capture**; captures then get proposals from the rules only.
- **You can add a provider** in **Settings ▸ AI Models**: a local server (Ollama, LM Studio or another server on your Mac or local network), or a cloud service (Anthropic, OpenAI, or any OpenAI-compatible endpoint). Nothing is sent to a provider until you add it and choose it for Classification.
- **What a chosen provider receives:** the text of each new capture, from your Mac or your iPhone, and your category names and descriptions, so it can pick categories. Agent suggestions and imports are never sent to a provider: they arrive with their fields already proposed. Requests to a cloud provider also carry the API key you gave it, which Funes Vault keeps only in your Mac's Keychain. **Load Models** asks the provider for its model list, and **Test Connection** classifies one made-up note among Funes Vault's built-in categories, so neither sends any of your memories or category names.
- **The cloud limit** (default **Internal**) applies to every provider that isn't on your Mac or your local network, for every task. Funes Vault first estimates each text's sensitivity on your Mac; text that already has a level is checked against the higher of the two. If anything in a request is above your limit, or of unknown sensitivity, nothing is sent: the capture is classified on your Mac instead and its card says it was kept on this Mac. You can set the limit to Public, Low, Internal, Sensitive, Restricted, **Everything, including Secret**, or **Nothing**. Choosing a level above Internal asks you to confirm first, naming the provider: those levels can send health, money, family and legal matters. Text that looks like a password, key or card number is never sent, whatever the limit. While captures can go to a cloud provider, the capture box says so ("fields suggested by Anthropic").
- **Cloud requests per day** (300 by default, in **Settings ▸ AI Models**) caps how many requests Funes Vault sends to cloud providers each day, so a large import or a busy agent can't run up your bill. Agents' input may use at most 40% of it. At the limit, captures are classified on your Mac until the next day. The count is kept in your vault, on your Mac.
- **Anything that looks like a secret** (a password, an API key, a card number) is never sent to any provider that isn't Apple's on-device model.
- **Cloud providers must use HTTPS.** A provider is treated as local only if its address is on your Mac or your private network; anything else is cloud, whatever it's called.
- **Your provider's terms apply** to what you send it, including whether it keeps or trains on it. Funes Vault shows request and token counts per provider; costs are between you and the provider.

Search embeddings aren't configurable in v0.1: they always run on your Mac with the built-in model.

## No analytics, no crash reports

Funes Vault contains no analytics, advertising or tracking code, and no crash reporter. It makes no network requests other than the ones above.

If macOS crashes or hangs Funes Vault, macOS writes a report on your Mac. If you share analytics with Apple (**System Settings ▸ Privacy & Security ▸ Analytics & Improvements**), macOS sends Apple diagnostic data under [Apple's privacy policy](https://www.apple.com/legal/privacy/). We don't receive these reports for an app distributed outside the App Store. If you want us to see one, attach it to an issue after removing anything private.

## Installing

- **The DMG** comes from GitHub Releases, under GitHub's privacy statement.
- **Homebrew** (`brew install --cask bereciartua/tap/funes-vault`) downloads the same DMG from GitHub. Homebrew has its own [analytics](https://docs.brew.sh/Analytics), which you can turn off with `brew analytics off`. Funes Vault doesn't receive them.

## This website

funesvault.com is a static site hosted on GitHub Pages. It sets no cookies, loads no fonts, scripts or images from anywhere else, and has no analytics. Its one script runs in your browser and sends and stores nothing: it adds the copy button for the Homebrew command, and lets the eye on the home page follow your pointer (not if you've asked your system to reduce motion). GitHub, as the host, receives your IP address and request details and keeps logs under the [GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement). Downloads and documentation links go to GitHub.

## Support

- **GitHub Issues** are public. Don't paste memories, agent keys or API keys into an issue.
- **Security reports** go privately through GitHub's private vulnerability reporting ([SECURITY.md](https://github.com/bereciartua/funes-vault-app/blob/main/SECURITY.md)).

## Children

Funes Vault, on the Mac and the iPhone, isn't directed at children and collects no personal data from anyone.

## Changes

When this statement changes, the date at the top changes, and the change is listed in the [CHANGELOG](https://github.com/bereciartua/funes-vault-app/blob/main/CHANGELOG.md). A version that sends anything new will say so here before it ships.

## Contact

Funes Vault is an open-source project maintained by [bereciartua](https://github.com/bereciartua). For questions, open an [issue](https://github.com/bereciartua/funes-vault-app/issues); for anything sensitive, use [private vulnerability reporting](https://github.com/bereciartua/funes-vault-app/security/advisories/new).
