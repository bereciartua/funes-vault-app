# Users and use cases

## Personas

### P1: Maya, the multi-agent developer (primary for v0.1)
- **Profile:** a senior engineer who uses Claude Code in the terminal, Cursor for some repos, Codex occasionally and Claude Desktop for writing.
- **Pain:** every agent starts cold. She keeps a `CLAUDE.md`, a Cursor rules file and a scratch note of "things to tell AIs", and they drift apart.
- **Wants:** one place for her coding preferences, stack, current projects and writing style, available to every agent. Agents should be able to propose new memories ("you said you prefer pnpm, remember that?") without her copying anything by hand.
- **Worries:** she doesn't want a work agent to see her health or finance notes, or a random MCP client to read everything.

### P2: Diego, the privacy-minded professional
- **Profile:** a consultant who uses ChatGPT, Claude Desktop and a few MCP-enabled tools for client work and personal admin.
- **Pain:** he's uneasy that each assistant builds its own profile of him that he can't fully see.
- **Wants:** to know exactly what each tool received and when. He wants to keep client details away from personal tools and family details away from work tools.
- **Worries:** cloud storage of personal context; sharing that's too broad.

### P3: Sam, the capture-on-the-go user (primary for v0.2)
- **Profile:** has ideas, preferences and decisions while walking, commuting or in meetings, away from the Mac.
- **Wants:** to grab a thought in two seconds on the iPhone (Action button, share sheet, dictation) and know it will reach the vault.
- **Accepts:** search from the phone working only when the Mac is reachable.

### Anti-persona
Someone who wants an AI chat app with memory built in, team-shared memory, or automatic mining of every conversation. Funes deliberately doesn't do this.

## Jobs to be done

| Id | When… | I want to… | So that… |
|---|---|---|---|
| J1 | I start a task with any AI agent | have it pull the right context from my vault, with my approval | I don't re-explain myself |
| J2 | an agent learns something durable about me | have it propose a memory I can accept with one click | my vault grows without busywork |
| J3 | I connect a new tool | grant it narrow access (some categories, low sensitivity) | it can't see what it doesn't need |
| J4 | something is shared | see exactly what text went to which agent and why | I trust the system and can audit it |
| J5 | I change my mind about a tool | pause or revoke it instantly | nothing more leaves the vault |
| J6 | I think of something away from my Mac | capture it on my phone instantly | it's not lost, even if the Mac is asleep |
| J7 | I need to check or fix a memory on the go | search and edit the vault from my phone | the vault stays accurate |
| J8 | I first install Funes | seed the vault quickly from what other assistants already know | it's useful on day one |
| J9 | memories go stale | see expired or duplicate ones and clean up | agents don't get outdated context |

## Key scenarios

### S1: First run (Maya, about 5 minutes)
1. Installs from the DMG or with `brew install --cask bereciartua/tap/funes-vault`. The app offers to move itself to /Applications.
2. Setup checklist, step 1, **seed your vault**:
   - She answers some of seven quick questions (collaboration style, communication, software development, current projects, privacy boundaries, constraints, goals). The answers become suggestions in the Inbox.
   - Optionally, she imports her ChatGPT memory export or pastes her Claude memories.
3. Step 2, **review**: she applies the suggestions she likes. Each has a proposed category and sensitivity, adjustable before applying.
4. Step 3, **add an agent**:
   - Picks Claude Code from the detected-agents tiles.
   - Chooses a starting access ("Read non-sensitive memories in all categories, ask before sharing").
   - Clicks **Add to Claude Code…**, which shows the exact config change, writes it with a backup, and never puts the key in the config.
5. The checklist completes when Claude Code makes its first request.

### S2: An agent asks for context (Maya, every day)
1. In Claude Code, Maya asks: "Set up the new repo the way I like it."
2. Claude Code calls `request_memory` with task "set up a new TypeScript repo following the user's preferences".
3. Funes evaluates the request. Claude Code has Read access up to INTERNAL in *Software Development* and *Project Context*, with ask before sharing on. Four memories match.
4. The **Share with Claude Code?** panel appears at the top right without stealing focus. It shows the four memories' exact text, each with a checkbox, plus the agent's stated purpose, labelled as reported by the agent.
5. Maya unchecks one and clicks **Share 3**. The tool call returns the three memories. Activity records "Shared 3 memories with Claude Code" (ids only).
6. If she doesn't answer within 45 seconds, the call returns `needs_approval`. She can still approve from the menu bar within 15 minutes, and the agent fetches the result with `get_memory_request`.

### S3: An agent suggests a memory
1. During a session, Maya says "I always use Vitest, not Jest." Claude Code calls `suggest_memory` with a title, a body, the category *Software Development*, kind PREFERENCE and sensitivity LOW.
2. Claude Code has Suggest but not Write, so the **Save this memory?** panel appears: **Save**, **Edit…**, **Later** (to the Inbox) or **Discard**.
3. If nobody answers, the suggestion waits in the Inbox. It is never lost and never saved automatically.

### S4: Narrow access for a less trusted tool (Diego)
1. Diego adds a new MCP client with **no starting access**.
2. In its access screen he grants Read for *Communication Style* only, up to LOW, with ask before sharing on.
3. The tool asks for context about a client project. No allowed memories match, so it gets `denied` with reason `no_allowed_memories` and a count of withheld memories, with no ids or text.
4. If "Let it ask for more access" is on, Funes shows an access request ("Tool X wants to read Project Context"). Diego picks **Not Now**.

### S5: Audit and revoke (Diego)
1. Diego opens Activity, filters to his writing app and sees every disclosure with time, memory count, approval answer and task.
2. He opens a row; Funes looks up the current memory titles live (the log stores only ids).
3. He's uncomfortable with one tool and clicks **Pause**. Its next request is refused with `agent_paused`. Later he clicks **Remove** and its key stops working immediately.

### S6: Capture on the go (Sam, iPhone)
1. On a walk, Sam presses the Action button, which is set to "Remember in Funes", and dictates "Prefer morning meetings before 11".
2. The capture is saved on the phone and queued; the app shows "1 waiting for your Mac".
3. At home, the phone finds the Mac on the same Wi-Fi via Bonjour. The capture is sent (signed and encrypted), accepted once (by its capture id), and lands in the Mac's Inbox with suggested categories. The phone deletes its copy.

### S7: Search from the phone (Sam)
1. At a café, Sam opens Funes on the iPhone. Through Tailscale it reaches the Mac at home.
2. He searches "dentist". The Mac runs the search and returns titles and snippets; tapping one fetches the full memory.
3. He edits it ("moved to Dr. Lee") and saves. If the Mac isn't reachable, the app says so and offers capture only.

## User stories

User stories with acceptance criteria are in [requirements](03-requirements.md), grouped by area. Each requirement id (for example `FR-D-04`) is referenced from the [backlog](../roadmap/backlog.md).
