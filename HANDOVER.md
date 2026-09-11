# Handover — nyimpinimabunda.com

Everything the Take Charge Leadership Institute needs to own, run and pay for this
site and its mailing list.

**Prepared by** Gerald Louw · **Last updated** 7 September 2026

> ### ⚠️ No passwords or API keys are in this document
> That is deliberate. Secrets do not belong in a file that gets emailed, printed or
> committed to a repository. This document tells you **where each credential lives**
> so the right person can retrieve it. Move the actual values through a password
> manager (1Password, Bitwarden) or hand them over in person — never by email or
> WhatsApp.

---

## 1. The short version

Every service is registered to **one Google account**, created specifically so that
ownership sits with the Institute rather than with any individual. Whoever holds that
Gmail controls everything else, because it is the password-reset address for all five
services.

```
        takechargeleadershipinstitute@gmail.com
                        │
   ┌──────────┬─────────┼─────────┬──────────┐
 GitHub   Cloudflare  Supabase  beehiiv    Resend
  code     hosting    database    list    system mail
```

**Total running cost today: R0/month.** Every service is on a free tier, and none has
a card on file.

---

## 2. Accounts

| # | Service | What it does | Account / identifier | Plan |
|---|---|---|---|---|
| 1 | **Google** | Owns everything below; password resets land here | `takechargeleadershipinstitute@gmail.com` | Free |
| 2 | **GitHub** | Stores the website code | Org `takechargeleadershipinstitute-a11y`, repo `nyimpinimabunda.com` | Free |
| 3 | **Cloudflare** | Hosts the website | Pages project `nyimpinimabunda-com` | Free |
| 4 | **Supabase** | Database behind the waitlist and the CEO Nights book pre-orders | Org "Take Charge Leadership Institute", project `cbbhgoahhykpckbtlzkr` | Free |
| 5 | **beehiiv** | Mailing list and newsletters | Publication "Take Charge's Newsletter"<br>`pub_4cac3614-a9f4-4d2b-9346-d5543f0ca78c` | Max trial → **Launch (free)** |
| 6 | **Resend** | Sends the "someone signed up" alert | API key named `supabase-waitlist` | Free |

### Already owned by TCLI, not created for this project

| Service | Detail |
|---|---|
| **Domain** `takechargeli.co.za` | Nameservers `ns1.tld-ns.net` / `ns2.tld-ns.com`, mail on `mx1.tld-mx.com`. **Registrar login not yet identified — see §6.** |
| **Mailboxes** | `info@takechargeli.co.za`, `bookings@takechargeli.co.za` |
| **Paystack** | Book sales. ⚠️ Still a **test** link, so it cannot take payment yet. Zimasa is also setting up a **Yoco** payment link. Check in with her on how far the Yoco link is, while the Paystack account is still being sorted out |
| **YouTube** | `@ceonightswithnyimpini` |
| **Instagram** | `@nyimpinimabunda`, `@takecharge_li` |
| **LinkedIn** | Nyimpini Mabunda's personal profile |

---

## 3. Where the credentials live

> **Next step.** Gerald will phone Zimasa to go through this section in more detail. On
> **Monday 14 September 2026** he will give her access to all the other services listed
> here, so she has access to everything he has.

| Credential | Where to get it | Who can |
|---|---|---|
| Gmail password | Held by Gerald Louw — **hand over first** | — |
| GitHub, Cloudflare, Supabase, beehiiv, Resend passwords | Password reset via the Gmail | Anyone with the Gmail |
| **beehiiv API key** | Supabase → Edge Functions → Secrets → `BEEHIIV_API_KEY`. Not retrievable from beehiiv again; create a new one if lost | Supabase admin |
| **Resend API key** | Supabase → Edge Functions → Secrets → `RESEND_API_KEY`. Same — create a new one if lost | Supabase admin |
| **Supabase publishable key** | Visible in the page source. **Public by design** — it can only add a waitlist row, never read the list | Anyone |
| **Supabase secret key** | Supabase → Settings → API Keys. **Never put this in a web page** — it bypasses every security rule | Supabase admin |

### The five Edge Function secrets

Supabase → Edge Functions → Secrets:

