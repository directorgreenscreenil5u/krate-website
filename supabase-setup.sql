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
  kind text not null check (kind in ('once', 'sub')),
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
