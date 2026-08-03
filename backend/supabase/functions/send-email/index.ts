// POST /functions/v1/send-email  { to, template, data }
// Transactional mail via Resend. Callers: the entitlements DB trigger
// (welcome_pro) and future server-side flows — NEVER the client app.
// Auth: x-email-secret must match EMAIL_WEBHOOK_SECRET (set as an EF secret;
// the DB trigger reads the same value from private.app_config).
import { json, preflight } from "../_shared/http.ts";

const BRAND = { ink: "#0A0A0A", sig: "#2E5BFF", bg: "#F7F7F5" };

const welcomePro = (data: Record<string, string>) => ({
  subject: "Welcome to Looktok Pro",
  html: `
  <div style="background:${BRAND.bg};padding:40px 16px;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
    <div style="max-width:520px;margin:0 auto;background:#fff;border-radius:20px;padding:40px 36px">
      <p style="font-size:13px;font-weight:800;letter-spacing:.12em;color:${BRAND.sig};margin:0 0 18px;text-transform:uppercase">Looktok Pro</p>
      <h1 style="font-size:30px;line-height:1.15;letter-spacing:-.02em;color:${BRAND.ink};margin:0 0 14px">You're in.<br>Unlimited honest style.</h1>
      <p style="font-size:15px;line-height:1.6;color:#5C5C57;margin:0 0 22px">
        Your account now has unlimited reviews and looks, instant tucked / untucked renders,
        and shoppable pieces from partner brands${data.source?.startsWith("promo:") ? " — unlocked with your founder code" : ""}.
      </p>
      <p style="font-size:15px;line-height:1.6;color:#5C5C57;margin:0 0 28px">
        Open the app, drop in a photo, and let it tell you the truth.
      </p>
      <p style="font-size:12px;color:#9B9B94;margin:0">— The Looktok team</p>
    </div>
  </div>`,
});

const TEMPLATES: Record<string, (d: Record<string, string>) => { subject: string; html: string }> = {
  welcome_pro: welcomePro,
};

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("EMAIL_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-email-secret") !== secret) {
    return json({ error: "forbidden" }, 403);
  }

  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) return json({ error: "resend_key_missing" }, 503); // wired, waiting for the key

  const { to, template, data } = await req.json().catch(() => ({}));
  const tpl = TEMPLATES[String(template ?? "")];
  if (!to || !tpl) return json({ error: "bad_payload" }, 400);

  const { subject, html } = tpl((data ?? {}) as Record<string, string>);
  const from = Deno.env.get("EMAIL_FROM") ?? "Looktok <onboarding@resend.dev>";
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [String(to)], subject, html }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.error("[send-email]", res.status, JSON.stringify(body));
    return json({ error: "resend_failed", status: res.status }, 502);
  }
  return json({ ok: true, id: body.id });
});
