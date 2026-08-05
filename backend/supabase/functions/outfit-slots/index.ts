// POST /functions/v1/outfit-slots  { image:{data(b64),mimeType} }
// Detect the garment slots present on the person + 2 alternative ideas per slot.
// Powers the sectioned avatar editor (P0-1). Authed, no credit burned (part of
// iterating on a paid look). Returns { slots:[{slot,item,ideas[]}] }.
import { admin, getEntitlement, getUser } from "../_shared/supabase.ts";
import { detectOutfitSlots } from "../_shared/vision.ts";
import { matchRealGarment } from "../_shared/affiliate.ts";
import { json, preflight } from "../_shared/http.ts";

const SLOT_TO_CATEGORY: Record<string, string> = {
  top: "top", bottom: "bottom", shoes: "shoes", outerwear: "outerwear",
  belt: "accessory", accessories: "accessory", bag: "accessory",
  glasses: "accessory", watch: "accessory", jewelry: "accessory",
};

// DETERMINISTIC SANITY VETO — the DB category/gender tags on the generated
// library are imperfect (a polo tagged 'bottom', women's heels tagged 'male'
// leaked into the wrong slot), and the semantic RPC trusts those tags. This
// name-based guard is the last line: it rejects an image whose NAME plainly
// contradicts the slot it's about to fill, or the user's gender — regardless
// of how it was tagged or which source it came from. Rejecting a wrong image
// (→ Gemini renders from the idea text instead) beats showing it.
const TOP_WORDS = /(polo|shirt|tee|t-shirt|blouse|sweater|jumper|knit|hoodie|cardigan|tank|camisole|turtleneck|top)\b/i;
const BOTTOM_WORDS = /(trouser|pant|jean|chino|jogger|legging|short|skirt|slack|culotte)/i;
const SHOE_WORDS = /(shoe|sneaker|trainer|boot|loafer|derby|oxford|brogue|sandal|slide|flip|mule|espadrille|heel|pump|stiletto|ballet|ballerina|moccasin|clog|flat)/i;
const OUTER_WORDS = /(jacket|coat|blazer|parka|trench|bomber|overcoat|windbreaker|gilet|vest|anorak)/i;
// Unmistakably feminine footwear/garment cues — never on a masculine avatar.
const FEMININE_WORDS = /(heel|stiletto|pump|court shoe|ballet|ballerina|mary jane|maryjane|slingback|kitten|wedge|peep.?toe|dress\b|gown|skirt|blouse|camisole|bodysuit|bralette)/i;
const MASCULINE_ONLY_WORDS = /(necktie|bow.?tie)/i;

// SHORTS ARE OFF THE MENU until the render base has bare legs. The base wears
// full-length trousers, and the legs repaint pass measurably fails (grey trouser
// with the base's emblem bleeding through) — so every shorts render ships as
// long navy trousers with a white fill band and denim tubes around the pocketed
// hands. Reported from the phone as "полный ужас", traced to `lower: navy
// shorts` in the job rows while the identical pipeline rendered real jeans
// cleanly. Offering a garment the engine cannot render is worse than a thinner
// catalogue; lift this with the minimal-base work.
const BLOCKED_WORDS = /(shorts|шорт)/i;

