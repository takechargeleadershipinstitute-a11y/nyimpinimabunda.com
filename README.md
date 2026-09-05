# nyimpinimabunda.com

Personal-brand site for **Nyimpini Mabunda** — board chairman, author, executive coach
and host of *CEO Nights* — for the Take Charge Leadership Institute (TCLI).

## What this is

A single static page. `index.html` contains the markup, an inline `<style>` block and an
inline `<script>` block. There is **no build step, no framework and no dependencies** —
what is in the repo is exactly what ships.

```
index.html        the entire site
assets/           images, logos, episode thumbnails, sponsor marks
.vercelignore     working files excluded from deploys
```

Every image is served as WebP with a PNG/JPG fallback via `<picture>`.

## Deploying

The site is static, so any static host works. Cloudflare Pages is the intended home:

| Setting | Value |
|---|---|
| Build command | *(none)* |
| Build output directory | `/` |
| Framework preset | None |

Pushing to `main` redeploys.

## Conventions worth knowing

**Image swaps use a new filename.** `hero-cutout-2.png`, `portrait-cutout-4.png`,
`ceo-nights-book-1.png`. Browsers cache aggressively by URL, and replacing a file in place
leads to "you haven't changed it yet" reports when the change is in fact live. Bump the
number, update both the `<source srcset>` and the `<img src>`, and delete the old file so
nothing can silently fall back to it.

**No em dashes in visitor-facing copy.** A client requirement (Sept 2026). Use a colon
where the second half explains the first, a full stop where it is a separate thought, a
comma for an aside. Em dashes in CSS/JS comments are fine — they never render.

**Brand palette** is defined once in `:root` per the NM Brand Guidelines v1.0:
Signature Navy `#051A52`, Charge Gold `#D4AD66`, Ivory Canvas `#FAF6EF`.
Body copy uses `#6B6459` rather than brand Stone `#8C8478`, because Stone on ivory is
only 3.43:1 and fails WCAG AA.

## Before this goes public

- [ ] **Paystack link is still a TEST link.** "Buy the book" opens Paystack's own
      *"Do not share with your customers"* page. It cannot take payment. Replace with the
      live product link.
- [ ] **Absolute URLs in `<head>` point at the review deployment**, not the real domain.
      `canonical`, `og:url`, `og:image`, `twitter:image` and the JSON-LD `url` all read
      `https://nyimpinimabundacom-phi.vercel.app`. Repoint them the moment the real
      domain is live, or Google will treat that address as canonical.
- [ ] **Waitlist forms** currently point at two Google Forms. To be replaced by the
      self-hosted waitlist page (Supabase + beehiiv).
- [ ] Verify every link on the live site, not just in markup. Note that `youtu.be`
      returns 204 to HEAD (fine) and the `preconnect` font hosts return 404 (also fine).
- [ ] Scroll the whole page in a real browser — `loading="lazy"` images never start
      loading otherwise, so a check of `img.complete` reports false breakage.

## Credits

Photography supplied by TCLI. Book cover artwork by the publisher.
