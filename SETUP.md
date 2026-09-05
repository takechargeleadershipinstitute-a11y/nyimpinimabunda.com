# Waitlist setup

Everything code-side is built. This is the click-by-click for the parts that need
the TCLI accounts.

**Do all of this signed in as the TCLI Gmail, not a personal account.** The whole
point of the account structure is that TCLI owns these outright.

---

## 1. Supabase — the database

**Dashboard → New project**

| Field | Value |
|---|---|
| Name | `nyimpinimabunda` |
| Region | **Frankfurt (eu-central-1)** or Ireland — closest to South Africa |
| Plan | Free |

Then **SQL Editor → New query**, paste the whole of [`supabase/schema.sql`](supabase/schema.sql)
and run it. It creates the `waitlist` table and, critically, a row-level security
policy that lets the public key **insert only**.

> Why that matters: the waitlist page carries the publishable key in its source,
> which is normal and safe — but only because the policy denies select, update and
> delete. Without it, anyone viewing source could download the entire mailing list.

Then **Project Settings → API** and copy two values:

- **Project URL** — `https://xxxx.supabase.co`
- **Publishable / anon key** — the long `eyJ...` one labelled *anon* / *public*

Paste them into `waitlist/index.html`, near the bottom:

```js
var SUPABASE_URL  = 'https://YOUR-PROJECT-REF.supabase.co';
var SUPABASE_ANON = 'YOUR-PUBLISHABLE-ANON-KEY';
```

⚠️ **Do not paste the `service_role` key.** That one bypasses all security and must
never appear in a web page.

---

## 2. beehiiv — the list

**Create a publication.** One publication, not three — the three interests on the
form are stored as tags, which keeps everyone inside the free 2,500 allowance.

Then **Settings → API → Create new API key**, and note the **Publication ID**
(starts `pub_`, in Settings → Publication).

---

## 3. Resend — the notification email

**API Keys → Create API Key**, sending permission only.

Domain verification comes later, with DNS. Until then Resend only sends to the
address that owns the account, which is fine for testing.

---

## 4. Supabase Edge Function — the glue

**Edge Functions → Secrets**, add these six. **Add them yourself; they are
credentials and should not pass through chat.**

| Secret | Value |
|---|---|
| `BEEHIIV_API_KEY` | from step 2 |
| `BEEHIIV_PUBLICATION_ID` | `pub_...` |
| `RESEND_API_KEY` | from step 3 |
| `NOTIFY_TO` | `info@takechargeli.co.za` |
| `NOTIFY_FROM` | `TCLI Waitlist <news@takechargeli.co.za>` |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

Deploy [`supabase/functions/waitlist-sync/index.ts`](supabase/functions/waitlist-sync/index.ts)
— either paste it into **Edge Functions → Deploy a new function**, or:

```bash
supabase functions deploy waitlist-sync
```

Then wire the trigger: **Database → Webhooks → Create a new hook**

| Field | Value |
|---|---|
| Table | `public.waitlist` |
| Events | **Insert** only |
| Type | Supabase Edge Function |
| Function | `waitlist-sync` |

---

## 5. Cloudflare Pages — hosting

**Workers & Pages → Create → Pages → Connect to Git**, pick the repo.

| Setting | Value |
|---|---|
| Build command | *(leave empty)* |
| Build output directory | `/` |
| Framework preset | None |

Pushing to `main` redeploys. The waitlist lives at `/waitlist/`.

---

## 6. DNS — last, needs TCLI's registrar

Blocked until someone at TCLI grants access to `takechargeli.co.za`.

**Send from subdomains, never the root.** `info@` and `bookings@` already work,
which means an SPF record exists on the root — a domain gets exactly one, and
editing it carelessly breaks their live email. Subdomains carry their own and
cannot collide. It also keeps bulk newsletter reputation away from the address
board correspondence goes to.

- beehiiv → `news.takechargeli.co.za`
- Resend → `mail.takechargeli.co.za`

Both dashboards print the exact records once you add the domain.

---

## Testing before DNS

1. Open `/waitlist/`, submit a real address.
2. **Supabase → Table Editor → waitlist** — the row should be there.
3. Check `synced_at`. If it is null, read `sync_error` on the same row; the
   function records what failed rather than dropping the signup.
4. **beehiiv → Subscribers** — the address should have appeared.
5. Check the inbox for the notification.

The function treats beehiiv and Resend independently, so one being down cannot
swallow the other, and the signup is saved either way.

---

## Still outstanding, not part of this build

- **Paystack is still a TEST link.** "Buy the book" opens Paystack's own
  *"Do not share with your customers"* page. It cannot take payment.
- **Meta URLs in `index.html` point at the review deployment.** Repoint on launch.
- **The two Google Form links** in `index.html` should be swapped for `/waitlist/`
  once this is live.
