-- =====================================================================
-- KRATE BACKEND (Supabase)
-- Run this whole file once in Supabase → SQL Editor → New query → Run.
-- It is safe to run again: it only adds what is missing.
-- =====================================================================

-- ---------- 1. Customers ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text,
  phone text,
  email text,
  address text,
  addresses jsonb default '[]'::jsonb,
  updated_at timestamptz default now()
);
alter table public.profiles add column if not exists email text;

-- ---------- 2. Staff (operations dashboard) ----------
-- Staff sign in on /ops with a Staff ID (e.g. KR-001) and a password.
-- Behind the scenes the Staff ID is an email like kr-001@staff.krate.ng (see "Adding staff" at the bottom).
create table if not exists public.staff (
  id uuid primary key references auth.users (id) on delete cascade,
  staff_id text unique not null,           -- KR-001
  name text not null,
  role text not null default 'ops' check (role in ('admin', 'ops', 'rider')),
  active boolean not null default true,
  created_at timestamptz default now()
);

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where id = auth.uid() and active);
$$;

-- ---------- 3. Orders, Krate Plans and plan top-ups ----------
create table if not exists public.orders (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('once', 'sub', 'topup')),
  summary text not null,
  crates int not null default 1,
  frequency text,
  total numeric not null,
  skip_next boolean default false,
  credit_used numeric default 0,          -- naira taken off with Krate Coins
  coins_used int default 0,
  coins_earned int default 0,             -- set by the server (see trigger), counts once paid
  delivery_fee numeric default 0,
  payment_method text,                    -- paystack | transfer
  payment_status text default 'awaiting payment' check (payment_status in ('awaiting payment', 'paid', 'failed', 'refunded')),
  payment_ref text,
  delivery_address text,
  delivery_note text,
  -- Krate Plan (prepaid bundles)
  plan_id bigint references public.orders (id) on delete cascade,  -- for top-ups: which plan they add to
  add_value numeric,                      -- for top-ups: value added to the plan once paid
  plan_value numeric,
  per_crate numeric,
  fee_each numeric,
  used_before numeric default 0,
  done_before int default 0,
  start_date date,
  plan_day int,
  skips jsonb default '[]'::jsonb,
  paused_until date,
  gift_name text,
  gift_phone text,
  status text not null default 'placed',
  handled_by uuid references public.staff (id),
  staff_note text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
-- bring older tables up to date
alter table public.orders drop constraint if exists orders_kind_check;
alter table public.orders add constraint orders_kind_check check (kind in ('once', 'sub', 'topup'));
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check check (status in ('placed', 'confirmed', 'on the way', 'delivered', 'active', 'paused', 'cancelled'));
alter table public.orders add column if not exists coins_used int default 0;
alter table public.orders add column if not exists coins_earned int default 0;
alter table public.orders add column if not exists plan_id bigint references public.orders (id) on delete cascade;
alter table public.orders add column if not exists add_value numeric;
alter table public.orders add column if not exists plan_value numeric;
alter table public.orders add column if not exists per_crate numeric;
alter table public.orders add column if not exists fee_each numeric;
alter table public.orders add column if not exists used_before numeric default 0;
alter table public.orders add column if not exists done_before int default 0;
alter table public.orders add column if not exists start_date date;
alter table public.orders add column if not exists plan_day int;
alter table public.orders add column if not exists skips jsonb default '[]'::jsonb;
alter table public.orders add column if not exists paused_until date;
alter table public.orders add column if not exists gift_name text;
alter table public.orders add column if not exists gift_phone text;
alter table public.orders add column if not exists handled_by uuid references public.staff (id);
alter table public.orders add column if not exists staff_note text;
alter table public.orders add column if not exists updated_at timestamptz default now();

-- Plan deliveries that staff have marked as done
create table if not exists public.deliveries (
  id bigint generated always as identity primary key,
  plan_id bigint not null references public.orders (id) on delete cascade,
  delivery_date date not null,
  status text not null default 'delivered' check (status in ('delivered', 'failed')),
  staff uuid references public.staff (id),
  created_at timestamptz default now(),
  unique (plan_id, delivery_date)
);

