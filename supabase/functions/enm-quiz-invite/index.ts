// ENM Style quiz: partner invites and Kit sync.
//
// Three actions, all public, all narrow:
//
//   send    a taker who has just finished gives their partner's email; we mint
//           a token, mail the invite, and remember who invited whom
//   redeem  the partner finishes their own run via that link; we cross-link the
//           two leads so the pair can be read as one couple
//   kit     every taker, once their result is saved; we upsert them in Kit with
//           their top 3 results as custom fields and tag them for the 1st only
//
// Cross-linking needs an UPDATE, and the anon role deliberately has INSERT-only
// rights on enm_quiz_leads, so it has to happen here under the service role.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import { corsHeaders } from "../_shared/api-helpers.ts";

const QUIZ_URL = "https://swoon-quiz.pages.dev/";
const FROM = "Swoon Quiz <quiz@swoon.coach>";
const COVER_IMG = `${QUIZ_URL}img/cover-e13e86.jpg`;
const LOGO_IMG = `${QUIZ_URL}img/swoon-logo.png`;

const db = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const isEmail = (v: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v);
const esc = (v: string) =>
  v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Quiz result title -> Kit tag id. Only the 1st result is ever tagged.
const KIT_STYLES: { name: string; tagId: number }[] = [
  { name: "Open Relationship", tagId: 21549291 },
  { name: "Swinging / The Lifestyle", tagId: 22378254 },
  { name: "Hotwife / Stag & Vixen", tagId: 22378256 },
  { name: "Cuckolding", tagId: 22378259 },
  { name: "Polyamory", tagId: 22378263 },
  { name: "Hierarchical Polyamory", tagId: 22378269 },
  { name: "Solo Polyamory", tagId: 22378274 },
  { name: "Relationship Anarchy", tagId: 22378276 },
  { name: "Monogamish", tagId: 22378284 },
  { name: "Mono/Poly", tagId: 22378287 },
  { name: "Still Exploring", tagId: 22378288 },
];

// The quiz titles "Still Exploring" with a long tail, so match on prefix too.
const kitStyle = (title: string) =>
  KIT_STYLES.find((s) => title === s.name) ?? KIT_STYLES.find((s) => title.startsWith(s.name));

