// Supabase Edge Function: confirms a Paystack payment on the server, then marks the order paid.
// Deploy:  supabase functions deploy paystack-verify
// Secret:  supabase secrets set PAYSTACK_SECRET_KEY=sk_live_xxx
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { reference } = await req.json();
    if (!reference) return json({ error: "Missing reference" }, 400);

    // who is asking
    const auth = req.headers.get("Authorization") ?? "";
    const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Not signed in" }, 401);

    // ask Paystack
    const r = await fetch(`https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`, {
      headers: { Authorization: `Bearer ${Deno.env.get("PAYSTACK_SECRET_KEY")}` },
    });
    const p = await r.json();
    if (!p.status || p.data?.status !== "success") return json({ ok: false, reason: "Payment not successful" });

    // find the order and check the amount
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: order } = await admin.from("orders").select("id,user_id,total").eq("payment_ref", reference).maybeSingle();
    if (!order || order.user_id !== user.id) return json({ ok: false, reason: "Order not found" }, 404);
    if (Math.round(Number(order.total) * 100) !== Number(p.data.amount)) return json({ ok: false, reason: "Amount mismatch" }, 400);

    await admin.from("orders").update({ payment_status: "paid", payment_method: "paystack" }).eq("id", order.id);
    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
