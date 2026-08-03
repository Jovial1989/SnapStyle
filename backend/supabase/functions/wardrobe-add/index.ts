// POST /functions/v1/wardrobe-add  { image:{data(b64),mimeType} }
// Add one clothing item to the user's Digital Wardrobe. We store the item WORN
// ON THE USER (rendered on their default body photo) rather than a flat garment
// photo — a flat lay is "far from the truth". Falls back to the flat photo if
// the user has no body photo yet. Authed, no credit burned.
import { admin, getUser } from "../_shared/supabase.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { classifyItem } from "../_shared/vision.ts";
import { json, preflight } from "../_shared/http.ts";

const BUCKET = "wardrobe";
const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

/** Self-hosted preprocessing engine (rembg u2netp + OpenCV): background removal
 * + tight crop + 512px normalize, for FREE — replaces the ~$0.04 Gemini
 * isolation call per item when PREPROCESSOR_URL is configured. Returns null on
 * any failure/timeout so the caller can fall back to the Gemini path. */
async function preprocess(image: { data: string; mimeType: string }): Promise<Uint8Array | null> {
  const base = Deno.env.get("PREPROCESSOR_URL");
  if (!base) return null;
  try {
    const fd = new FormData();
    fd.append("file", new Blob([b64ToBytes(image.data)], { type: image.mimeType }), "item");
    const r = await fetch(`${base.replace(/\/$/, "")}/preprocess`, {
      method: "POST",
      body: fd,
      signal: AbortSignal.timeout(30_000),
    });
    if (!r.ok) throw new Error(`preprocessor ${r.status}`);
    const out = new Uint8Array(await r.arrayBuffer());
    return out.length > 0 ? out : null;
  } catch (e) {
    console.error("[wardrobe-add] preprocess", (e as Error).message);
    return null;
  }
}

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  // `category` = the user's explicit intent (top/bottom/shoes/outerwear/accessory):
  // the extraction targets exactly that garment and the classifier only labels.
  const { image, original, category: userCategory, is_worn, pre_isolated } = await req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) return json({ error: "image { data, mimeType } required" }, 400);
  const isWorn = is_worn === true; // worn → rembg would cut out the person, route to Gemini
  // Client already isolated the garment ON-DEVICE (native Vision/ML Kit):
  // store as-is, skip every server-side isolation hop. `original` carries the
  // raw as-shot photo for the closet's original_image_path.
  const preIsolated = pre_isolated === true;
  const CATS = ["top", "bottom", "shoes", "outerwear", "accessory"];
  const intent = CATS.includes(userCategory) ? userCategory as string : null;

  try {
    const id = crypto.randomUUID();
    const path = `${user.id}/${id}.jpg`;

    // Label from the garment photo; the user's explicit intent wins for
    // category — UNLESS the label's own words plainly contradict it (a
    // mis-tapped chip filed "navy shorts" under top; that row then polluted
    // the editor's Top tab). Deterministic keyword check, no model judgment.
    const LABEL_RULES: [string, RegExp][] = [
      ["bottom", /short|pant|trouser|jean|chino|skirt/i],
      ["shoes", /shoe|sneaker|boot|loafer|sandal|heel|flip[- ]?flop/i],
      ["outerwear", /jacket|coat|blazer|overshirt|cardigan/i],
      ["accessory", /watch|belt|bag|scarf|hat|glasses/i],
      ["top", /t-?shirt|shirt|tee|polo|sweater|knit|blouse|top/i],
    ];
    const categoryFromLabel = (l: string) => LABEL_RULES.find(([, re]) => re.test(l))?.[0] ?? null;
    let label = intent ? `${intent} item` : "Clothing item";
    let category = intent ?? "other";
    try {
      const c = await classifyItem({ data: image.data, mimeType: image.mimeType });
      label = c.label || label;
      if (!intent) category = c.category || category;
      const derived = categoryFromLabel(label);
      if (derived && derived !== category) {
        console.log(`[wardrobe-add] intent/label mismatch: ${category} → ${derived} ("${label}")`);
        category = derived;
      }
    } catch (e) {
      console.error("[wardrobe-add] classify", (e as Error).message);
    }

    // Digital-closet pair: image_path = the ISOLATED garment (person/background
    // removed, clean product shot); original_image_path = the raw photo as shot.
    let stored = b64ToBytes(image.data); // fallback: the raw photo as the main image
    let contentType = image.mimeType;
    // SMART ROUTER: pre-isolated (on-device) → store as-is; flat/hanger shots
    // → self-hosted rembg preprocessor (free); worn shots → Gemini extraction
    // (rembg would isolate the whole person). Any failure → Gemini fallback.
    const pre = (isWorn || preIsolated) ? null : await preprocess(image);
    if (pre) {
      stored = pre;
      contentType = "image/png";
    } else if (!preIsolated) try {
      // Targeted extraction: with intent we name the exact garment type — no
      // guessing which piece in a busy photo, fewer mis-extractions.
      const target = intent ? `the ${intent}` : "the main clothing item";
      const iso = await generateLookImage(
        { data: image.data, mimeType: image.mimeType },
        `Extract ONLY ${target} from this photo as a clean e-commerce product shot: ` +
          "the garment alone, neatly presented front-on, NO person, NO body parts, NO background scene — " +
          "a plain seamless light-grey (#EFEFEF) studio backdrop, soft even lighting. Reproduce the garment " +
          "FAITHFULLY — exact colour, pattern, print, fabric. No text, no logos, no watermarks.",
      );
      stored = b64ToBytes(iso.data);
      contentType = iso.mimeType || "image/png";
    } catch (e) {
      console.error("[wardrobe-add] isolate", (e as Error).message); // fall back to raw photo
    }

    const originalPath = `${user.id}/${id}-original.jpg`;
    const { error: upErr } = await db.storage.from(BUCKET)
      .upload(path, stored, { contentType, upsert: true });
    if (upErr) throw new Error(`upload: ${upErr.message}`);
    // Original is best-effort — the closet still works without it. When the
    // client isolated on-device, the raw shot arrives separately as `original`.
    const rawShot = (original?.data && original?.mimeType) ? original : image;
    const { error: origErr } = await db.storage.from(BUCKET)
      .upload(originalPath, b64ToBytes(rawShot.data), { contentType: rawShot.mimeType, upsert: true });
    if (origErr) console.error("[wardrobe-add] original upload", origErr.message);

    const { data: item, error: insErr } = await db.from("wardrobe_items")
      .insert({ id, user_id: user.id, image_path: path, original_image_path: origErr ? null : originalPath, label, category })
      .select("id, image_path, original_image_path, label, category").single();
    if (insErr) throw new Error(insErr.message);

    return json({ item });
  } catch (err) {
    console.error("[wardrobe-add]", (err as Error).message);
    return json({ error: "add_failed" }, 502);
  }
});
