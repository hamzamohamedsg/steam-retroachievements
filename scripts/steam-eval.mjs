// Dev tool: evaluate JS in Steam's SharedJSContext over CDP.
// Usage: node scripts/steam-eval.mjs '<expression>'   |   node scripts/steam-eval.mjs --binding-test
const targets = await (await fetch("http://127.0.0.1:8080/json")).json();
const target = targets.find((t) => t.title === "SharedJSContext");
if (!target) { console.error("SharedJSContext not found"); process.exit(1); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
let nextId = 1;
const pending = new Map();
const listeners = [];
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  else listeners.forEach((fn) => fn(msg));
};
const send = (method, params = {}) => new Promise((resolve) => {
  const id = nextId++;
  pending.set(id, resolve);
  ws.send(JSON.stringify({ id, method, params }));
});
setTimeout(() => { console.error("timeout"); process.exit(1); }, 5000);
await new Promise((r) => (ws.onopen = r));

if (process.argv[2] === "--binding-test") {
  await send("Runtime.enable");
  await send("Runtime.addBinding", { name: "__sra_probe" });
  listeners.push((m) => {
    if (m.method === "Runtime.bindingCalled" && m.params.name === "__sra_probe") { console.log(m.params.payload); process.exit(0); }
  });
  await send("Runtime.evaluate", { expression: '__sra_probe("ok")' });
} else {
  const res = await send("Runtime.evaluate", { expression: process.argv[2], awaitPromise: true, returnByValue: true });
  if (res.result?.exceptionDetails) {
    console.error(res.result.exceptionDetails.exception?.description ?? JSON.stringify(res.result.exceptionDetails));
    process.exit(1);
  }
  console.log(JSON.stringify(res.result?.result?.value ?? null, null, 1));
  process.exit(0);
}
