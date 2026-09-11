// Take Charge book checkout: website -> Supabase -> Yoco
//
// POST  The order form posts here. This function, not the browser, sets the
//       price, saves the order as 'pending' in public.book_orders, asks Yoco for
//       a checkout and returns Yoco's hosted payment page URL. The Yoco secret
//       key never reaches the browser and a visitor cannot change the amount.
//
// GET   ?order=<uuid>  returns only that order's status, so the page a buyer
//       returns to can say whether the payment has been confirmed.
//
// A payment is confirmed ONLY by the yoco-webhook function. Landing on the
// success URL proves nothing; Yoco's documentation says the same.
//
// Secrets (Dashboard -> Edge Functions -> Secrets):
//   YOCO_SECRET_KEY  sk_test_... while testing, sk_live_... to take real payments
//   SITE_ORIGINS     optional, comma-separated extra site origins (e.g. the real
//                    domain once it is live). The pages.dev address is built in.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy with "Verify JWT" OFF: the website calls this without a user session.

const env = (k: string) => Deno.env.get(k) ?? "";

// Prices live on the server, in cents. Price and delivery options match TCLI's
// Paystack product page for the book (R320; Johannesburg R90, KwaZulu-Natal
// R120, collection free), charged once per order.
const BOOKS: Record<string, { name: string; price: number }> = {
  "take-charge": { name: "Take Charge: Life Lessons on the Road to CEO", price: 32000 },
};
const DELIVERY: Record<string, { name: string; fee: number }> = {
  johannesburg: { name: "Delivery: Johannesburg", fee: 9000 },
  kzn: { name: "Delivery: KwaZulu-Natal", fee: 12000 },
  collection: { name: "Collection", fee: 0 },
};

const ORIGINS = [
  "https://nyimpinimabunda-com.pages.dev",
  ...env("SITE_ORIGINS").split(",").map((s) => s.trim().replace(/\/$/, "")).filter(Boolean),
];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function headers(origin: string | null) {
  return {
    "Access-Control-Allow-Origin": origin && ORIGINS.includes(origin) ? origin : ORIGINS[0],
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Vary": "Origin",
    "Content-Type": "application/json",
  };
}

function reply(origin: string | null, status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: headers(origin) });
}

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

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");