| Name | Purpose |
|---|---|
| `BEEHIIV_API_KEY` | Adds each signup to the mailing list |
| `BEEHIIV_PUBLICATION_ID` | `pub_4cac3614-a9f4-4d2b-9346-d5543f0ca78c` |
| `RESEND_API_KEY` | Sends the internal alert |
| `NOTIFY_TO` | Who receives the alert. Currently the TCLI Gmail; becomes `info@takechargeli.co.za` once DNS is done |
| `NOTIFY_FROM` | Currently `onboarding@resend.dev`, which **only delivers to the account owner**. Becomes a real address once DNS is done |

---

## 4. How it fits together

```
Visitor fills the form on /waitlist/
        │
        ▼
Supabase  ── stores the row (name, surname, email, interest)
        │
        ▼  database webhook fires on insert
Edge Function "waitlist-sync"
        ├──► beehiiv   adds them to the mailing list
        └──► Resend    emails TCLI that someone joined
```

### Book pre-orders (added 11 September 2026)

```
Visitor clicks "Pre-order the book" → pop-up form
        │  first name, surname, email, contact number, copies, signed yes/no,
        │  terms accepted (and which version of the terms page)
        ▼
Supabase  ── stores the row in public.book_preorders   (status starts as 'new')
```

- **Where to see orders:** Supabase → Table Editor → `book_preorders`, newest first.
- **Track each order with the `status` column:** `new` → `contacted` → `paid` →
  `fulfilled` (or `cancelled`). Change it in the Table Editor. The website itself can
  never set or read it.
- **Every pre-order is saved in Supabase, so nobody is lost.** Each row keeps the
  person's name, email address, contact number, how many copies they want, whether
  they want them signed, and that they accepted the terms (with the date of the terms
  version they saw). Everything on the form is kept. That makes the table a ready-made list: once enough pre-orders
  have been collected, TCLI can export it (Table Editor → Export → CSV) and email
  everyone on it in one go, for example to tell them the book is ready to buy.
- **Before that email goes out, TCLI must prepare a real link to buy the book.** The
  pop-up reserves a copy but takes no payment. Once the payment gateway (Paystack or
  Yoco) is sorted out, create a live payment link for *CEO Nights*, so the email can
  send people straight to pay.
- **No email is sent automatically when a pre-order arrives.** Check the table, or ask
  the developer to add an alert like the waitlist one.
- Schema and security rules: [`supabase/book_preorders.sql`](supabase/book_preorders.sql).
  Like the waitlist, the public key can add an order and do nothing else.

### Gig guide (added 11 September 2026)

The page at `/gig-guide/`, linked from **Upcoming Events**, reads its list straight from
Supabase. **Nobody has to touch the website code to update it.**

- **To add an event:** Supabase → Table Editor → `gig_guide` → **Insert row**. Fill in
  `event_name` and `starts_on` (plus `ends_on` for a multi-day event), and whatever you
  have of `organisation`, `city`, `country` and `link`. Save, and it is on the site.
- **Coming up and Recently sort themselves.** Once an event's last day has passed, it
  moves to "Recently". Nothing needs deleting.
- **`category`** is the small tag shown on each event: Conference, Keynote, CEO Nights,
  Masterclass, Gathering. Keep the spelling consistent so the tags match.
- **Corporate bookings: tick `private`.** The site then shows "Private corporate session"
  with the city only, never the client's name. Untick it once the client is happy to be
  named. The first import marked Nedbank, Capitec, KPMG and Board Partners as private.
- **To hide an event completely,** untick `published`. It disappears from the site but
  stays in the table.
- **The homepage** Upcoming Events card shows the next three dates from the same table,
  and the page adds each public event in the structured format search engines read.
- **Planning details stay private.** `venue`, `theme`, `expected_attendance`, `audience`,
  `dress_code` and `notes` are for TCLI only. The website cannot read those columns, so
  the table can replace the PDF gig guide.
- Schema and security rules: [`supabase/gig_guide.sql`](supabase/gig_guide.sql).

**Pushing code to GitHub `main` redeploys the site automatically.** There is no build
step: the repository contains exactly what is published.

