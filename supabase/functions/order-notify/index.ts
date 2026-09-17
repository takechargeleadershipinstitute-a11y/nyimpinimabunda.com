// Book order notifications: Supabase -> Resend
//
// Triggered by a database webhook on public.book_preorders for INSERT and
// UPDATE. Emails TCLI when:
//   - a new order is placed on the website, and
//   - someone changes an order's status on the dashboard (who, and to what).
// Other updates (none today) send nothing.
//
// Uses the same secrets as waitlist-sync: RESEND_API_KEY, NOTIFY_TO, NOTIFY_FROM.
// Until a domain is verified in Resend, NOTIFY_TO must be the Resend account's
// own address, or Resend refuses with a 403.

interface Order {
  id: string;
  created_at: string;
  book: string;
  order_ref: string | null;
  title: string | null;
  first_name: string;
  last_name: string;
  email: string;
  phone: string;
  job_title: string | null;
  industry: string | null;
  copies: number;
  delivery: string | null;
  delivery_address: string | null;
  signed: boolean;
  sign_for: string | null;
  status: string;
  status_changed_at: string | null;
  status_changed_by: string | null;
}

const env = (k: string) => Deno.env.get(k) ?? "";

const esc = (s: unknown) =>
  String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

const BOOK: Record<string, string> = {
  "take-charge": "Take Charge (R320)",
  "ceo-nights": "CEO Nights pre-sale (R375)",
};
const STATUS: Record<string, string> = {
  new: "Awaiting payment",
  contacted: "Contacted",
  paid: "Paid, to send",
  fulfilled: "Sent",
  cancelled: "Cancelled",
};
const DELIVERY: Record<string, string> = {
  johannesburg: "Delivery, Johannesburg",
  kzn: "Delivery, KwaZulu-Natal",
  collection: "Collection",
};

const when = (iso: string | null) =>
  iso
    ? new Intl.DateTimeFormat("en-ZA", {
      timeZone: "Africa/Johannesburg",
      day: "numeric",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }).format(new Date(iso))
    : "";

function table(o: Order) {
  const rows: [string, unknown][] = [
    ["Reference", o.order_ref],
    ["Book", BOOK[o.book] ?? o.book],
    ["Status", STATUS[o.status] ?? o.status],
    ["Name", [o.title, o.first_name, o.last_name].filter(Boolean).join(" ")],
    ["Email", o.email],
    ["Phone", o.phone],
    ["Job title", o.job_title],
    ["Industry", o.industry],
    ["Delivery", o.delivery ? DELIVERY[o.delivery] ?? o.delivery : ""],
    ["Address", o.delivery_address],
    ["Signed", o.signed ? `Yes${o.sign_for ? `, for ${o.sign_for}` : ""}` : "No"],
    ["Ordered", when(o.created_at)],
  ];
  return rows
    .filter(([, v]) => v !== null && v !== undefined && v !== "")
    .map(([k, v]) =>
      `<tr><td style="color:#8C8478;padding:4px 14px 4px 0;vertical-align:top">${esc(k)}</td><td style="padding:4px 0">${esc(v)}</td></tr>`
    )
    .join("");
}

async function send(subject: string, heading: string, lead: string, o: Order) {
  const key = env("RESEND_API_KEY"), to = env("NOTIFY_TO"), from = env("NOTIFY_FROM");
  if (!key || !to || !from) throw new Error("Resend secrets not set");
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from,
      to: [to],
      reply_to: o.email,
      subject,
      html: `
        <div style="font-family:Arial,sans-serif;font-size:15px;color:#2A2620">
          <p style="font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:#8C8478;margin:0">${esc(heading)}</p>
          <h2 style="margin:6px 0 8px;color:#051A52">${esc(o.order_ref ?? "Book order")}</h2>
          <p style="margin:0 0 16px">${esc(lead)}</p>
          <table cellpadding="0" style="border-collapse:collapse;font-size:14px">${table(o)}</table>
          <p style="color:#8C8478;font-size:12px;margin-top:22px">
            Manage orders on the website manager. Reply to this email to write to the buyer.
          </p>
        </div>`,
    }),
  });
  if (!res.ok) throw new Error(`resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  let body: { type?: string; record?: Order; old_record?: Order };
  try {
    body = await req.json();
  } catch {
    return new Response("Bad payload", { status: 400 });
  }
  const o = body.record;
  if (!o?.email) return new Response("No order on payload", { status: 400 });
  const name = [o.first_name, o.last_name].filter(Boolean).join(" ");
  const book = BOOK[o.book] ?? o.book;

  try {
    if (body.type === "INSERT") {
      await send(
        `New order ${o.order_ref ?? ""}: ${name}, ${book}`,
        "New book order",
        `${name} filled in the order form and was sent to Yoco to pay. Check Yoco for the payment, then mark the order Paid.`,
        o,
      );
    } else if (body.type === "UPDATE" && body.old_record && body.old_record.status !== o.status) {
      await send(
        `Order ${o.order_ref ?? ""} is now ${STATUS[o.status] ?? o.status}`,
        "Order status changed",
        `${o.status_changed_by ?? "Someone"} changed this order from "${STATUS[body.old_record.status] ?? body.old_record.status}" to "${STATUS[o.status] ?? o.status}" on ${when(o.status_changed_at ?? new Date().toISOString())}.`,
        o,
      );
    } else {
      return new Response(JSON.stringify({ ok: true, sent: false }), { headers: { "Content-Type": "application/json" } });
    }
  } catch (e) {
    console.error("order-notify", o.order_ref, String(e));
    // 200 so the webhook does not retry; the order itself is already saved.
    return new Response(JSON.stringify({ ok: false, error: String(e) }), { headers: { "Content-Type": "application/json" } });
  }

  return new Response(JSON.stringify({ ok: true, sent: true }), { headers: { "Content-Type": "application/json" } });
});
