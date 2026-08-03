// POST /functions/v1/generate-look  { photoPath, event(occasion) }
// Flow 2 look-gen — ASYNC FAN-OUT DISPATCHER (migration 0010). The 3-2-2
// planner (text-only, fast) lays out the set; then instead of rendering
// serially in this request (old path: 30–90s blocking call, one timeout kills
// the whole set), the dispatcher inserts one look_renders row per look
// (status=pending), fires one render-look worker invocation per row WITHOUT
// awaiting, and returns the row ids immediately (202). Workers flip their rows
// completed/failed; the Flutter client subscribes to the rows over Supabase
// Realtime and updates each card independently. The last worker to finish
// finalizes the parent generations row and burns the single per-set credit.
import { admin, canAnalyze, entitlementView, getEntitlement, getUser, signedUrl } from "../_shared/supabase.ts";
import { fetchInline, type PlannedLook } from "../_shared/gemini.ts";
import { planLooks } from "../_shared/vision.ts";
import { buildCanonicalAvatar } from "../_shared/avatar.ts";
import { matchRealGarment } from "../_shared/affiliate.ts";
import { markRenderFailed } from "../_shared/renders.ts";
import { json, preflight } from "../_shared/http.ts";

// Tier quotas: inspiration, wardrobe_mix, affiliate. Cost lever (renders/op).
// Wardrobe tier = 0 by owner decision (2026-07-10): mixing owned pieces into
// generated looks "wrecks the picture" — Generate is fresh items ONLY, precisely
// aimed at the occasion, plus two branded looks. Closet mode still exists for
// the explicit "my clothes" flow.
function tierQuotas(): { inspiration: number; wardrobe: number; affiliate: number } {
  const [i, w, a] = (Deno.env.get("LOOK_TIERS") ?? "3,0,2").split(",").map((x) => Math.max(0, Math.min(4, Number(x) || 0)));
  return { inspiration: i ?? 3, wardrobe: w ?? 0, affiliate: a ?? 2 };
}

// Fallback directions (planner failure / closet mode variant count).
const VARIANTS = [
  "Aim for a timeless, refined take with a calm neutral palette.",
  "Aim for a bolder take with a stronger colour or contrast.",
  "Aim for a relaxed, laid-back interpretation.",
];

// Which body area each wardrobe category dresses. 'dress' covers top+bottom
// at once. Anything unmapped is treated as an accessory (never essential).
const CATEGORY_TO_SLOT: Record<string, string> = {
  top: "top", shirt: "top", tee: "top", knit: "top", sweater: "top",
  bottom: "bottom", pants: "bottom", trousers: "bottom", jeans: "bottom",
  shorts: "bottom", skirt: "bottom",
  dress: "dress",
  shoes: "shoes", footwear: "shoes", sneakers: "shoes", boots: "shoes",
  outerwear: "outerwear", jacket: "outerwear", coat: "outerwear", blazer: "outerwear",
};

// The slots a complete look needs covered. A 'dress' satisfies top+bottom.
const ESSENTIAL_SLOTS = ["top", "bottom", "shoes"];

type ClosetItem = { label: string; category: string; image_path: string | null };

/** Closet plan for ONE variant: the exact owned pieces to wear, the wardrobe
 * image paths to ground the render on, and the essential slots the wardrobe
 * can't cover (rendered by keeping the person's own garment — never invented). */
