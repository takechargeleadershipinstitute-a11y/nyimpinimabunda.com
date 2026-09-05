// Waitlist hand-off: Supabase -> beehiiv + Resend
//
// Triggered by a database webhook on INSERT into public.waitlist. Runs
// server-side so the beehiiv and Resend keys never reach the browser.
//
// Two jobs, deliberately independent: if beehiiv is down, TCLI still gets the
// notification email, and vice versa. A partial failure is recorded on the row
// (sync_error) rather than thrown away, so it can be retried.
//
// Secrets required (Dashboard -> Edge Functions -> Secrets):
//   BEEHIIV_API_KEY          from beehiiv -> Settings -> API
//   BEEHIIV_PUBLICATION_ID   the "pub_..." id of the publication
//   RESEND_API_KEY           from resend.com -> API Keys
//   NOTIFY_TO                e.g. info@takechargeli.co.za
//   NOTIFY_FROM              e.g. "TCLI Waitlist <news@takechargeli.co.za>"
//                            must be on a domain verified in Resend
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

interface Row {
  id: string;
  first_name: string;
  last_name: string;
  email: string;
  interests: string[] | null;
  source: string | null;
  created_at: string;
}

const env = (k: string) => Deno.env.get(k) ?? "";

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
   .replace(/"/g, "&quot;");

// ── beehiiv ────────────────────────────────────────────────────────────────
async function addToBeehiiv(row: Row) {
  const pub = env("BEEHIIV_PUBLICATION_ID");
  const key = env("BEEHIIV_API_KEY");
  if (!pub || !key) throw new Error("beehiiv secrets not set");

  const res = await fetch(
    `https://api.beehiiv.com/v2/publications/${pub}/subscriptions`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email: row.email,
        reactivate_existing: true,
        send_welcome_email: true,
        utm_source: row.source ?? "website",
        // One publication, segmented by tag. Cheaper than separate
        // publications and keeps everyone inside the 2,500 free tier.
        custom_fields: [
          { name: "First Name", value: row.first_name },
          { name: "Last Name",  value: row.last_name },
          { name: "Interests",  value: (row.interests ?? []).join(", ") },
        ],
      }),
    },
  );

  if (!res.ok) {
    throw new Error(`beehiiv ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
}

// ── Resend ─────────────────────────────────────────────────────────────────
async function notifyTcli(row: Row) {
  const key = env("RESEND_API_KEY");
  const to = env("NOTIFY_TO");
  const from = env("NOTIFY_FROM");
  if (!key || !to || !from) throw new Error("Resend secrets not set");

  const name = `${row.first_name} ${row.last_name}`.trim();
  const interests = (row.interests ?? []).join(", ") || "not specified";

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: [to],
      // So a reply from TCLI goes to the person who signed up, not into a void.
      reply_to: row.email,
      subject: `Waitlist: ${name}`,
      html: `
        <div style="font-family:Arial,sans-serif;font-size:15px;color:#2A2620">
          <p style="font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:#8C8478">
            New waitlist signup
          </p>
          <h2 style="margin:6px 0 18px;color:#051A52">${esc(name)}</h2>
          <table cellpadding="6" style="border-collapse:collapse;font-size:14px">
            <tr><td style="color:#8C8478">Email</td><td><a href="mailto:${esc(row.email)}">${esc(row.email)}</a></td></tr>
            <tr><td style="color:#8C8478">Interested in</td><td>${esc(interests)}</td></tr>
            <tr><td style="color:#8C8478">Source</td><td>${esc(row.source ?? "website")}</td></tr>
            <tr><td style="color:#8C8478">Signed up</td><td>${esc(row.created_at)}</td></tr>
          </table>
          <p style="color:#8C8478;font-size:12px;margin-top:22px">
            Added to the beehiiv list automatically. Sent by the waitlist on nyimpinimabunda.com.
          </p>
        </div>`,
    }),
  });

  if (!res.ok) {
    throw new Error(`resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
}

// ── mark the row so failures are visible and retryable ─────────────────────
async function stamp(id: string, error: string | null) {
  await fetch(`${env("SUPABASE_URL")}/rest/v1/waitlist?id=eq.${id}`, {
    method: "PATCH",
    headers: {
      apikey: env("SUPABASE_SERVICE_ROLE_KEY"),
      Authorization: `Bearer ${env("SUPABASE_SERVICE_ROLE_KEY")}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({
      synced_at: error ? null : new Date().toISOString(),
      sync_error: error,
    }),
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  let row: Row;
  try {
    const body = await req.json();
    row = body.record ?? body; // database webhook wraps the row in `record`
    if (!row?.email) throw new Error("no email on payload");
  } catch (e) {
    return new Response(`Bad payload: ${e}`, { status: 400 });
  }

  // Independent, so one outage cannot swallow the other.
  const [beehiiv, resend] = await Promise.allSettled([
    addToBeehiiv(row),
    notifyTcli(row),
  ]);

  const errors = [beehiiv, resend]
    .filter((r): r is PromiseRejectedResult => r.status === "rejected")
    .map((r) => String(r.reason));

  await stamp(row.id, errors.length ? errors.join(" | ") : null);

  if (errors.length) {
    console.error("waitlist-sync", row.email, errors);
    // 200 regardless: the signup IS saved, and returning an error here only
    // makes the webhook retry work that partially succeeded. The row carries
    // sync_error for anyone auditing.
  }

  return new Response(
    JSON.stringify({ ok: errors.length === 0, errors }),
    { headers: { "Content-Type": "application/json" } },
  );
});
