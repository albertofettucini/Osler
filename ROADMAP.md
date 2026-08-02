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

## v1.2 — The Approval node 🤝

**The headline:** a flow can pause for a human. The run stops at the node,
shows what's about to happen, and the user approves, edits, or rejects
before it continues.

This is the one place we break principle 3, because this node *is* the
philosophy: agents propose, the human decides. It is also a strong safety
differentiator once tools (v1.1) can touch the real world.

Riders: **per-node token & cost display** — BYOK users deserve to see what each
node spent. And **structured output** — an optional JSON schema on an Agent, so
a node can promise a shape instead of hoping the prompt holds. Both providers
support this natively; it's a field on the existing node, not a new one.

## v1.3 — Sub-flows + Repeat node 🧩

**The headline:** composition. Use a saved flow as a single node inside
another flow — templates stop being snippets and become building blocks,
laying the foundation for a template ecosystem.

**Repeat node:** runs a saved sub-flow repeatedly until an exit condition
is met (a keyword match or an LLM yes/no check), with a hard
max-iterations cap (default 5). Iteration is contained *inside* the node,
so the parent graph remains a DAG and cycle detection stays untouched.
This is how Osler gets critic-loops — "revise until the reviewer
approves" — without ever allowing cycles on the canvas.

## v1.4 — Persistent run history & replay 🕰

**The headline:** past runs survive relaunch, and a run can be replayed
step by step, node by node. (The in-memory session history from v1 becomes
durable and navigable.)

## Growth layer (later, order flexible)

- **Flow runner CLI + scheduling** — extend the existing `osler-cli` to run
  `.oslerflow` files headlessly; `launchd` integration for "every morning
  at 9".
- **Apple Shortcuts export** — trigger a flow system-wide (or from an
  iPhone). Something web-based competitors can never do.
- **Export canvas as image** — one-click PNG of the flow for sharing.
- **Community template gallery** — a public repo of `.oslerflow` files to
  browse and import. (The local half — My Templates — already exists.)

---

*Everything here obeys the principles at the top. If a feature and a
principle ever collide, the principle wins.*