function planCloset(items: ClosetItem[], dir: string, occasion: string): {
  garments: string[];
  reference_paths: string[];
  wardrobe_used: string[];
  kept_from_photo: string[];
} {
  const bySlot = new Map<string, ClosetItem[]>();
  for (const it of items) {
    const slot = CATEGORY_TO_SLOT[(it.category ?? "").toLowerCase().trim()] ?? "accessory";
    (bySlot.get(slot) ?? bySlot.set(slot, []).get(slot)!).push(it);
  }
  const hasDress = (bySlot.get("dress") ?? []).length > 0;
  const covered = new Set<string>();
  if (hasDress) { covered.add("top"); covered.add("bottom"); }
  for (const s of ["top", "bottom", "shoes", "outerwear"]) {
    if ((bySlot.get(s) ?? []).length > 0) covered.add(s);
  }
  // Pick one owned piece per essential slot (or the dress). Cheap rotation by
  // variant index keeps the three cards distinct when the closet is deep.
  const pieces: ClosetItem[] = [];
  const pickFrom = (slot: string, i: number) => {
    const list = bySlot.get(slot) ?? [];
    if (list.length) pieces.push(list[i % list.length]);
  };
  const vi = VARIANTS.indexOf(dir);
  if (hasDress) {
    pickFrom("dress", vi < 0 ? 0 : vi);
  } else {
    pickFrom("top", vi < 0 ? 0 : vi);
    pickFrom("bottom", vi < 0 ? 0 : vi);
  }
  pickFrom("shoes", vi < 0 ? 0 : vi);
  if ((bySlot.get("outerwear") ?? []).length) pickFrom("outerwear", vi < 0 ? 0 : vi);

  const garments = pieces.map((p) => `${p.label} (${CATEGORY_TO_SLOT[(p.category ?? "").toLowerCase().trim()] ?? "accessory"})`);
  const reference_paths = pieces.map((p) => p.image_path).filter((p): p is string => !!p);
  const kept_from_photo = ESSENTIAL_SLOTS.filter((s) => !covered.has(s));
  return {
    garments,
    reference_paths,
    wardrobe_used: pieces.map((p) => p.label),
    kept_from_photo,
  };
}

/** Closet render prompt: the reference images ARE the exact owned garments —
 * reproduce them faithfully (never reinterpret a tee as a shirt), and for any
 * body area the wardrobe doesn't cover, KEEP the person's own garment from the
 * source photo. Nothing is ever invented. */
function closetPrompt(garments: string[], keptFromPhoto: string[], occasion: string, fit: string, gender?: string): string {
  const keepClause = keptFromPhoto.length
    ? `The person owns NOTHING for these slots: ${keptFromPhoto.join(", ")}. For each of those, KEEP EXACTLY what the person already wears in the source photo — same garment, same colour, same shoes — do NOT invent, add, replace or restyle anything there. `
    : "";
  return [
    `Dress the person in this photo for "${occasion}" using ONLY their own clothes.`,
    `The attached reference images after the person are the EXACT garments they own — reproduce each one faithfully on the person: same type, cut, colour, pattern, sleeve length and fabric. A striped t-shirt stays a striped t-shirt; never reinterpret it as a shirt, polo or any other garment. The owned pieces to wear: ${garments.join("; ")}.`,
    "Do NOT add, invent or substitute ANY garment or accessory that is not in this owned list or already worn in the photo — no extra shoes, jackets, hats, belts or bags.",
    keepClause,
    gender && gender !== "neutral"
      ? `The person presents ${gender.toUpperCase()}; keep every piece ${gender}-appropriate.`
      : "",
    fit,
    IDENTITY,
  ].filter(Boolean).join(" ");
}

const IDENTITY =
  "Keep their face, hair, body, pose and identity completely unchanged — only change the clothing. " +
  "BACKGROUND — REBUILD FROM SCRATCH (critical): DISCARD the input photo's background ENTIRELY. Do NOT keep, " +
  "blur or feather ANY part of the original scene — no wall/floor patches, no grey rectangles or smudges " +
  "behind or beside the person, no cutout halos or fuzzy matte clouds (especially above the head/hair and " +
  "between the arms and torso). The ENTIRE frame behind and around the person must be ONE flat, uniform, " +
  "seamless PURE-WHITE (#FFFFFF) — corner to corner, edge to edge. Any leftover fragment of the original " +
  "background is a FAILED generation. " +
  "Base fabric weight and layering on what is VISIBLE in the photo and the stated occasion. " +
  "Photorealistic, full-body head-to-toe framing filling the frame, on a plain seamless pure-white (#FFFFFF) " +
  "studio background, soft even lighting. No logos, no brand names visible as text, no text, no watermarks.";

function fitLine(bodyType: string | null, proportionDesc: string | null): string {
  return [
    bodyType ? `Choose cuts and proportions that flatter a ${bodyType.replace(/_/g, " ")} build.` : "",
    proportionDesc ? `Their proportions: ${proportionDesc}.` : "",
  ].filter(Boolean).join(" ");
}

