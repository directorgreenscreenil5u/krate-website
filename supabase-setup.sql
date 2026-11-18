-- Krate customer accounts: run this once in Supabase → SQL Editor → New query → Run.

-- 1. Customer details
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text,
  phone text,
  address text,
  addresses jsonb default '[]'::jsonb,
  updated_at timestamptz default now()
);

-- 2. Orders and subscriptions
create table if not exists public.orders (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('once', 'sub', 'topup')),
  summary text not null,
  crates int not null default 1,
  frequency text,
  total numeric not null,
  skip_next boolean default false,
  credit_used numeric default 0,
  delivery_fee numeric default 0,
  payment_method text,
  payment_status text,
  payment_ref text,
  delivery_address text,
  delivery_note text,
  -- Krate Plan (prepaid bundles)
  plan_value numeric,          -- prepaid value (items + delivery fees)
  per_crate numeric,           -- locked crate price for this plan
  fee_each numeric,            -- delivery fee per delivery
  used_before numeric default 0,
  done_before int default 0,
  start_date date,
  plan_day int,                -- 0 = Sunday … 6 = Saturday
  skips jsonb default '[]'::jsonb,
  paused_until date,
  gift_name text,
  gift_phone text,
  status text not null default 'placed' check (status in ('placed', 'delivered', 'active', 'paused', 'cancelled')),
  created_at timestamptz default now()
);

-- 3. Each customer can only see and change their own rows
alter table public.profiles enable row level security;
alter table public.orders enable row level security;

create policy "own profile read"   on public.profiles for select using (auth.uid() = id);
create policy "own profile insert" on public.profiles for insert with check (auth.uid() = id);
create policy "own profile update" on public.profiles for update using (auth.uid() = id);

create policy "own orders read"    on public.orders for select using (auth.uid() = user_id);
create policy "own orders insert"  on public.orders for insert with check (auth.uid() = user_id);
-- customers may only pause, resume or cancel their own subscriptions
create policy "own orders update"  on public.orders for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id and status in ('active', 'paused', 'cancelled'));

-- If you already created the orders table, run this instead to add the plan columns:
-- alter table public.orders drop constraint if exists orders_kind_check;
-- alter table public.orders add constraint orders_kind_check check (kind in ('once','sub','topup'));
-- alter table public.orders add column if not exists plan_value numeric, add column if not exists per_crate numeric,
--   add column if not exists fee_each numeric, add column if not exists used_before numeric default 0,
--   add column if not exists done_before int default 0, add column if not exists start_date date,
--   add column if not exists plan_day int, add column if not exists skips jsonb default '[]'::jsonb,
--   add column if not exists paused_until date, add column if not exists gift_name text, add column if not exists gift_phone text;