function validate(b: Record<string, unknown>) {
  const o = {
    book: str(b.book) || "take-charge",
    first_name: str(b.first_name),
    last_name: str(b.last_name),
    email: str(b.email).toLowerCase(),
    phone: str(b.phone),
    delivery: str(b.delivery),
    delivery_address: str(b.delivery_address) || null,
    copies: Number(b.copies),
    signed: b.signed === true,
    sign_for: str(b.sign_for) || null,
    accepted_terms: b.accepted_terms === true,
    terms_version: str(b.terms_version),
    source: str(b.source).slice(0, 60) || null,
  };
  // Same rules as the table's check constraints, so a bad form gets a clear
  // message instead of a database error.
  if (!BOOKS[o.book]) return { error: "Unknown book." };
  if (!o.first_name || !o.last_name || o.first_name.length > 80 || o.last_name.length > 80)
    return { error: "Please give your first name and surname." };
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(o.email) || o.email.length > 254)
    return { error: "That email address does not look right. Please check it." };
  const digits = o.phone.replace(/\D/g, "");
  if (!/^\+?[0-9 ()-]+$/.test(o.phone) || digits.length < 9 || digits.length > 15)
    return { error: "That contact number does not look right. Please check it." };
  if (!DELIVERY[o.delivery]) return { error: "Please choose delivery or collection." };
  if (o.delivery === "collection") o.delivery_address = null;
  else if (!o.delivery_address || o.delivery_address.length < 10 || o.delivery_address.length > 500)
    return { error: "Please give the full delivery address." };
  if (!Number.isInteger(o.copies) || o.copies < 1 || o.copies > 50)
    return { error: "Please choose between 1 and 50 copies." };
  if (o.sign_for && o.sign_for.length > 120) return { error: "The name to sign for is too long." };
  if (!o.signed) o.sign_for = null;
  if (!o.accepted_terms || !o.terms_version || o.terms_version.length > 40)
    return { error: "Please accept the terms to continue." };
  return { order: o };
}

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: headers(origin) });

  // ── status lookup for the return page ────────────────────────────────────
  if (req.method === "GET") {
    const id = new URL(req.url).searchParams.get("order") ?? "";
    if (!UUID.test(id)) return reply(origin, 400, { error: "Bad order id." });
    const r = await db(`book_orders?id=eq.${id}&select=status,mode`);
    const rows = r.ok ? await r.json() : [];
    if (!rows.length) return reply(origin, 404, { error: "Order not found." });
    return reply(origin, 200, rows[0]);
  }

  if (req.method !== "POST") return reply(origin, 405, { error: "Method not allowed." });

  const secret = env("YOCO_SECRET_KEY");
  if (!/^sk_(test|live)_/.test(secret)) {
    console.error("book-checkout: YOCO_SECRET_KEY is not set");
    return reply(origin, 503, { error: "Online payment is not available right now." });
  }
  const mode = secret.startsWith("sk_live_") ? "live" : "test";

  let input: Record<string, unknown>;
  try { input = await req.json(); } catch { return reply(origin, 400, { error: "Bad request." }); }
  const v = validate(input);
  if (v.error || !v.order) return reply(origin, 400, { error: v.error });

  const book = BOOKS[v.order.book];
  const delivery = DELIVERY[v.order.delivery];
  const amount = book.price * v.order.copies + delivery.fee;

  // 1. Save the order first, so no attempt to pay is ever lost.
  const ins = await db("book_orders", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({
      ...v.order,
      unit_price_cents: book.price,
      delivery_fee_cents: delivery.fee,
      amount_cents: amount,
      mode,
    }),
  });
  if (!ins.ok) {
    console.error("book-checkout insert:", ins.status, await ins.text());
    return reply(origin, 500, { error: "We could not start your order. Please try again." });
  }
  const [order] = await ins.json();

  // 2. Ask Yoco for a hosted checkout. The order id doubles as the idempotency
  //    key, so a retried request cannot create a second checkout.
  const site = origin && ORIGINS.includes(origin) ? origin : ORIGINS[0];
  const back = (state: string) => `${site}/?order=${order.id}&payment=${state}#book`;
  const yoco = await fetch("https://payments.yoco.com/api/checkouts", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${secret}`,
      "Content-Type": "application/json",
      "Idempotency-Key": order.id,
    },
    body: JSON.stringify({
      amount,
      currency: "ZAR",
      successUrl: back("success"),
      cancelUrl: back("cancelled"),
      failureUrl: back("failed"),
      externalId: order.id,
      metadata: { orderId: order.id, book: v.order.book },
      lineItems: [
        {
          displayName: book.name + (v.order.signed ? " (signed)" : ""),
          quantity: v.order.copies,
          pricingDetails: { price: book.price },
        },
        ...(delivery.fee > 0
          ? [{ displayName: delivery.name, quantity: 1, pricingDetails: { price: delivery.fee } }]
          : []),
      ],
    }),
  });

  if (!yoco.ok) {
    const detail = (await yoco.text()).slice(0, 500);
    console.error("book-checkout yoco:", yoco.status, detail);
    await db(`book_orders?id=eq.${order.id}`, {
      method: "PATCH",
      body: JSON.stringify({ status: "cancelled", last_error: `yoco ${yoco.status}: ${detail}` }),
    });
    return reply(origin, 502, { error: "The payment page could not be opened. Please try again." });
  }

  const checkout = await yoco.json();
  await db(`book_orders?id=eq.${order.id}`, {
    method: "PATCH",
    body: JSON.stringify({ checkout_id: checkout.id }),
  });

  return reply(origin, 200, { orderId: order.id, redirectUrl: checkout.redirectUrl, mode });
});
