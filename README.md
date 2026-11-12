# dpoc-fleet — what exists (PoC of the diene fleet)
- `registry/` 👤 people, by PR: landscapes, clusters, accounts. The ONLY human-edited part.
- `machinery/` 🧱 static: fleet-root (the one hand-applied object), the platforms AppSet (finds `dpoc-*.carbon` repos), the baseline AppSet, CRDs, T3, the compiler chart.
- Machine-written state lives in `ProtoDurian/dpoc-fleet-state` (never here).
New platform = create `dpoc-<p>.carbon`. New service = create `dpoc-<p>.<svc>`. Neither edits this repo.
