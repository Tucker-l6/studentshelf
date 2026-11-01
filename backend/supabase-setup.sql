-- =====================================================================
-- THE STUDENT SHELF: database setup for Supabase
-- How to use: Supabase dashboard > SQL Editor > New query >
-- paste this whole file > Run. Run it once, on a new project.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. PROFILES (one per student; created automatically at signup)
-- ---------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  class_year  int  check (class_year between 2026 and 2032),
  handoffs    int  not null default 0,
  lbs         numeric not null default 0,
  borrowed    int  not null default 0,
  lent        int  not null default 0,
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Only @babson.edu emails can create an account.
create or replace function public.enforce_babson_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is null or lower(new.email) !~ '@babson\.edu$' then
    raise exception 'Only @babson.edu emails can join The Student Shelf';
  end if;
  return new;
end $$;

create trigger enforce_babson_email
  before insert on auth.users
  for each row execute function public.enforce_babson_email();

-- Create the profile from the name and class year entered at signup.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare yr text := new.raw_user_meta_data->>'class_year';
begin
  insert into public.profiles (id, name, class_year)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)), 40),
    case when yr ~ '^\d{4}$' and yr::int between 2026 and 2032 then yr::int end
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- Estimated weight (lbs) by item type. Set by the database, not the app,
-- so nobody can inflate the campus impact numbers.
create or replace function public.lbs_for(p_icon text) returns numeric
language sql immutable as $$
  select (case p_icon
    when 'fridge' then 45 when 'bike' then 30 when 'chair' then 25 when 'rug' then 12
    when 'monitor' then 10 when 'drawers' then 10 when 'bed' then 8 when 'mirror' then 8
    when 'books' then 6 when 'fan' then 6 when 'mug' then 6 when 'lamp' then 4
    when 'coat' then 3 when 'suit' then 3 when 'box' then 3 when 'heels' then 2
    when 'dress' then 1 when 'top' then 1 when 'hoodie' then 1 when 'calculator' then 1 when 'cable' then 1
    else 5 end)::numeric
$$;

-- ---------------------------------------------------------------------
-- 2. LISTINGS (items for sale and items for rent)
-- ---------------------------------------------------------------------
create table public.listings (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind        text not null default 'sale' check (kind in ('sale','rent')),
  title       text not null check (char_length(title) between 2 and 80),
  description text not null default '' check (char_length(description) <= 600),
  category    text not null,
  condition   text,
  price       numeric(8,2) not null default 0 check (price >= 0 and price <= 5000),
  retail      numeric(8,2) check (retail >= 0 and retail <= 20000),
  size        text check (char_length(size) <= 12),
  occasion    text,
  course      text check (char_length(course) <= 12),
  tags        text[] not null default '{}',
  hold_until  text,
  spot        text not null,
  icon        text,
  lbs         numeric not null default 5,
  photo_path  text,
  status      text not null default 'active' check (status in ('active','reserved','sold','removed')),
  created_at  timestamptz not null default now()
);
create index listings_status_idx on public.listings (status, created_at desc);

create or replace function public.set_listing_lbs() returns trigger
language plpgsql as $$
begin
  new.lbs := public.lbs_for(new.icon);
  return new;
end $$;
create trigger set_listing_lbs
  before insert or update of icon on public.listings
  for each row execute function public.set_listing_lbs();

-- ---------------------------------------------------------------------
-- 3. WANTED REQUESTS
-- ---------------------------------------------------------------------
create table public.requests (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  title       text not null check (char_length(title) between 2 and 80),
  course      text check (char_length(course) <= 12),
  budget      numeric(8,2) check (budget >= 0 and budget <= 5000),
  needed_by   text,
  status      text not null default 'open' check (status in ('open','filled','closed')),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. CONVERSATIONS, MESSAGES, HANDOFF CODES
-- buyer_id = buyer / renter / student who posted the request
-- seller_id = seller / lender / student who has the item
-- ---------------------------------------------------------------------
create table public.threads (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('sale','rent','request')),
  listing_id     uuid references public.listings(id) on delete set null,
  request_id     uuid references public.requests(id) on delete set null,
  buyer_id       uuid not null references public.profiles(id) on delete cascade,
  seller_id      uuid not null references public.profiles(id) on delete cascade,
  stage          text not null default 'chat' check (stage in
                   ('chat','proposed','scheduled','done','requested','confirmed','out','inspect','declined','cancelled')),
  pickup_spot    text,
  pickup_when    text,
  proposed_by    uuid,
  rent_day       date,
  rent_due       date,
  plan_interest  text,
  code_attempts  int not null default 0,
  lbs            numeric,
  damage_cost    numeric,
  buyer_read_at  timestamptz,
  seller_read_at timestamptz,
  completed_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (buyer_id <> seller_id)
);
create index threads_buyer_idx on public.threads (buyer_id, updated_at desc);
create index threads_seller_idx on public.threads (seller_id, updated_at desc);