| Page | Address |
|---|---|
| Site | https://nyimpinimabunda-com.pages.dev |
| Waitlist | https://nyimpinimabunda-com.pages.dev/waitlist/ |
| Terms & privacy | https://nyimpinimabunda-com.pages.dev/terms/ |

---

## 5. Handover checklist

- [ ] **Transfer the Gmail** to the Institute — change the password, and set the recovery phone and backup email to someone at TCLI. Everything else follows from this.
- [ ] Turn on **2-factor authentication** on the Gmail and save the recovery codes somewhere that is *not* that inbox.
- [ ] **Remove `geraldlouw89`** as a collaborator on the GitHub repo (Settings → Collaborators) once no further work is needed.
- [ ] Decide whether the repo should be **Private** (currently Public — no secrets in it, but source is visible).
- [ ] **Decommission the old review site** at `nyimpinimabundacom-phi.vercel.app`. It sits on Gerald's personal Vercel account, is still live, and is now out of date.
- [ ] Confirm someone at TCLI can log into all six services.

---

## 6. Open items — none of these are optional before launch

| Item | Detail | Who |
|---|---|---|
| 🔴 **`nyimpinimabunda.com` is not registered** | A public DNS lookup returns *non-existent domain*. The site the whole project is named after has no domain, and anyone can register it. **Register it now.** | TCLI |
| 🔴 **Paystack is a test link** | "Buy the book" opens Paystack's own *"Do not share with your customers"* page. **It cannot take payment.** Replace with the live product link | TCLI |
| 🔴 **DNS access for `takechargeli.co.za`** | Blocks three things at once: connecting the real domain, sending the newsletter from `@takechargeli.co.za`, and system email. Nobody has identified who holds the registrar login | TCLI |
| 🟡 **`nyimpini.com` is registered to someone** | It resolves to `102.211.205.136`. Earlier versions of this site pointed at it, which suggests it was once theirs. Worth establishing who controls it | TCLI |
| 🟡 **Meta tags point at the old review URL** | `canonical`, `og:url` and `og:image` still read `nyimpinimabundacom-phi.vercel.app`. Must be repointed the day the real domain goes live, or Google treats that address as the canonical one | Developer |
| 🟡 **CEO Nights pre-order has no payment route** | The button now opens a pop-up that saves the order to Supabase (`book_preorders`), but nothing is charged. TCLI contacts each person to confirm and take payment | TCLI |
| 🟡 **No alert when a pre-order arrives** | Orders are only visible in Supabase → Table Editor → `book_preorders`. A webhook + email (like `waitlist-sync`) would fix it | Developer |
| 🟡 **"Get your signed copy" has no order route** | Same — currently a pre-filled email | TCLI |
| 🟡 **Terms page is not legally reviewed** | Written around what the site actually does and shaped to POPIA, but **not by a lawyer**. Have TCLI's attorney read it, particularly payments and the filming clause | TCLI |

---

## 7. What it will cost as it grows

| Trigger | Cost |
|---|---|
| Now | **R0** |
| Over 2,500 newsletter subscribers | beehiiv Scale, from ~$43/month |
| Over 3,000 system emails a month | Resend paid, from $20/month |
| Heavy database use | Supabase Pro, $25/month |
| Domain registration | ~R150–R250/year |

Realistically the only one you will hit in the first year is the **domain**.

---

## 8. If something breaks

**Signups stop arriving.** Check Supabase → Table Editor → `waitlist`. If rows are
still appearing, the form is fine and the problem is downstream — look at `sync_error`
on the newest row; it records exactly what failed. If no rows are appearing, check the
site is up.

**No email when someone signs up.** Almost always `NOTIFY_FROM` / `NOTIFY_TO`. Until
the domain is verified in Resend, it will *only* deliver to the account owner's own
address, and anything else fails with a 403 recorded in `sync_error`.

**Site shows an old version.** Check GitHub → Actions or Cloudflare → Deployments for
a failed build. Browsers also cache aggressively; try a hard refresh first.

**A change went wrong.** Every version is in git. `git revert` restores any previous
state, and the site redeploys automatically.

Technical notes and conventions are in `README.md`; step-by-step service setup is in
`SETUP.md`.
