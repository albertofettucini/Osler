# Osler Roadmap

## Guiding principles

1. **One headline feature per release. Never more.** Small riders may tag
   along, but every release has exactly one reason to exist.
2. **Radical simplicity is the product.** Every proposal must answer one
   question first: *does this break simplicity?* If yes, it's out.
3. **The default answer to any new node type is no.** A node earns its place
   only when it embodies the product's philosophy, not when it adds a
   capability.
4. **Local-first forever.** No accounts, no cloud, no telemetry. Your flows,
   your keys, your machine.

## Already in v1

For context — these shipped recently and are deliberately *not* on the
roadmap below: local models via **Ollama**, session **run history** with
per-node outputs, the **⌘K command palette**, **user templates** (save any
flow, reuse it from the library), full **undo/redo**, and **multi-select**.

## Before v1.1

Open v1 items come first:

- [x] End-to-end verification of a real flow run (all three demos verified
      against a live local model via Ollama, including the MCP tool loop)
- [ ] Decide the LICENSE attribution

## v1.1 — MCP tools 🎯

**The headline:** agents can call tools from MCP servers — files, web,
APIs. Osler becomes the first native Mac agent builder that speaks MCP.

Scope is deliberately hard-limited so the feature cannot eat the product:

- **stdio servers only.** You point Osler at a local command; it launches
  and talks to it. No HTTP transports, no OAuth flows, no marketplace.
- **One settings pane.** A plain list of servers: name, command, on/off.
- **Tools flow through native tool-calling.** The Agent node exposes the
  enabled servers' tools to the model via each provider's own tool-use API.
  No new node type.

Rider: an **LM Studio** provider preset (OpenAI-compatible, local — minutes
of work next to the Ollama plumbing).

## v1.2 — Flows your coding agent can call 🎯

**The headline:** a saved flow becomes a command and a tool.
`osler-cli run` runs a `.oslerflow` file from the terminal, and
`osler-cli validate` checks one and names every problem. `osler-cli mcp`
serves a folder of flows over MCP, so Claude Code or any MCP client can call
each flow as one tool. Nothing to host and no open port: it's stdio, started
by the client. The file format gets a published JSON schema.

Riders:

- **Ask before running tools.** Approval lives at the tool boundary, not in
  a new node. Before an MCP tool runs, Osler asks: Allow, Allow all, or Deny.
  A denial goes back to the model as an error, so it can try something else.
  Headless runs refuse tool calls unless you pass `--allow-tools`.
- **A tool trace that stays.** Which tools ran, with what arguments and what
  came back, kept on the node after the run and in run history. It survives
  relaunch once run history does (v1.3).
- **MCP for the 2026-07-28 spec.** Osler asks a server which protocol it
  speaks and falls back to the older handshake, so both kinds work.
- **Apple on-device model.** A keyless provider on Macs with Apple
  Intelligence. Text only, no tools.
- **Per-node token & cost display.** BYOK users deserve to see what each
  node spent.
- **Structured output.** An optional JSON schema on an Agent, so a node can
  promise a shape instead of hoping the prompt holds. Both providers support
  this natively; it's a field on the existing node, not a new one.

## v1.3 — Persistent run history & replay 🕰

**The headline:** past runs survive relaunch, and a run can be replayed
step by step, node by node. (The in-memory session history from v1 becomes
durable and navigable.)

## Growth layer (later, order flexible)

- **Scheduling** — `launchd` recipes around `osler-cli run` for "every
  morning at 9".
- **Apple Shortcuts export** — trigger a flow system-wide (or from an
  iPhone). Something web-based competitors can never do.
- **Export canvas as image** — one-click PNG of the flow for sharing.
- **Community template gallery** — a public repo of `.oslerflow` files to
  browse and import. (The local half — My Templates — already exists.)

---

*Everything here obeys the principles at the top. If a feature and a
principle ever collide, the principle wins.*
