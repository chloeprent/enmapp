// ENM Style quiz: Stripe purchases for the quiz dashboard.
//
// Read-only towards Stripe: it uses STRIPE_API_KEY, a restricted key with read
// access only, and never creates, changes or refunds anything.
//
//   discover  (service role only) summarise products, prices, payment links and
//             how purchases were made, without any customer details, so the
//             product mapping can be confirmed before anything is stored.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const STRIPE = "https://api.stripe.com/v1";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });

async function stripeGet(path: string, params: Record<string, string> = {}): Promise<any> {
  const key = Deno.env.get("STRIPE_API_KEY");
  if (!key) throw new Error("STRIPE_API_KEY is not set");
  const qs = new URLSearchParams(params).toString();
  const res = await fetch(`${STRIPE}${path}${qs ? `?${qs}` : ""}`, { headers: { Authorization: `Bearer ${key}` } });
  const body = await res.json();
  if (!res.ok) throw new Error(`Stripe ${path}: ${body?.error?.message || res.status}`);
  return body;
}

// Walks a Stripe list endpoint, newest first, up to `max` items.
async function stripeList(path: string, params: Record<string, string> = {}, max = 2000): Promise<any[]> {
  const out: any[] = [];
  let after = "";
  while (out.length < max) {
    const page = await stripeGet(path, { limit: "100", ...params, ...(after ? { starting_after: after } : {}) });
    out.push(...page.data);
    if (!page.has_more || !page.data.length) break;
    after = page.data[page.data.length - 1].id;
  }
  return out;
}

function isServiceRole(req: Request): boolean {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return !!token && !!service && token === service;
}

const day = (unix: number) => new Date(unix * 1000).toISOString().slice(0, 10);

async function discover() {
  const key = Deno.env.get("STRIPE_API_KEY") || "";
  const mode = key.startsWith("rk_live_") || key.startsWith("sk_live_") ? "live"
    : key.startsWith("rk_test_") || key.startsWith("sk_test_") ? "test" : "unknown";

  const [products, prices, links] = await Promise.all([
    stripeList("/products", {}, 500),
    stripeList("/prices", {}, 1000),
    stripeList("/payment_links", {}, 200),
  ]);
  const productName = new Map(products.map((p) => [p.id, p.name]));

  const paymentLinks = [];
  for (const l of links) {
    const items = await stripeGet(`/payment_links/${l.id}/line_items`, { limit: "20" });
    paymentLinks.push({
      id: l.id, active: l.active, url: l.url,
      items: items.data.map((i: any) => `${productName.get(i.price?.product) || i.description} (${(i.price?.unit_amount ?? 0) / 100} ${i.currency})`),
    });
  }

  // Completed checkouts, grouped by product and by payment link. Counts only.
  const sessions = await stripeList("/checkout/sessions", { status: "complete", "expand[]": "data.line_items" }, 3000);
  const byProduct: Record<string, { count: number; first: string; last: string }> = {};
  const byLink: Record<string, number> = {};
  const sessionIntents = new Set<string>();
  for (const s of sessions) {
    if (s.payment_intent) sessionIntents.add(typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent.id);
    byLink[s.payment_link || "(no payment link)"] = (byLink[s.payment_link || "(no payment link)"] || 0) + 1;
    for (const i of s.line_items?.data || []) {
      const name = productName.get(i.price?.product) || i.description || "(unknown)";
      const row = byProduct[name] ||= { count: 0, first: day(s.created), last: day(s.created) };
      row.count++;
      if (day(s.created) < row.first) row.first = day(s.created);
      if (day(s.created) > row.last) row.last = day(s.created);
    }
  }

  // Successful charges that did not come from a Checkout Session (for example a
  // Squarespace store or invoices). Counted by where they came from, no details.
  const charges = await stripeList("/charges", {}, 3000);
  const other: Record<string, number> = {};
  let paid = 0, refunded = 0;
  for (const c of charges) {
    if (c.status !== "succeeded") continue;
    paid++;
    if (c.refunded || c.amount_refunded > 0) refunded++;
    if (c.payment_intent && sessionIntents.has(c.payment_intent)) continue;
    const where = c.application ? `connected app ${c.application}`
      : c.invoice ? "invoice"
      : `other (${c.calculated_statement_descriptor || "no descriptor"})`;
    other[where] = (other[where] || 0) + 1;
  }

  return {
    mode,
    products: products.map((p) => ({ id: p.id, name: p.name, active: p.active })),
    prices: prices.map((p) => ({
      product: productName.get(p.product) || p.product, amount: (p.unit_amount ?? 0) / 100,
      currency: p.currency, recurring: !!p.recurring, active: p.active,
    })),
    payment_links: paymentLinks,
    checkouts: { completed: sessions.length, by_product: byProduct, by_payment_link: byLink },
    charges: { succeeded: paid, with_refund: refunded, not_from_checkout: other },
  };
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: any = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { /* not JSON */ }

  if (body.action === "discover") {
    if (!isServiceRole(req)) return json({ error: "Not allowed" }, 401);
    try { return json(await discover()); } catch (e) { return json({ error: String((e as Error).message) }, 500); }
  }

  return json({ error: "Unknown request" }, 400);
});
