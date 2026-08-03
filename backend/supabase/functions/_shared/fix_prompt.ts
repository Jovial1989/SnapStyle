// The single source of truth for the try-on swap prompt — used by generate-fix
// (legacy synchronous path, kept for older installed builds) and the
// fix-render worker (Realtime path). Divergence here = subtle render drift
// between app versions, so NEVER fork this text.

export function buildFixPrompt(
  instruction: string,
  refsCount: number,
  targetZones: string[],
  lockedZones: string[],
  hasIdentityRef = false,
): string {
  return [
    `Show the person in this photo with one specific styling change applied: ${instruction}.`,
    refsCount
      ? `IMAGE ORDER: the FIRST image is THE PERSON — the only human that may appear in the output. The next ${refsCount} image(s) are GARMENT product shots: reference material only, never people or bodies to render. COPY each garment from its reference photo LITERALLY — the same color, wash, pattern, fabric, length and construction — fitted naturally onto the person from the FIRST image. Where the text and a reference photo could be read differently, the reference photo wins.`
      : "",
    hasIdentityRef
      ? "FACE IDENTITY REFERENCE: the LAST image is a close crop of the SAME person's head. The face in your output MUST be recognizably this exact individual — same facial features, same hairline, same skin tone. It is an identity anchor only, never something to wear or render as a separate person."
      : "",
    // The person photo may arrive as a background-free cutout; with garment
    // references attached the model sometimes swapped in a generic model.
    "IDENTITY LOCK (absolute): the output shows THE SAME person as the person photo — same face, same head, same hairline, same body proportions, same skin tone, same pose. Rendering a different, younger, slimmer or generic fashion model is a FAILED generation.",
    targetZones.length
      ? `TARGET ZONE (hyper-localized mask, PERSON only): the edit is confined STRICTLY to the ${targetZones.join(" and ")} region — as if inpainting with a mask drawn only around that zone's body landmarks. No pixel OF THE PERSON outside it may change. The BACKGROUND is exempt from this mask: never preserve the original scene — always replace it with the required studio backdrop.`
      : "",
    lockedZones.length
      ? `LOCKED ANCHOR ZONES (zero tolerance): ${lockedZones.join(", ")}. These garments are pixel-frozen source material — rendering ANY of them differently (color, fit, drape, length) is a FAILED generation.`
      : "",
    // Anti-"floating head": Gemini native editing exposes no mask/negative_prompt
    // params, so mask discipline is expressed as HARD prompt constraints — the
    // edit region is confined to the garment; neck/shoulder anatomy is pinned.
    "MENTAL UNDRESS: before dressing, treat every garment being replaced as ALREADY REMOVED from the person — the outgoing piece's neckline, sleeve length, hem and silhouette must leave NO trace in the output. Dress the described garment onto a neutral body, never onto the old garment's shape.",
    "CONSTRUCTION SOURCE (the #1 failure to avoid): the new garment's SILHOUETTE — sleeve length, neckline, collar, hem length, LEG LENGTH, overall cut and fit — comes ONLY from the replacement garment's description/reference photo, NEVER from the garment currently worn in the person photo. Do NOT repaint the new fabric onto the outgoing garment's shape. Example A (sleeves): if the person currently wears a SLEEVELESS top and the new top has sleeves, the output MUST show sleeves covering the shoulders; bare shoulders = FAILED. Example B (leg length): if the person currently wears SHORTS and the new bottoms are full-length TROUSERS, the output MUST show fabric covering the whole leg DOWN TO THE ANKLE; leaving shorts or bare calves = FAILED. And vice-versa: new shorts on a trousers-wearer must show bare lower legs.",
    "EDIT REGION: modify ONLY the pixels of the garment being changed. Treat the head, neck, hands and all visible skin as a protected region — never regenerate or rescale them, and do not let the new garment's collar creep up the neck or erase the natural shoulder joints.",
    "STRUCTURE LOCK: preserve the person's exact proportions from the original photo — the SAME neck width, SAME shoulder width and shoulder line, SAME head size and head-to-body scale. Fit the new garment TO this body; never invent a new body for the garment.",
    "Seamless blend at the neckline and cuffs, perfectly matching the existing skin tone, grain and lighting.",
    "STRICTLY AVOID: disproportionate body, distorted anatomy, a floating or pasted-on head, changed shoulder width, mismatched head-to-body scale, altered pose.",
    "Keep their face, hair, body, pose and identity unchanged, and keep the rest of the outfit the same — change only what the instruction describes.",
    "FRAMING LOCK: reproduce the person photo's exact framing — same camera distance, same person scale and position in the frame, full body head-to-toe. The person must occupy the SAME height in the output as in the input; never zoom in or out between renders.",
    "TUCK DEFAULT: unless the instruction explicitly says otherwise, tops are worn UNTUCKED — the hem hangs naturally OVER the bottoms' waistband. Never tuck a top on your own initiative.",
    "BACKGROUND — REBUILD FROM SCRATCH (critical): DISCARD the input photo's background ENTIRELY. Do NOT keep, blur or feather any part of the original scene — no wall/floor patches, no grey rectangles behind or beside the person, no cutout halos or fuzzy matte edges (especially around the head, shoulders and between the arms and torso). The ENTIRE frame behind and around the person must be ONE flat, uniform, seamless PURE-WHITE (#FFFFFF) — corner to corner, edge to edge. Any leftover fragment of the original background is a FAILED generation.",
    "Photorealistic, full-body head-to-toe, centered, on a plain seamless PURE-WHITE (#FFFFFF) studio background that fills the whole frame — no grey, no gradient, no vignette, no patches. Natural even lighting.",
    "No logos, no brand names, no text, no watermarks.",
  ].filter(Boolean).join(" ");
}

/** COMPACT fallback prompt. The full buildFixPrompt is ~14 dense clauses;
 * gemini-2.5-flash-image sometimes gives up on a prompt that long and returns
 * finishReason IMAGE_OTHER (no image). This lean version keeps only the
 * non-negotiables — same person, copy the reference garment, full body, white
 * background — and reliably renders when the full prompt "dies". Used ONLY as
 * the retry after a no-image response, never as the primary. */
export function buildCompactFixPrompt(instruction: string, refsCount: number): string {
  return [
    `Edit this photo: dress the SAME person (identical face, hair, skin tone, body and pose) in ${instruction}.`,
    refsCount
      ? "Copy the garment from the reference product shot(s) EXACTLY — same colour, pattern, length and cut."
      : "",
    "Change only the described garment; keep the rest of the outfit the same.",
    "Full body, head to feet inside the frame, on a plain seamless pure-white background.",
    "Photorealistic. No text, no logos, no watermarks.",
  ].filter(Boolean).join(" ");
}

/** Escalation suffix for a re-render after a failed QA verdict. */
export const FIX_RETRY_NOTE =
  " NOTE: a previous attempt FAILED one of two ways: it kept the SOURCE garment's construction (e.g. rendered the new top SLEEVELESS like the original instead of with the described sleeves), or it REPLACED the person with a different/generic fashion model. This time: build the new garment from ITS OWN description/reference photo (correct sleeves, length, cut) AND keep the EXACT person from the person photo — same face, same head fully in frame, same build, same skin tone. Decisively.";