function lookPrompt(look: PlannedLook, occasion: string, fit: string, skuMandates: string[] = [], gender?: string): string {
  return [
    `Restyle the person in this photo into "${look.title}" for "${occasion}" — dress them in: ${look.garments.join("; ")}.`,
    gender && gender !== "neutral"
      ? `GENDER LOCK (absolute, overrides any garment description): the person presents ${gender.toUpperCase()}. Every rendered piece must be ${gender}-appropriate. ${
        gender === "masculine"
          ? "Rendering a dress, skirt, camisole, spaghetti-strap top, blouse or heels on them is a FAILED generation — if a description could be read as womenswear, render its closest menswear equivalent instead."
          : "Rendering menswear-only pieces on them is a FAILED generation — if a description could be read as menswear, render its closest womenswear equivalent instead."
      }`
      : "",
    skuMandates.length
      ? `EXACT SKUs (these are real purchasable products the user will see side-by-side with this render — geometry, fabric and color MUST match): ${skuMandates.join("; ")}.`
      : "",
    // ATTRIBUTE PARITY (binding): the carousel shows the exact SKU the user
    // picked — the render must not quietly swap a long-sleeve linen shirt for
    // a short-sleeve one. Every stated attribute is a hard requirement.
    "GENDER CONSISTENCY: every garment must match the person's gender presentation as visible in the photo — never dress a masculine-presenting person in womenswear (dress, skirt, blouse) or vice versa.",
    "MENTAL UNDRESS: the person's current clothes are ALREADY REMOVED — dress the described garments onto a neutral body; the outgoing pieces' necklines, sleeve lengths and silhouettes must leave NO trace.",
    "ATTRIBUTE PARITY: reproduce EVERY attribute stated in each garment description literally — sleeve length, fabric, color, fit, garment length, closure. If a piece says long-sleeve, render LONG sleeves; never substitute a different cut, material or colorway.",
    fit,
    IDENTITY,
  ].filter(Boolean).join(" ");
}

/** Code-side quota enforcement — the model's tiers are suggestions until they
 * pass this. Shortfalls top up from leftover looks so the set stays full. */