create table public.messages (
  id         bigint generated always as identity primary key,
  thread_id  uuid not null references public.threads(id) on delete cascade,
  sender_id  uuid default auth.uid() references public.profiles(id) on delete set null,
  kind       text not null default 'text' check (kind in ('text','pickup','sys')),
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index messages_thread_idx on public.messages (thread_id, created_at);

create or replace function public.touch_thread() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.threads set updated_at = now() where id = new.thread_id;
  return new;
end $$;
create trigger touch_thread after insert on public.messages
  for each row execute function public.touch_thread();

-- The secret 4-digit code. Only the person holding it can read it.
create table public.handoff_codes (
  thread_id  uuid not null references public.threads(id) on delete cascade,
  purpose    text not null default 'pickup' check (purpose in ('pickup')),
  holder_id  uuid not null references public.profiles(id) on delete cascade,
  code       text not null,
  primary key (thread_id, purpose)
);

-- ---------------------------------------------------------------------
-- 5. REPORTS (flag a listing or a conversation)
-- ---------------------------------------------------------------------
create table public.reports (
  id          bigint generated always as identity primary key,
  listing_id  uuid references public.listings(id) on delete cascade,
  thread_id   uuid references public.threads(id) on delete cascade,
  reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  reason      text not null check (char_length(reason) between 1 and 500),
  resolved    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY (who can see and change what)
-- ---------------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.listings      enable row level security;
alter table public.requests      enable row level security;
alter table public.threads       enable row level security;
alter table public.messages      enable row level security;
alter table public.handoff_codes enable row level security;
alter table public.reports       enable row level security;

create policy "Students see profiles" on public.profiles for select to authenticated using (true);
create policy "Edit own profile" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "Students see listings" on public.listings for select to authenticated
  using (status <> 'removed' or owner_id = auth.uid() or public.is_admin());
create policy "Create own listings" on public.listings for insert to authenticated
  with check (owner_id = auth.uid() and status = 'active');
create policy "Edit own listings" on public.listings for update to authenticated
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());
create policy "Delete own listings" on public.listings for delete to authenticated
  using (owner_id = auth.uid());

create policy "Students see requests" on public.requests for select to authenticated
  using (status <> 'closed' or owner_id = auth.uid());
create policy "Create own requests" on public.requests for insert to authenticated
  with check (owner_id = auth.uid() and status = 'open');
create policy "Edit own requests" on public.requests for update to authenticated
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());

-- Conversations are private to the two students in them (admins included).
create policy "See own conversations" on public.threads for select to authenticated
  using (auth.uid() in (buyer_id, seller_id));
create policy "See own messages" on public.messages for select to authenticated
  using (exists (select 1 from public.threads t where t.id = thread_id and auth.uid() in (t.buyer_id, t.seller_id)));
create policy "Send messages in own conversations" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and kind = 'text'
    and exists (select 1 from public.threads t where t.id = thread_id and auth.uid() in (t.buyer_id, t.seller_id)));

create policy "Holder sees own code" on public.handoff_codes for select to authenticated
  using (holder_id = auth.uid());

create policy "File reports" on public.reports for insert to authenticated
  with check (reporter_id = auth.uid());
create policy "See own reports" on public.reports for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin());

-- Column-level limits: students can't edit counters, ownership, or impact numbers.
revoke all on all tables in schema public from anon;
revoke insert, update, delete on public.profiles from authenticated;
grant  update (name, class_year) on public.profiles to authenticated;
revoke update on public.listings from authenticated;
grant  update (title, description, category, condition, price, retail, size, occasion, course,
               tags, hold_until, spot, icon, photo_path, status) on public.listings to authenticated;
revoke update on public.requests from authenticated;
grant  update (title, course, budget, needed_by, status) on public.requests to authenticated;
revoke insert, update, delete on public.threads, public.handoff_codes from authenticated;
revoke update, delete on public.messages, public.reports from authenticated;