function slotConflict(slot: string, name: string): boolean {
  const n = (name || "").toLowerCase();
  if (!n) return false;
  if (BLOCKED_WORDS.test(n)) return true;
  switch (slot) {
    case "bottom": return TOP_WORDS.test(n) || SHOE_WORDS.test(n) || OUTER_WORDS.test(n);
    case "top":    return BOTTOM_WORDS.test(n) || SHOE_WORDS.test(n) || OUTER_WORDS.test(n);
    case "shoes":  return TOP_WORDS.test(n) || BOTTOM_WORDS.test(n) || OUTER_WORDS.test(n);
    case "outerwear": return SHOE_WORDS.test(n) || BOTTOM_WORDS.test(n);
    default: return false; // accessories/belt/bag/watch/glasses/jewelry — too varied to veto
  }
}
function genderConflict(name: string, g?: string): boolean {
  const n = (name || "").toLowerCase();
  if (!n) return false;
  if (g === "male" && FEMININE_WORDS.test(n)) return true;
  if (g === "female" && MASCULINE_ONLY_WORDS.test(n)) return true;
  return false;
}

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { image } = await req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) return json({ error: "image { data, mimeType } required" }, 400);

  try {
    let trends: string[] = [];
    try {
      const { data: trendRows } = await db.from("trend_insights")
        .select("aesthetic_tag, summary")
        .order("captured_at", { ascending: false })
        .limit(4);
      trends = (trendRows ?? []).map((t) => `${t.aesthetic_tag}: ${t.summary}`);
    } catch (_) {/* trends are seasoning, never a blocker */}
    // ACCESSORY STUDIO (premium): glasses / watch / jewelry become their own
    // slots; everyone else keeps the single grouped 'accessories' entry.
    let premium = false;
    try {
      premium = (await getEntitlement(db, user.id)).premium;
    } catch (_) {/* no entitlement row → free tier */}
    // STUB_TEXT: skip the vision model and hand back a fixed slot list. The
    // ENGINE is the feature under test; the text layer is a dependency that was
    // costing money and is currently switched off, so the editor could not even
    // open (analyze/outfit-slots returned 502 and the swap path was never
    // reached). Stubbing lets the try-on be exercised end to end.
    //
    // NOT random text: `item` is deliberately vague and the ideas are filled
    // from the catalogue by the pool code below, so every alternative carries a
    // real garment photo — which is exactly what the renderer needs. A random
    // string would have produced a rail of unrenderable cards.
    const stub = (Deno.env.get("STUB_TEXT") ?? "") === "1";
    const out = stub
      ? {
        gender_presentation: "masculine",
        // OUTERWEAR IS CUT FROM THE DEMO LANE, same rule as shorts: never offer
        // what the engine cannot render. Layering a jacket OVER a worn top is not
        // expressible by single-slot inpainting — a puffer rendered as a floating
        // black shape with a grey arch over the shoulders, and it was already in
        // the failed half of the acceptance set. Restore the slot when layering
        // exists; a thinner rail beats a broken frame at a fund demo.
        slots: ["top", "bottom", "shoes"].map((slot) => ({
          slot,
          item: `your ${slot}`,
          ideas: [0, 1, 2, 3].map(() => ({
            garment: slot,          // pool matching keys off the slot, not this
            why: "Swap it and see how it looks on you.",
            recommended: false,
          })),
        })),
      } as Awaited<ReturnType<typeof detectOutfitSlots>>
      : await detectOutfitSlots({ data: image.data, mimeType: image.mimeType }, trends, premium);
    // LIBRARY GROUNDING: match each idea to our OWN generated flat-lay
    // (affiliate_items, source='generated') so the editor shows a READY image
    // instantly (no per-thumb Gemini render) AND grounds the try-on on that
    // exact flat-lay. Fine-category pinned to the actual slot (top/bottom/
    // watch/glasses…); 'accessories' (grouped) matches on embedding only.
    // Lower threshold — the library is generic, we want a hit almost always.
    const g = out.gender_presentation === "masculine" ? "male"
      : out.gender_presentation === "feminine" ? "female" : undefined;
    // Pre-fetch a per-category pool of library flat-lays (ONE cheap DB query,
    // no embeddings) — the quota-free fallback so a thumbnail is ALWAYS ready
    // even when the embedding endpoint is rate-limited. Semantic match still
    // runs first (nicer relevance); this only fills the gaps.
    const pools: Record<string, { id: string; name: string; image_url: string }[]> = {};
    try {
      const cats = [...new Set(out.slots.map((s) => s.slot === "accessories" ? null : s.slot).filter(Boolean))] as string[];
      const { data } = await db.from("affiliate_items")
        .select("id, name, image_url, category")
        .eq("source", "generated").eq("active", true)
        .in("category", cats)
        // gender unknown/neutral → UNISEX ONLY, never cross-gender (a man was
        // getting women's shoes when detection returned neutral).
        .or(g ? `gender.eq.${g},gender.eq.unisex` : "gender.eq.unisex");
      for (const r of (data ?? []) as { id: string; name: string; image_url: string; category: string }[]) {
        (pools[r.category] ??= []).push({ id: r.id, name: r.name, image_url: r.image_url });
      }
    } catch (e) {
      console.error("[outfit-slots] pool fetch", (e as Error).message);
    }
    // Only OUR clean, correctly-tagged generated flat-lays may reach the user.
    // The semantic RPC searches ALL affiliate_items (incl. legacy scraped rows
    // with NULL gender that slip past the gender filter) — so a semantic hit is
    // accepted ONLY when its id is also in the generated pool. Kills the
    // scraped-womenswear leak at the source.
    const generatedIds = new Set(Object.values(pools).flat().map((p) => p.id));
    const used = new Set<string>();
    try {
      await Promise.all(out.slots.flatMap((s) =>
        (s.ideas ?? []).map(async (idea) => {
          // Semantic match ONLY when gender is known — otherwise the RPC would
          // return any gender (a man got women's shoes). Unknown/neutral → skip
          // straight to the unisex-only pool below.
          // A candidate is only acceptable if it's a GENERATED item AND its NAME
          // matches the slot AND the gender — this vetoes mistagged/scraped rows
          // (polo→bottom, heels→male) the tag-trusting RPC/pool would let through.
          const ok = (nm?: string, itemId?: string) =>
            !!nm && !!itemId && generatedIds.has(itemId) &&
            !slotConflict(s.slot, nm) && !genderConflict(nm, g);
          const m = (g && !stub)
              ? await matchRealGarment(db, idea.garment, {
                  category: s.slot === "accessories" ? null : s.slot,
                  minSimilarity: 0.28,
                  gender: g,
                })
              : null;
          let img: string | undefined, id: string | undefined, name: string | undefined;
          if (m && ok(m.name, m.id)) { img = m.imageUrl; id = m.id; name = m.name; }
          if (!img) {
            // Fallback: a distinct library item of this category not yet used —
            // skipping any whose name fails the slot/gender veto.
            const pool = pools[s.slot] ?? [];
            const pick = pool.find((p) => !used.has(p.id) && ok(p.name, p.id))
                ?? pool.find((p) => ok(p.name, p.id));
            if (pick) { img = pick.image_url; id = pick.id; name = pick.name; }
          }
          if (img) {
            used.add(id!);
            (idea as Record<string, unknown>).shop = {
              id, brand: "", name, price: 0, currency: "USD", buyUrl: "", imageUrl: img,
            };
            // The matched item's real name becomes the idea itself, so the
            // client's label — and therefore the renderer's hint — names the
            // garment instead of repeating the slot.
            if (name) (idea as Record<string, unknown>).garment = name;
          }
        })));
    } catch (e) {
      console.error("[outfit-slots] library match", (e as Error).message);
    }
    return json(out);
  } catch (err) {
    console.error("[outfit-slots]", (err as Error).message);
    return json({ error: "slots_failed" }, 502);
  }
});