async function kitFetch(path: string, body: unknown) {
  const key = Deno.env.get("KIT_API_KEY");
  if (!key) throw new Error("KIT_API_KEY not configured");

  const res = await fetch(`https://api.kit.com/v4${path}`, {
    method: "POST",
    headers: { "X-Kit-Api-Key": key, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Kit ${path} ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return await res.json();
}

async function syncToKit(email: string, firstName: string | null, results: string[]) {
  // Short style names where we know them, so fields read the same as the tags.
  const names = results.map((t) => kitStyle(t)?.name ?? t);

  // POST /subscribers is an upsert keyed on email. Unused slots are sent empty
  // so a retake with fewer results clears what an earlier run left behind.
  await kitFetch("/subscribers", {
    email_address: email,
    first_name: firstName ?? undefined,
    fields: {
      enm_quiz_result: names[0] ?? "",
      enm_quiz_result_2: names[1] ?? "",
      enm_quiz_result_3: names[2] ?? "",
    },
  });

  const style = results[0] ? kitStyle(results[0]) : undefined;
  if (style) {
    await kitFetch(`/tags/${style.tagId}/subscribers`, { email_address: email });
  } else if (results[0]) {
    console.error("kit: no tag mapped for result", results[0]);
  }
}

async function sendMail(to: string, subject: string, html: string, text: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) throw new Error("RESEND_API_KEY not configured");

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html, text }),
  });
  if (!res.ok) throw new Error(`Resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return await res.json();
}

function inviteEmail(inviterName: string | null, link: string) {
  const who = inviterName ? esc(inviterName) : "Someone you know";
  const text =
    `${inviterName ?? "Someone you know"} just took the ENM Style quiz and asked us to send you your own copy.\n\n` +
    `It is 15 questions, it is judgement-free, and your answers are your own, they do not see them ` +
    `unless you choose to share.\n\nTake it here: ${link}\n\n` +
    `If this is not something you want, you can ignore this email and we will not write again.`;

  // Table layout and inline styles only: that is what email apps reliably render.
  const font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";
  const html = `<div style="margin:0;padding:28px 12px;background:#f8f3f1;font-family:${font};color:#3c3c3c">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:20px;border:1px solid #f1dcdd">
    <tr><td align="center" style="padding:26px 28px 6px">
      <img src="${LOGO_IMG}" alt="Swoon" width="112" style="display:block;width:112px;height:auto;border:0">
    </td></tr>
    <tr><td style="padding:14px 24px 0">
      <a href="${esc(link)}" style="display:block"><img src="${COVER_IMG}" alt="What's your ENM style?" width="512" style="display:block;width:100%;max-width:512px;height:auto;border:0;border-radius:16px"></a>
    </td></tr>
    <tr><td align="center" style="padding:26px 32px 4px">
      <h1 style="margin:0 0 14px;font-size:23px;line-height:1.3;font-weight:700;color:#1c1212">${who} invited you to take the ENM Style quiz</h1>
      <p style="margin:0 0 12px;font-size:15.5px;line-height:1.6">It is 15 questions and it is judgement-free. Your answers are your own, they do not see them unless you choose to share.</p>
      <p style="margin:0;font-size:15.5px;line-height:1.6">When you are done, the two of you can compare where you actually line up, and where you do not.</p>
    </td></tr>
    <tr><td align="center" style="padding:26px 32px 30px">
      <a href="${esc(link)}" style="display:inline-block;background:#fc6a77;color:#ffffff;text-decoration:none;font-size:16px;font-weight:700;padding:14px 34px;border-radius:999px">Take the quiz</a>
    </td></tr>
  </table>
  <p style="max-width:520px;margin:18px auto 0;text-align:center;font-size:12px;line-height:1.5;color:#9a8a8a">If this is not something you want, ignore this email and we will not write again.</p>
</div>`;

  return { html, text };
}

async function actionSend(payload: any) {
  const runId = payload?.run_id;
  const partnerEmail = String(payload?.partner_email ?? "").trim().toLowerCase();
  if (!runId) return { status: 400, body: { error: "run_id required" } };
  if (!isEmail(partnerEmail)) return { status: 400, body: { error: "A valid partner email is required" } };

  const client = db();
  const { data: session } = await client
    .from("enm_quiz_sessions").select("id, lead_id").eq("run_id", runId).maybeSingle();
  if (!session?.lead_id) return { status: 404, body: { error: "Session not found" } };

  const { data: lead } = await client
    .from("enm_quiz_leads").select("id, email, first_name, invite_token")
    .eq("id", session.lead_id).maybeSingle();
  if (!lead) return { status: 404, body: { error: "Lead not found" } };

  // Don't let someone invite themselves into a self-partnership.
  if (lead.email?.toLowerCase() === partnerEmail) {
    return { status: 400, body: { error: "That is your own address" } };
  }

  const token = lead.invite_token ?? crypto.randomUUID().replace(/-/g, "");
  const link = `${QUIZ_URL}?invite=${token}`;

  await client.from("enm_quiz_leads").update({
    partner_email: partnerEmail,
    invite_token: token,
    invite_sent_at: new Date().toISOString(),
  }).eq("id", lead.id);

  try {
    const { html, text } = inviteEmail(lead.first_name, link);
    await sendMail(
      partnerEmail,
      `${lead.first_name ?? "Someone"} invited you to take the ENM Style quiz`,
      html,
      text,
    );
  } catch (e) {
    console.error("invite send failed", e);
    return { status: 502, body: { error: "Could not send the invite just now" } };
  }

  return { status: 200, body: { sent: true, partner_email: partnerEmail } };
}

async function actionKit(payload: any) {
  const runId = payload?.run_id;
  if (!runId) return { status: 400, body: { error: "run_id required" } };

  // Email and name come from the saved lead, not the request, so this can only
  // subscribe someone who actually finished the quiz.
  const client = db();
  const { data: session } = await client
    .from("enm_quiz_sessions").select("lead_id, top_results").eq("run_id", runId).maybeSingle();
  if (!session?.lead_id) return { status: 404, body: { error: "Session not found" } };

  const { data: lead } = await client
    .from("enm_quiz_leads").select("email, first_name").eq("id", session.lead_id).maybeSingle();
  if (!lead?.email) return { status: 404, body: { error: "Lead not found" } };

  const passed = Array.isArray(payload?.results) ? payload.results : null;
  const saved = Array.isArray(session.top_results) ? session.top_results.map((r: any) => r?.title) : [];
  const results = ((passed ?? saved) as unknown[])
    .filter((t): t is string => typeof t === "string" && t.trim() !== "")
    .map((t) => t.trim().slice(0, 200))
    .slice(0, 3);

  // Kit is a side channel: a failure is logged, never surfaced to the taker.
  try {
    await syncToKit(lead.email, lead.first_name, results);
  } catch (e) {
    console.error("kit sync failed", e);
    return { status: 200, body: { kit: false } };
  }

  return { status: 200, body: { kit: true } };
}

async function actionRedeem(payload: any) {
  const token = String(payload?.invite_token ?? "").trim();
  const runId = payload?.run_id;
  if (!token || !runId) return { status: 400, body: { error: "invite_token and run_id required" } };

  const client = db();
  const { data: inviter } = await client
    .from("enm_quiz_leads").select("id, partner_lead_id").eq("invite_token", token).maybeSingle();
  if (!inviter) return { status: 404, body: { error: "Unknown invite" } };

  const { data: session } = await client
    .from("enm_quiz_sessions").select("lead_id").eq("run_id", runId).maybeSingle();
  if (!session?.lead_id) return { status: 404, body: { error: "Session not found" } };
  if (session.lead_id === inviter.id) return { status: 400, body: { error: "That is the same person" } };

  const now = new Date().toISOString();
  await client.from("enm_quiz_leads").update({
    partner_lead_id: session.lead_id, partner_linked_at: now,
  }).eq("id", inviter.id);
  await client.from("enm_quiz_leads").update({
    partner_lead_id: inviter.id, invited_by_lead_id: inviter.id, partner_linked_at: now,
  }).eq("id", session.lead_id);

  return { status: 200, body: { linked: true } };
}

serve(async (req: Request) => {
  const cors = { ...corsHeaders, "Content-Type": "application/json" };
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const payload = await req.json();
    const action = String(payload?.action ?? "");
    const result = action === "send"
      ? await actionSend(payload)
      : action === "redeem"
      ? await actionRedeem(payload)
      : action === "kit"
      ? await actionKit(payload)
      : { status: 400, body: { error: `Unknown action: ${action}` } };

    return new Response(JSON.stringify(result.body), { status: result.status, headers: cors });
  } catch (e) {
    console.error("enm-quiz-invite failed", e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: cors });
  }
});
