# TermAI

A coding agent for iPhone, laid out like Claude Code: sessions in a sidebar, a composer with environment, folder, model, effort and permission controls, and tool calls shown as they run. It talks to your own inference gateway and works either on files on the phone or on your servers over SSH.

## Install

Every push builds an unsigned IPA on GitHub Actions.

1. Open the latest **Build** run under the repository's *Actions* tab.
2. Download the `TermAI-unsigned-ipa` artifact and unzip it.
3. Sign and install `TermAI-unsigned.ipa` with your sideloading tool (AltStore, Sideloadly, TrollStore, or your own certificate).

The same run uploads a `screenshots` artifact with the main screens and every theme.

## Connect a gateway

**Settings › Add connection** has the fields of Claude Desktop's third-party inference screen:

| Field | Notes |
| --- | --- |
| API format | **Anthropic Messages** (`/v1/messages`, what Claude Code gateways speak) or **OpenAI-compatible** (`/chat/completions`) |
| Gateway base URL | e.g. `https://llm-gateway.example.com`; for the Anthropic format `/v1` is added if it is missing |
| Gateway API key | stored in the Keychain |
| Gateway auth scheme | `bearer` (`Authorization: Bearer …`) or `x-api-key` |
| Custom inference headers | sent with every request |
| Model discovery | fills the model picker from the gateway's model list at launch |
| Model list | models you add by hand; they come first and the first is the default |
| Default model effort | `low` to `max`, or Default to leave it to the model |
| Always start with the default model | otherwise new sessions keep your last model and effort |

For the Anthropic format there are also **Max output tokens** and **Prompt caching** (on by default; it makes tool rounds cheaper). Reasoning blocks are sent back unchanged between tool rounds, as the API requires.

## Work

- **Environment and folder.** The chips under the composer choose where the session works: *This iPhone* (files only, there is no shell on iOS) or an SSH host from **Settings › Environments**, and the working folder there. A `CLAUDE.md` or `AGENTS.md` in the folder is read as project instructions.
- **Tools.** `Bash` (SSH environments), `Read`, `Write`, `Edit`, `Glob`, `Grep`, `WebFetch` and a task list. Edits are shown as diffs.
- **Permission modes.**
  - *Ask permissions*: commands, edits and web requests wait for you. Reads inside the working folder do not.
  - *Accept edits*: file edits inside the folder run without asking.
  - *Plan mode*: read-only; the agent investigates and proposes a plan.
  - *Bypass permissions*: nothing asks.

  A prompt offers **Deny**, **Allow once** and, where a safe rule exists, **Always allow** for the rest of the session (for example `git status` commands, edits, or one web domain). Chained or redirected commands never get a standing rule.
- **Shell mode.** The terminal button in the top bar, or a leading `!`, runs a command on the SSH host yourself; the model is told what happened.
- **Sessions.** The sidebar lists saved sessions grouped by environment and folder, with search, pin, rename and delete.
- **Keep the app open while it works.** iOS suspends apps in the background, which cuts the response stream. The screen stays on while the agent is working (not while it waits for your answer), and switching away leaves a turn only the short grace period iOS allows. A session that was cut off keeps everything up to its last finished tool round; send a message to carry on.

| Command | What it does |
| --- | --- |
| `/new`, `/clear` | start a new session |
| `/resume` | open the session list |
| `/model [id]`, `/effort [level]`, `/mode [name]` | same as the chips |
| `/env [name\|local]`, `/cd [path]` | switch environment or folder |
| `/compact` | replace the conversation with a summary to free context |
| `/init` | have the agent write a `CLAUDE.md` for the folder |
| `/usage`, `/retry`, `/copy`, `/export` | token use, resend, copy the last answer, share as Markdown |
| `/theme [id]` | `dark`, `light`, `terminal`, `crt-green`, `crt-amber` |
| `/config` | open settings |

## Safety model

- **Secrets.** API keys, custom header values, passwords and private keys are stored in the iOS Keychain (this device only), never in the JSON settings files.
- **Host keys.** The first connection to a host records its key and shows the fingerprint; later connections are refused if the key changes.
- **On-device files.** File tools on the phone are confined to the app's Documents folder, visible in Files › On My iPhone › TermAI.
- **On SSH hosts** the agent has whatever access the SSH user has. The permission prompts are the guard rail, not a sandbox. A command that times out or is stopped may keep running on the host.
- **Network.** The app talks only to the gateways and hosts you configure, plus URLs you approve for `WebFetch`. Plain-`http` gateways are allowed for LAN servers; the app warns when a key would be sent over one.

SSH private keys must be Ed25519 or RSA in OpenSSH format. File tools on SSH hosts use SFTP.

## Development

```
TermKit/            Swift package
  Sources/TermCore  models, gateway client (both wire formats), agent loop, tools, permissions,
                    and the app's state (no UI; builds and is tested on Linux)
  Sources/TermSSH   SSH connection and SFTP on top of Citadel
App/                SwiftUI views
project.yml         XcodeGen project definition
```

```sh
swift test --package-path TermKit      # unit tests (macOS or Linux)
xcodegen generate && open TermAI.xcodeproj
```

Some tests talk to real services and are skipped unless configured:

```sh
python3 TermKit/Tests/mock_server.py 8765 &     # mock gateway, both formats
TERMAI_TEST_BASEURL=http://127.0.0.1:8765 \
TERMAI_SSH_HOST=127.0.0.1 TERMAI_SSH_USER=me TERMAI_SSH_PASSWORD=… \
swift test --package-path TermKit
```

`-demoScreen chat -theme dark` as launch arguments starts the app with sample content, which is how CI takes its screenshots.
