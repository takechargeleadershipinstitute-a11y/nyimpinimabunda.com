// Yoco -> Supabase: marks a Take Charge book order paid
//
// Yoco calls this when a payment succeeds. The message is accepted only if its
// signature checks out against the secret Yoco issued for this webhook, so
// nobody else can mark an order paid. The order must also match the amount the
// book-checkout function charged.
//
// One-time setup, per key mode (test, then live):
//   POST <function url>?setup=1
// registers this function's URL with Yoco using YOCO_SECRET_KEY and stores the
// signing secret Yoco returns (shown only once) in public.yoco_webhooks. It
// refuses to run again for a mode that is already registered, and never returns
// the secret.
//
// Signature check, per Yoco's "Verifying the events" guide: HMAC-SHA256 over
// "<webhook-id>.<webhook-timestamp>.<raw body>" with the base64-decoded secret
// (minus its whsec_ prefix), base64-encoded, compared with each "v1,<sig>"
// entry in the webhook-signature header. Timestamps older than 3 minutes are
// rejected.
//
// Secrets: YOCO_SECRET_KEY (same as book-checkout).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy with "Verify JWT" OFF: Yoco cannot send a Supabase session.

const env = (k: string) => Deno.env.get(k) ?? "";

async function db(path: string, init: RequestInit = {}) {
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  return await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function signatureOk(req: Request, raw: string, secret: string) {
  const id = req.headers.get("webhook-id");
  const ts = req.headers.get("webhook-timestamp");
  const sigs = req.headers.get("webhook-signature");
  if (!id || !ts || !sigs) return false;
  if (!/^\d+$/.test(ts) || Math.abs(Date.now() / 1000 - Number(ts)) > 180) return false;

  const keyBytes = Uint8Array.from(atob(secret.replace(/^whsec_/, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${raw}`)));
  const expected = btoa(String.fromCharCode(...mac));

  return sigs.split(" ").some((entry) => {
    const [version, sig] = entry.split(",");
    return version === "v1" && !!sig && safeEqual(sig, expected);
  });
}

async function setup() {
  const secret = env("YOCO_SECRET_KEY");
  if (!/^sk_(test|live)_/.test(secret)) return json(503, { error: "YOCO_SECRET_KEY is not set." });
  const mode = secret.startsWith("sk_live_") ? "live" : "test";

  const existing = await db(`yoco_webhooks?mode=eq.${mode}&select=mode,webhook_id,url`);
  const rows = existing.ok ? await existing.json() : [];
  if (rows.length) return json(200, { ok: true, mode, alreadyRegistered: true, webhookId: rows[0].webhook_id });

  const url = `${env("SUPABASE_URL")}/functions/v1/yoco-webhook`;
  const res = await fetch("https://payments.yoco.com/api/webhooks", {
    method: "POST",
    headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
    body: JSON.stringify({ name: `nyimpinimabunda-book-orders-${mode}`, url }),
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 500);
    console.error("yoco-webhook setup:", res.status, detail);
    return json(502, { error: `Yoco refused the webhook registration (${res.status}).`, detail });
  }
  const hook = await res.json();
  if (!hook.secret) return json(502, { error: "Yoco did not return a webhook secret." });

  const save = await db("yoco_webhooks", {
    method: "POST",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({ mode, webhook_id: hook.id, url, secret: hook.secret }),
  });
  if (!save.ok) {
    console.error("yoco-webhook setup save:", save.status, await save.text());
    return json(500, { error: "Registered with Yoco but could not store the secret." , webhookId: hook.id });
  }
  return json(200, { ok: true, mode, registered: true, webhookId: hook.id, url });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed." });
  if (new URL(req.url).searchParams.get("setup") === "1") return await setup();

  const raw = await req.text();

  // Try every stored secret (test and live); the event says which mode it is,
  // but it cannot be trusted until a signature has matched.
  const hooks = await db("yoco_webhooks?select=mode,secret");
  const secrets: { mode: string; secret: string }[] = hooks.ok ? await hooks.json() : [];
  let verifiedMode: string | null = null;
  for (const h of secrets) {
    if (await signatureOk(req, raw, h.secret)) { verifiedMode = h.mode; break; }
  }
  if (!verifiedMode) {
    console.warn("yoco-webhook: signature did not verify");
    return json(401, { error: "Invalid signature." });
  }

  let event: { type?: string; payload?: Record<string, any> };
  try { event = JSON.parse(raw); } catch { return json(400, { error: "Bad payload." }); }
  const p = event.payload ?? {};

  if (event.type !== "payment.succeeded") {
    console.log("yoco-webhook: ignored event", event.type);
    return json(200, { ok: true, ignored: event.type });
  }

  const checkoutId = p.metadata?.checkoutId;
  if (!checkoutId) return json(200, { ok: true, ignored: "no checkoutId" });

  const found = await db(`book_orders?checkout_id=eq.${encodeURIComponent(checkoutId)}&select=id,status,amount_cents,mode`);
  const [order] = found.ok ? await found.json() : [];
  if (!order) {
    // Not one of ours (e.g. another integration on the same Yoco account).
    console.log("yoco-webhook: no order for checkout", checkoutId);
    return json(200, { ok: true, ignored: "unknown checkout" });
  }
  if (order.status !== "pending") return json(200, { ok: true, already: order.status });

  if (p.amount !== order.amount_cents || p.currency !== "ZAR" || (p.mode && p.mode !== order.mode)) {
    const note = `payment ${p.id} did not match: amount ${p.amount} ${p.currency} mode ${p.mode}`;
    console.error("yoco-webhook:", order.id, note);
    await db(`book_orders?id=eq.${order.id}`, { method: "PATCH", body: JSON.stringify({ last_error: note }) });
    return json(200, { ok: false, mismatch: true });
  }

  // Only a pending order moves to paid, so Yoco's retries are harmless.
  await db(`book_orders?id=eq.${order.id}&status=eq.pending`, {
    method: "PATCH",
    body: JSON.stringify({ status: "paid", payment_id: p.id ?? null, paid_at: new Date().toISOString(), last_error: null }),
  });

  return json(200, { ok: true, orderId: order.id, status: "paid", mode: verifiedMode });
});