-- ---------------------------------------------------------------------
-- 7. ACTIONS THE APP CALLS (each checks who is asking)
-- ---------------------------------------------------------------------
create or replace function public._my_thread(p_thread uuid) returns public.threads
language plpgsql security definer set search_path = public as $$
declare t public.threads;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into t from public.threads where id = p_thread for update;
  if not found or auth.uid() not in (t.buyer_id, t.seller_id) then
    raise exception 'Conversation not found';
  end if;
  return t;
end $$;

create or replace function public._sys(p_thread uuid, p_body text) returns void
language sql security definer set search_path = public as $$
  insert into public.messages (thread_id, sender_id, kind, body) values (p_thread, null, 'sys', p_body);
$$;

create or replace function public._issue_code(p_thread uuid, p_holder uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.handoff_codes (thread_id, purpose, holder_id, code)
  values (p_thread, 'pickup', p_holder,
          lpad(((('x' || encode(extensions.gen_random_bytes(2), 'hex'))::bit(16)::int) % 10000)::text, 4, '0'))
  on conflict (thread_id, purpose) do update set holder_id = excluded.holder_id, code = excluded.code;
  update public.threads set code_attempts = 0 where id = p_thread;
end $$;

create or replace function public._day(d date) returns text
language sql immutable as $$ select to_char(d, 'Dy, Mon FMDD') $$;

-- Start (or reopen) a conversation about a listing or a Wanted request.
create or replace function public.start_thread(p_listing uuid default null, p_request uuid default null, p_message text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); l public.listings; r public.requests; tid uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if p_listing is not null then
    select * into l from public.listings where id = p_listing;
    if not found or l.status = 'removed' then raise exception 'That listing is no longer available'; end if;
    if l.owner_id = me then raise exception 'This is your own listing'; end if;
    select id into tid from public.threads
      where listing_id = p_listing and buyer_id = me and stage not in ('done','declined','cancelled')
      order by created_at desc limit 1;
    if tid is null then
      insert into public.threads (kind, listing_id, buyer_id, seller_id)
      values (case when l.kind = 'rent' then 'rent' else 'sale' end, p_listing, me, l.owner_id)
      returning id into tid;
    end if;
  elsif p_request is not null then
    select * into r from public.requests where id = p_request;
    if not found or r.status <> 'open' then raise exception 'That request is closed'; end if;
    if r.owner_id = me then raise exception 'This is your own request'; end if;
    select id into tid from public.threads
      where request_id = p_request and seller_id = me and stage not in ('done','declined','cancelled') limit 1;
    if tid is null then
      insert into public.threads (kind, request_id, buyer_id, seller_id)
      values ('request', p_request, r.owner_id, me) returning id into tid;
    end if;
  else
    raise exception 'Nothing to message about';
  end if;
  if nullif(trim(coalesce(p_message, '')), '') is not null then
    insert into public.messages (thread_id, sender_id, body) values (tid, me, left(trim(p_message), 1000));
  end if;
  return tid;
end $$;

create or replace function public.propose_pickup(p_thread uuid, p_spot text, p_when text) returns void
language plpgsql security definer set search_path = public as $$
declare t public.threads;
begin
  t := public._my_thread(p_thread);
  if t.kind = 'rent' then raise exception 'Rentals use the booking steps'; end if;
  if t.stage not in ('chat','proposed') then raise exception 'The pickup is already set'; end if;
  update public.threads set stage = 'proposed', pickup_spot = left(p_spot, 60), pickup_when = left(p_when, 60),
         proposed_by = auth.uid() where id = p_thread;
  insert into public.messages (thread_id, sender_id, kind, body)
  values (p_thread, auth.uid(), 'pickup', left(p_spot, 60) || ' · ' || left(p_when, 60));
end $$;

create or replace function public.accept_pickup(p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.threads;
begin
  t := public._my_thread(p_thread);
  if t.stage <> 'proposed' then raise exception 'There is no pickup to accept'; end if;
  if t.proposed_by = auth.uid() then raise exception 'Waiting for the other student to accept'; end if;
  update public.threads set stage = 'scheduled' where id = p_thread;
  perform public._issue_code(p_thread, t.buyer_id);
  perform public._sys(p_thread, 'Pickup confirmed: ' || t.pickup_spot || ' · ' || t.pickup_when);
end $$;

-- The seller (or lender) enters the code the buyer (or renter) shows them.
-- Returns 'ok', 'wrong', or 'locked' (after 5 wrong tries).
create or replace function public.confirm_handoff(p_thread uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare t public.threads; c public.handoff_codes; v_lbs numeric;
begin
  t := public._my_thread(p_thread);
  if auth.uid() <> t.seller_id then raise exception 'The other student enters the code'; end if;
  if t.kind = 'rent' and t.stage <> 'confirmed' then raise exception 'This rental is not ready for pickup'; end if;
  if t.kind <> 'rent' and t.stage <> 'scheduled' then raise exception 'Set a pickup first'; end if;
  if t.code_attempts >= 5 then return 'locked'; end if;
  select * into c from public.handoff_codes where thread_id = p_thread and purpose = 'pickup';
  if not found or c.code <> trim(coalesce(p_code, '')) then
    update public.threads set code_attempts = code_attempts + 1 where id = p_thread;
    return case when t.code_attempts + 1 >= 5 then 'locked' else 'wrong' end;
  end if;

  if t.kind = 'rent' then
    update public.threads set stage = 'out' where id = p_thread;
    perform public._sys(p_thread, 'Picked up with code · due back ' || public._day(t.rent_due));
    return 'ok';
  end if;

  v_lbs := coalesce((select lbs from public.listings where id = t.listing_id), public.lbs_for(null));
  update public.threads set stage = 'done', completed_at = now(), lbs = v_lbs where id = p_thread;
  update public.listings set status = 'sold' where id = t.listing_id;
  update public.requests set status = 'filled' where id = t.request_id;
  update public.profiles set handoffs = handoffs + 1 where id in (t.buyer_id, t.seller_id);
  update public.profiles set lbs = lbs + v_lbs where id = t.seller_id;
  perform public._sys(p_thread, 'Handoff confirmed with code · ' || v_lbs || ' lbs rehomed');
  return 'ok';
end $$;

-- If a code gets locked, the person holding it can get a new one.
create or replace function public.reissue_code(p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.threads;
begin
  t := public._my_thread(p_thread);
  if auth.uid() <> t.buyer_id then raise exception 'Only the code holder can do this'; end if;
  if t.stage not in ('scheduled','confirmed') then raise exception 'No pickup is waiting'; end if;
  perform public._issue_code(p_thread, t.buyer_id);
  perform public._sys(p_thread, 'A new pickup code was issued');
end $$;

-- RENTALS -------------------------------------------------------------
create or replace function public.book_rental(p_listing uuid, p_day date, p_plan text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); l public.listings; tid uuid;
        v_plan text := case when p_plan in ('none','std','full') then p_plan else 'std' end;
begin
  if me is null then raise exception 'Sign in first'; end if;
  select * into l from public.listings where id = p_listing;
  if not found or l.kind <> 'rent' or l.status <> 'active' then raise exception 'That item is not available to rent'; end if;
  if l.owner_id = me then raise exception 'This is your own listing'; end if;
  if p_day < current_date + 1 or p_day > current_date + 30 then raise exception 'Pick a day in the next 30 days'; end if;
  select id into tid from public.threads where listing_id = p_listing and buyer_id = me and stage = 'chat' limit 1;
  if tid is null then
    insert into public.threads (kind, listing_id, buyer_id, seller_id, stage, rent_day, rent_due, plan_interest)
    values ('rent', p_listing, me, l.owner_id, 'requested', p_day, p_day + 3, v_plan) returning id into tid;
  else
    update public.threads set stage = 'requested', rent_day = p_day, rent_due = p_day + 3, plan_interest = v_plan where id = tid;
  end if;
  perform public._sys(tid, 'Rental requested for ' || public._day(p_day) || ' to ' || public._day(p_day + 3));
  return tid;
end $$;

create or replace function public.respond_rental(p_thread uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare t public.threads;
begin
  t := public._my_thread(p_thread);
  if auth.uid() <> t.seller_id then raise exception 'Only the lender can answer'; end if;
  if t.stage <> 'requested' then raise exception 'This request was already answered'; end if;
  if p_accept then
    update public.threads set stage = 'confirmed' where id = p_thread;
    perform public._issue_code(p_thread, t.buyer_id);
    perform public._sys(p_thread, 'Rental confirmed for ' || public._day(t.rent_day));
  else
    update public.threads set stage = 'declined' where id = p_thread;
    perform public._sys(p_thread, 'Rental declined');
  end if;
end $$;

create or replace function public.mark_returned(p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.threads;
begin
  t := public._my_thread(p_thread);
  if auth.uid() <> t.buyer_id then raise exception 'Only the renter can do this'; end if;
  if t.stage <> 'out' then raise exception 'This rental is not out'; end if;
  update public.threads set stage = 'inspect' where id = p_thread;
  perform public._sys(p_thread, 'Marked as returned');
end $$;

create or replace function public.close_rental(p_thread uuid, p_damage numeric default null) returns void
language plpgsql security definer set search_path = public as $$
declare t public.threads; v_damage numeric := nullif(greatest(coalesce(p_damage, 0), 0), 0);
begin
  t := public._my_thread(p_thread);
  if auth.uid() <> t.seller_id then raise exception 'Only the lender can close the rental'; end if;
  if t.stage <> 'inspect' then raise exception 'Mark it returned first'; end if;
  update public.threads set stage = 'done', completed_at = now(), damage_cost = v_damage where id = p_thread;
  update public.profiles set handoffs = handoffs + 1 where id in (t.buyer_id, t.seller_id);
  update public.profiles set borrowed = borrowed + 1 where id = t.buyer_id;
  update public.profiles set lent = lent + 1 where id = t.seller_id;
  perform public._sys(p_thread, case when v_damage is null then 'Rental complete · returned in good shape'
                                     else 'Rental complete · damage reported ($' || v_damage || ')' end);
end $$;

create or replace function public.cancel_thread(p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.threads;
begin
  t := public._my_thread(p_thread);
  if t.stage in ('done','out','inspect','declined','cancelled') then raise exception 'This can no longer be cancelled'; end if;
  update public.threads set stage = 'cancelled' where id = p_thread;
  perform public._sys(p_thread, 'Cancelled');
end $$;

create or replace function public.mark_read(p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.threads
     set buyer_read_at  = case when buyer_id  = auth.uid() then now() else buyer_read_at end,
         seller_read_at = case when seller_id = auth.uid() then now() else seller_read_at end
   where id = p_thread and auth.uid() in (buyer_id, seller_id);
end $$;

-- Campus totals for the Impact tab: real completed trades only.
create or replace function public.campus_stats() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'lbs',      coalesce((select sum(lbs) from public.threads where stage = 'done' and kind in ('sale','request')), 0),
    'items',    (select count(*) from public.threads where stage = 'done' and kind in ('sale','request')),
    'borrowed', (select count(*) from public.threads where stage = 'done' and kind = 'rent'),
    'students', (select count(*) from public.profiles),
    'listings', (select count(*) from public.listings where status = 'active'),
    'by_class', coalesce((select json_object_agg(class_year, total) from (
                  select p.class_year, sum(t.lbs) as total from public.threads t join public.profiles p on p.id = t.seller_id
                  where t.stage = 'done' and t.kind in ('sale','request') and p.class_year is not null
                  group by p.class_year) x), '{}'::json),
    'weekly',   coalesce((select json_agg(json_build_object('week', wk, 'lbs', total) order by wk) from (
                  select date_trunc('week', completed_at)::date as wk, sum(lbs) as total from public.threads
                  where stage = 'done' and kind in ('sale','request') and completed_at > now() - interval '9 weeks'
                  group by 1) w), '[]'::json)
  )
$$;

-- Function permissions: signed-in students can call the actions; nothing else.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.start_thread(uuid, uuid, text), public.propose_pickup(uuid, text, text), public.accept_pickup(uuid),
  public.confirm_handoff(uuid, text), public.reissue_code(uuid), public.book_rental(uuid, date, text),
  public.respond_rental(uuid, boolean), public.mark_returned(uuid), public.close_rental(uuid, numeric),
  public.cancel_thread(uuid), public.mark_read(uuid), public.campus_stats(), public.is_admin(), public.lbs_for(text)
to authenticated;

-- ---------------------------------------------------------------------
-- 8. PHOTO STORAGE (public images, each student uploads to their own folder)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-photos', 'listing-photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "Upload own listing photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Delete own listing photos" on storage.objects for delete to authenticated
  using (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- 9. LIVE UPDATES (new messages and status changes appear instantly)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'threads') then
    alter publication supabase_realtime add table public.threads;
  end if;
end $$;

-- Done. Next: Authentication settings (see the setup guide).
