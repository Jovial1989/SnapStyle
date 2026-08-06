import { admin, FREE_QUOTA } from "./supabase";
import { setPro, addTokens } from "./actions";

export const dynamic = "force-dynamic";

async function loadUsers() {
  const db = admin();
  const [{ data: list }, { data: ents }] = await Promise.all([
    db.auth.admin.listUsers({ page: 1, perPage: 200 }),
    db.from("entitlements").select("user_id, pro, plan, source, free_used, bonus_tokens, updated_at"),
  ]);
  const byId = new Map((ents ?? []).map((e) => [e.user_id, e]));
  return (list?.users ?? [])
    .map((u) => {
      const e = byId.get(u.id) ?? {};
      const bonus = e.bonus_tokens ?? 0;
      return {
        id: u.id,
        email: u.email ?? "(anonymous)",
        created: u.created_at?.slice(0, 10) ?? "—",
        pro: e.pro === true,
        plan: e.pro ? (e.plan ?? "pro") : "free",
        source: e.source ?? "",
        tokensLeft: Math.max(0, FREE_QUOTA + bonus - (e.free_used ?? 0)),
        bonus,
      };
    })
    .sort((a, b) => (a.created < b.created ? 1 : -1));
}

function Chip({ children, tone }) {
  const tones = {
    pro: "bg-[#2E5BFF] text-white",
    free: "bg-[#EBEBE7] text-[#5C5C57]",
  };
  return (
    <span className={`inline-block rounded-full px-2.5 py-0.5 text-[11px] font-bold uppercase tracking-wider ${tones[tone]}`}>
      {children}
    </span>
  );
}

export default async function Users() {
  const users = await loadUsers();
  return (
    <main className="mx-auto max-w-6xl px-6 py-10">
      <p className="text-xs font-extrabold uppercase tracking-[0.14em] text-[#2E5BFF]">Looktok Admin</p>
      <h1 className="mt-1 text-3xl font-extrabold tracking-tight">Users</h1>
      <p className="mt-1 text-sm text-[#5C5C57]">
        {users.length} accounts · plan and token balance are server-authoritative (entitlements table).
      </p>

      <div className="mt-6 overflow-x-auto rounded-2xl border border-[#E4E4E0] bg-white shadow-[0_24px_48px_-32px_rgba(10,10,10,0.25)]">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-[#E4E4E0] text-left text-[11px] uppercase tracking-wider text-[#9B9B94]">
              <th className="px-4 py-3">Email</th>
              <th className="px-4 py-3">Joined</th>
              <th className="px-4 py-3">Plan</th>
              <th className="px-4 py-3">Tokens left</th>
              <th className="px-4 py-3">Bonus</th>
              <th className="px-4 py-3">Source</th>
              <th className="px-4 py-3 text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id} className="border-b border-[#F1F1EE] last:border-0 hover:bg-[#FAFAF8]">
                <td className="px-4 py-3 font-medium">{u.email}</td>
                <td className="px-4 py-3 text-[#5C5C57]">{u.created}</td>
                <td className="px-4 py-3"><Chip tone={u.pro ? "pro" : "free"}>{u.plan}</Chip></td>
                <td className="px-4 py-3 font-bold">{u.pro ? "∞" : u.tokensLeft}</td>
                <td className="px-4 py-3 text-[#5C5C57]">{u.bonus > 0 ? `+${u.bonus}` : "—"}</td>
                <td className="px-4 py-3 text-xs text-[#9B9B94]">{u.source}</td>
                <td className="px-4 py-3">
                  <div className="flex justify-end gap-1.5">
                    <form action={addTokens.bind(null, u.id, 10)}>
                      <button className="rounded-lg border border-[#E4E4E0] px-2.5 py-1 text-xs font-bold hover:border-[#2E5BFF] hover:text-[#2E5BFF]">+10</button>
                    </form>
                    <form action={addTokens.bind(null, u.id, -10)}>
                      <button className="rounded-lg border border-[#E4E4E0] px-2.5 py-1 text-xs font-bold hover:border-[#0A0A0A]">−10</button>
                    </form>
                    <form action={setPro.bind(null, u.id, !u.pro)}>
                      <button className={`rounded-lg px-2.5 py-1 text-xs font-bold ${u.pro ? "border border-[#E4E4E0] text-[#5C5C57] hover:border-red-400 hover:text-red-500" : "bg-[#0A0A0A] text-white hover:bg-[#2E5BFF]"}`}>
                        {u.pro ? "Revoke Pro" : "Grant Pro"}
                      </button>
                    </form>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </main>
  );
}