function enforceQuotas(looks: PlannedLook[], q: { inspiration: number; wardrobe: number; affiliate: number }, hasWardrobe: boolean, hasAffiliate: boolean): PlannedLook[] {
  const insp = looks.filter((l) => l.tier === "inspiration");
  const ward = hasWardrobe ? looks.filter((l) => l.tier === "wardrobe_mix" && (l.wardrobe_used ?? []).length > 0) : [];
  const aff = hasAffiliate ? looks.filter((l) => l.tier === "affiliate" && (l.affiliate_ids ?? []).length > 0) : [];
  const out: PlannedLook[] = [
    ...insp.slice(0, q.inspiration),
    ...ward.slice(0, q.wardrobe),
    ...aff.slice(0, q.affiliate),
  ];
  const total = q.inspiration + q.wardrobe + q.affiliate;
  const leftovers = looks.filter((l) => !out.includes(l));
  while (out.length < total && leftovers.length) out.push({ ...leftovers.shift()!, tier: "inspiration" });
  if (out.length < total) console.log(`[generate-look] plan shortfall: ${out.length}/${total}`);
  return out;
}

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { photoPath, event, source, subject } = await req.json().catch(() => ({}));
  if (!photoPath || !String(photoPath).startsWith(`${user.id}/`)) {
    return json({ error: "valid photoPath (own folder) required" }, 400);
  }
  const occasion = (event ?? "Casual").toString();
  const guest = subject && typeof subject === "object" && Object.keys(subject).length > 0;

  const ent = await getEntitlement(db, user.id);
  // canAnalyze() — NOT a bare FREE_QUOTA compare: this path used to ignore
  // bonus_tokens, so a user who redeemed BETA3X was let into every other flow
  // and refused here alone.
  if (!canAnalyze(ent)) return json({ error: "quota_exhausted", ...entitlementView(ent) }, 402);

  // Wardrobe — planner input (labels), and the STRICT source in closet mode
  // (labels + category + the garment's own image, used to ground the render).
  const { data: items } = await db.from("wardrobe_items")
    .select("label, category, image_path").eq("user_id", user.id);
  const wardrobe = (items ?? []).map((i: { label?: string; category?: string }) => i.label || i.category || "item").filter(Boolean);
  if (source === "closet" && wardrobe.length === 0) return json({ error: "closet_empty" }, 409);

  // Affiliate catalogue (global, active) — planner input for the affiliate tier.
  const { data: affRows } = await db.from("affiliate_items")
    .select("id, brand_name, name, category, price, currency, buy_url, image_url, attributes, gender")
    .eq("active", true).limit(80);
  const affById = new Map((affRows ?? []).map((a) => [a.id as string, a]));

  /** Attribute-parity mandate for a planner-attached SKU: turn structured
   * attributes into an explicit prompt line ("long-sleeve corduroy overshirt")
   * so the render can't hallucinate clothing geometry. */
  const skuMandate = (id: string): string | null => {
    const a = affById.get(id);
    if (!a) return null;
    const at = ((a.attributes ?? {}) as Record<string, string>);
    const bits = [
      at.sleeve_length && at.sleeve_length !== "na" ? `${at.sleeve_length}-sleeve` : null,
      at.color && at.color !== "na" ? at.color : null,
      at.fabric && at.fabric !== "na" ? at.fabric : null,
    ].filter(Boolean).join(" ");
    return `${a.brand_name} ${a.name}${bits ? ` (${bits} — render these attributes EXACTLY)` : ""}`;
  };
  const catalogue = (affRows ?? []).map((a) => ({
    id: a.id as string, brand: a.brand_name as string, name: a.name as string, category: a.category as string,
    gender: (a.gender as string) ?? "unisex",
  }));

  // Grounded seasonal trends → the planner speaks this season's language
  // instead of inventing generic (or plain weird) outfits.
  const { data: trendRows } = await db.from("trend_insights")
    .select("aesthetic_tag, summary")
    .order("captured_at", { ascending: false })
    .limit(5);
  const trends = (trendRows ?? []).map((t) => `${t.aesthetic_tag}: ${t.summary}`);

  const sp = guest
    ? subject
    : (await db.from("style_profiles").select("body_type, proportions, style_dna").eq("user_id", user.id).maybeSingle()).data;
  const bodyType = sp?.body_type ?? null;
  const proportionDesc = (sp?.proportions as { description?: string } | null)?.description ?? null;
  const styleDna = (sp as { style_dna?: unknown } | null)?.style_dna ?? null;
  const fit = fitLine(bodyType, proportionDesc);

  const { data: gen, error: insErr } = await db.from("generations")
    .insert({ user_id: user.id, type: "tryon", status: "processing", provider: "gemini", input: { photoPath, occasion, source: source ?? "inspire", ...(guest ? { guest: true } : {}) } })
    .select("id").single();
  if (insErr) { console.error("[generate-look] insert", insErr.message); return json({ error: "db_error" }, 500); }

  try {
    // ── Plan the set WITH the person photo: the planner must see who it
    // dresses — a text-only plan once put a masculine client in a camisole,
    // a midi skirt and a shirt-dress. Never again. ──
    let personGender: string | undefined;
    let planPerson: Awaited<ReturnType<typeof fetchInline>> | undefined;
    try {
      try {
        planPerson = await fetchInline(await signedUrl(db, "body-photos", `${photoPath}.clean.png`, 300));
      } catch (_) {
        planPerson = await fetchInline(await signedUrl(db, "body-photos", String(photoPath), 300));
      }
    } catch (e) {
      console.error("[generate-look] plan photo fetch:", (e as Error).message);
    }
    // Season grounding: the freshest distilled trend rules steer the planner
    // away from random/dated directions ("шляпные луки").
    let trendRules: string[] = [];
    try {
      const { data: tr } = await db.from("trend_insights")
        .select("aesthetic_tag, summary")
        .order("captured_at", { ascending: false }).limit(5);
      trendRules = (tr ?? []).map((t) => `${t.aesthetic_tag}: ${t.summary}`);
    } catch (e) {
      console.error("[generate-look] trends fetch:", (e as Error).message);
    }
    let planned: PlannedLook[];
    if (source === "closet") {
      // Closet mode: strictly their own clothes — slot-structured, grounded on
      // each garment's OWN image (kills fabrication + tee→shirt reinterpret),
      // and honest about slots the wardrobe can't cover (kept from the photo).
      const closetItems = (items ?? []) as ClosetItem[];
      planned = VARIANTS.map((dir, i) => {
        const c = planCloset(closetItems, dir, occasion);
        return {
          tier: "wardrobe_mix",
          title: `From your closet ${i + 1}`,
          garments: c.garments.length ? c.garments : [`your own clothes for "${occasion}"`],
          wardrobe_used: c.wardrobe_used,
          // carried into row.meta below (not part of the planner contract)
          reference_paths: c.reference_paths,
          kept_from_photo: c.kept_from_photo,
        } as PlannedLook & { reference_paths: string[]; kept_from_photo: string[] };
      });
    } else {
      const q = tierQuotas();
      try {
        const plan = await planLooks({ occasion, bodyType, proportionDesc, styleDna, wardrobe, affiliate: catalogue, quotas: q, person: planPerson, trends });
        personGender = plan.gender_presentation;
        planned = enforceQuotas(plan.looks ?? [], q, wardrobe.length > 0, catalogue.length > 0);
        if (planned.length === 0) throw new Error("empty plan");
      } catch (e) {
        console.error("[generate-look] planner failed, falling back", (e as Error).message);
        planned = VARIANTS.map((dir) => ({
          tier: "inspiration",
          title: "Styled look",
          garments: [`a complete, well-put-together outfit suited to "${occasion}" — infer formality, vibe, season. ${dir}`],
        }));
      }
    }

    // RAG grounding — moved BEFORE dispatch (text-only): an affiliate-tier
    // look whose planner picks came back thin gets each garment matched
    // SEMANTICALLY (pgvector) against the real catalogue — no hallucinated
    // product names ever reach a Shop card. Inspiration looks stay undecorated.
    for (const l of planned) {
      if (l.tier !== "affiliate") continue;
      const have = new Set(l.affiliate_ids ?? []);
      if (have.size < 2) {
        for (const g of l.garments ?? []) {
          const m = await matchRealGarment(db, g);
          if (m) have.add(m.id);
          if (have.size >= 3) break;
        }
      }
      l.affiliate_ids = [...have];
    }

    // ── Per-look rows: everything a worker needs to render + everything the
    // client needs for the gallery, frozen at dispatch time ──────────────────
    const rows = planned.map((l, i) => {
      const closet = l as PlannedLook & { reference_paths?: string[]; kept_from_photo?: string[] };
      const isCloset = source === "closet";
      return {
        generation_id: gen.id,
        user_id: user.id,
        look_index: i,
        status: "pending",
        meta: {
          prompt: isCloset
            ? closetPrompt(l.garments ?? [], closet.kept_from_photo ?? [], occasion, fit, personGender)
            : lookPrompt(l, occasion, fit,
                (l.affiliate_ids ?? []).map(skuMandate).filter((m): m is string => m !== null),
                personGender),
          tier: l.tier,
          title: l.title,
          // The plain garment list, kept alongside the full prompt: the grid
          // renderer needs ONE short line per quadrant, not the whole prompt
          // (identity/background boilerplate belongs to the grid prompt once).
          garments: l.garments ?? [],
          wardrobe_used: l.wardrobe_used ?? [],
          // Closet grounding: the garments' own images (wardrobe bucket) the
          // worker attaches as references; the slots kept from the photo so the
          // client can say "no shoes in your wardrobe — kept your own".
          ...(isCloset
            ? { reference_paths: closet.reference_paths ?? [], kept_from_photo: closet.kept_from_photo ?? [] }
            : {}),
          affiliate: (l.affiliate_ids ?? []).map((id) => affById.get(id)).filter(Boolean).map((a) => ({
            id: a!.id, brand: a!.brand_name, name: a!.name, category: a!.category, price: a!.price, currency: a!.currency, buyUrl: a!.buy_url, imageUrl: a!.image_url,
          })),
        },
      };
    });
    const { data: inserted, error: rowsErr } = await db.from("look_renders")
      .insert(rows).select("id, look_index");
    if (rowsErr || !inserted?.length) throw new Error(`rows: ${rowsErr?.message ?? "empty"}`);

    // ── Fan-out: one worker invocation per look, NOT awaited ────────────────
    // waitUntil keeps this instance alive until every worker's request settles
    // (each holds its fetch open for the whole render), while the 202 below
    // returns to the client NOW. A dispatch-level failure flips its row to
    // failed so the set can still finalize.
    const base = Deno.env.get("SUPABASE_URL")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // GRID ENGINE (default): one image call dresses the avatar in up to four
    // looks — ~$0.14 for the set instead of ~$0.39 for five singles, and one
    // failure point instead of five. render-grid keeps the row/Realtime
    // contract and hands anything it can't batch to render-look.
    // LOOK_ENGINE=fanout restores the per-look workers.
    if ((Deno.env.get("LOOK_ENGINE") ?? "grid") === "grid") {
      const one = fetch(`${base}/functions/v1/render-grid`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${service}` },
        body: JSON.stringify({ generation_id: gen.id }),
      }).then(async (res) => {
        if (!res.ok) {
          // The batched worker never even started — fall back to per-look so
          // the set still renders instead of hanging on pending rows.
          console.error("[generate-look] render-grid dispatch", res.status);
          await Promise.allSettled(inserted.map((r) =>
            fetch(`${base}/functions/v1/render-look`, {
              method: "POST",
              headers: { "Content-Type": "application/json", Authorization: `Bearer ${service}` },
              body: JSON.stringify({ render_id: r.id }),
            }).catch(() => markRenderFailed(db, r.id as string, "dispatch failed"))));
        }
      }).catch(async (e) => {
        console.error("[generate-look] render-grid", (e as Error).message);
        for (const r of inserted) await markRenderFailed(db, r.id as string, `dispatch: ${(e as Error).message}`);
      });
      // deno-lint-ignore no-explicit-any
      const rtG = (globalThis as any).EdgeRuntime;
      if (rtG?.waitUntil) rtG.waitUntil(one);

      const byIdxG = new Map(inserted.map((r) => [r.look_index as number, r.id as string]));
      return json({
        generationId: gen.id,
        occasion,
        renders: planned.map((l, i) => ({
          id: byIdxG.get(i), index: i, tier: l.tier, title: l.title,
        })).filter((r) => r.id),
      }, 202);
    }

    const fanout = Promise.allSettled(inserted.map((r, i) => (async () => {
      // 300ms stagger: five renders starting the same instant trip Gemini's
      // burst limiter TOGETHER and then back off together — that lockstep is
      // the long tail on the last cards. A ramped start stays under the limit.
      if (i) await new Promise((res) => setTimeout(res, i * 300));
      return await fetch(`${base}/functions/v1/render-look`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${service}` },
        body: JSON.stringify({ render_id: r.id }),
      }).then(async (res) => {
        if (!res.ok) await markRenderFailed(db, r.id as string, `dispatch ${res.status}`);
      }).catch((e) => markRenderFailed(db, r.id as string, `dispatch: ${(e as Error).message}`));
    })()));
    // deno-lint-ignore no-explicit-any
    const rt = (globalThis as any).EdgeRuntime;
    if (rt?.waitUntil) rt.waitUntil(fanout);

    // LAZY AVATAR BACKFILL: photos uploaded before the avatar pipeline existed
    // have no canonical avatar — build one in the background so the NEXT
    // generate on this photo starts from the anchored mannequin canvas. At
    // most one attempt per generate call (quota-gated upstream).
    const backfill = (async () => {
      const { data } = await db.storage.from("body-photos")
        .createSignedUrl(`${photoPath}.avatar.png`, 60);
      if (!data?.signedUrl) await buildCanonicalAvatar(db, String(photoPath));
    })().catch(() => {});
    if (rt?.waitUntil) rt.waitUntil(backfill);

    const byIndex = new Map(inserted.map((r) => [r.look_index as number, r.id as string]));
    return json({
      generationId: gen.id,
      occasion,
      renders: planned.map((l, i) => ({
        id: byIndex.get(i), index: i, tier: l.tier, title: l.title,
      })).filter((r) => r.id),
    }, 202);
  } catch (err) {
    console.error("[generate-look]", (err as Error).message);
    await db.from("generations").update({ status: "failed", error: (err as Error).message }).eq("id", gen.id);
    return json({ error: "generation_failed" }, 502); // quota NOT burned on failure
  }
});