-- ---------- 4. Krate Coins settings ----------
-- 50 coins per crate, 1,000 coins = ₦200 off. Change the numbers here AND in account.js (KRATE_COINS).
create table if not exists public.settings (key text primary key, value numeric not null);
insert into public.settings (key, value) values ('coins_per_crate', 50), ('coins_block', 1000), ('coins_block_value', 200)
  on conflict (key) do nothing;

-- ---------- 5. Server-side guards (customers can't fake payments or coins) ----------
create or replace function public.orders_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare per int; crates_bought int;
begin
  if public.is_staff() then
    new.updated_at := now();
    if tg_op = 'UPDATE' and new.handled_by is null then new.handled_by := auth.uid(); end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    new.payment_status := 'awaiting payment';          -- only Paystack verification or staff can mark paid
    new.status := case when new.kind = 'sub' then 'active' else 'placed' end;
    new.handled_by := null; new.staff_note := null;
    select value into per from public.settings where key = 'coins_per_crate';
    crates_bought := coalesce(new.crates, 1);
    if new.kind = 'sub' and new.plan_value is not null and new.per_crate is not null then
      crates_bought := round(new.plan_value / (coalesce(new.crates, 1) * new.per_crate + coalesce(new.fee_each, 0))) * coalesce(new.crates, 1);
    end if;
    new.coins_earned := crates_bought * coalesce(per, 50);
    return new;
  end if;

  -- customer UPDATE: only plan controls and pause / resume / cancel
  if new.user_id <> old.user_id or new.total <> old.total or new.kind <> old.kind
     or new.payment_status is distinct from old.payment_status or new.payment_ref is distinct from old.payment_ref
     or new.coins_earned is distinct from old.coins_earned or new.coins_used is distinct from old.coins_used
     or new.credit_used is distinct from old.credit_used or new.plan_value is distinct from old.plan_value
     or new.per_crate is distinct from old.per_crate or new.fee_each is distinct from old.fee_each
     or new.add_value is distinct from old.add_value or new.handled_by is distinct from old.handled_by then
    raise exception 'Not allowed';
  end if;
  if new.status <> old.status and new.status not in ('active', 'paused', 'cancelled') then
    raise exception 'Not allowed';
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists orders_guard on public.orders;
create trigger orders_guard before insert or update on public.orders
  for each row execute function public.orders_guard();

-- ---------- 6. Who can see what (row level security) ----------
alter table public.profiles enable row level security;
alter table public.orders enable row level security;
alter table public.staff enable row level security;
alter table public.deliveries enable row level security;
alter table public.settings enable row level security;

drop policy if exists "own profile read" on public.profiles;
drop policy if exists "own profile insert" on public.profiles;
drop policy if exists "own profile update" on public.profiles;
drop policy if exists "own orders read" on public.orders;
drop policy if exists "own orders insert" on public.orders;
drop policy if exists "own orders update" on public.orders;

create policy "profile read"   on public.profiles for select using (auth.uid() = id or public.is_staff());
create policy "profile insert" on public.profiles for insert with check (auth.uid() = id);
create policy "profile update" on public.profiles for update using (auth.uid() = id or public.is_staff());

create policy "orders read"    on public.orders for select using (auth.uid() = user_id or public.is_staff());
create policy "orders insert"  on public.orders for insert with check (auth.uid() = user_id);
create policy "orders update"  on public.orders for update using (auth.uid() = user_id or public.is_staff());

create policy "staff read self" on public.staff for select using (id = auth.uid() or public.is_staff());

create policy "deliveries read"  on public.deliveries for select using (
  public.is_staff() or exists (select 1 from public.orders o where o.id = plan_id and o.user_id = auth.uid()));
create policy "deliveries write" on public.deliveries for all using (public.is_staff()) with check (public.is_staff());

create policy "settings read" on public.settings for select using (true);

-- =====================================================================
-- ADDING STAFF
-- 1. Supabase → Authentication → Users → Add user → Create new user
--      Email:    kr-001@staff.krate.ng      (Staff ID in lower case + @staff.krate.ng)
--      Password: choose one, tick "Auto confirm user"
-- 2. Copy the new user's UID, then run (with your values):
--      insert into public.staff (id, staff_id, name, role)
--      values ('PASTE-UID-HERE', 'KR-001', 'Your Name', 'admin');
-- 3. Sign in at  https://<your-site>/ops/  with Staff ID KR-001 and that password.
-- To remove someone: update public.staff set active = false where staff_id = 'KR-001';
-- =====================================================================
