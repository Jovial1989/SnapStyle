// Unnamed style archetypes (NO celebrity names or likenesses — legal decision).
// Shared by trend-refresh (RAG rules) and build-muses (muse imagery).
export const ARCHETYPES: { tag: string; desc: string }[] = [
  { tag: "Elevated Minimalism", desc: "clean lines, neutral palette, considered proportions, quality basics" },
  { tag: "Quiet Luxury", desc: "understated, fine tonal fabrics, no logos, expensive-feeling simplicity" },
  { tag: "Sharp Tailoring", desc: "structured, precise, dressed-up, strong shoulders and clean trousers" },
  { tag: "Street Modern", desc: "relaxed streetwear, bold proportion, sneaker-led, layered casual" },
  { tag: "Old Money Prep", desc: "heritage preppy, classic knits and collars, timeless and unflashy" },
  { tag: "Utilitarian", desc: "functional workwear-inspired, muted earthy tones, practical details" },
];

// Occasion buckets the Generate loader groups muses by.
export const CATEGORIES: string[] = ["everyday", "work", "evening", "weekend"];

/** Coarse season label (northern-hemisphere default). EF runtime → Date OK. */
export function currentSeason(d: Date = new Date()): string {
  const m = d.getUTCMonth(); // 0 = Jan
  if (m <= 1 || m === 11) return "winter";
  if (m <= 4) return "spring";
  if (m <= 7) return "summer";
  return "autumn";
}

/** Round-robin items across archetypes so a feed reads DIVERSE (not 3 near-identical
 * looks of the same archetype in a row). `first` (optional) leads. */
export function interleaveByArchetype<T extends { archetype: string }>(items: T[], first?: string | null): T[] {
  const groups = new Map<string, T[]>();
  for (const it of items) {
    const g = groups.get(it.archetype) ?? [];
    g.push(it);
    groups.set(it.archetype, g);
  }
  const order = [...groups.keys()];
  if (first && groups.has(first)) { order.splice(order.indexOf(first), 1); order.unshift(first); }
  const out: T[] = [];
  let added = true;
  while (added) {
    added = false;
    for (const k of order) {
      const g = groups.get(k)!;
      if (g.length) { out.push(g.shift()!); added = true; }
    }
  }
  return out;
}
