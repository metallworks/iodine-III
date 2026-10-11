-- ===========================================================================
-- Iodine III - the whole database, in one file
--
-- RUN THIS ONCE. That is the entire setup.
--
-- In Supabase: left sidebar -> SQL Editor -> New query -> paste the whole
-- file -> Run. It takes a few seconds.
--
-- It is safe to run again later, as many times as you like. Nothing in
-- here deletes anyone's posts, messages or accounts.
--
-- WHY THIS REPLACED THE THREE SEPARATE FILES
-- They had to be run in the right order, and if one stopped part-way
-- through, the next failed on something the first had not created yet -
-- which is exactly what happened: schema.sql defined the view counter
-- one way, the second file redefined it another way, PostgreSQL refused
-- the change, and everything after that point in the file never ran. One
-- file with one order cannot go wrong that way.
--
-- A NOTE ON STORAGE, since the free plan is not large.
-- Everything here is text and numbers, which is tiny. What fills a free
-- database is images and video, so posts hold a LINK to a picture rather
-- than the picture, clips hold a link to the video, and the site refuses
-- anything over 2MB. Views, likes and dislikes are counters on a row
-- rather than one row per click. Anything that only matters to one
-- person on one computer - what they have played, their colours, what
-- they have already seen - never touches the server at all.
-- ===========================================================================

-- ===========================================================================
-- Iodine III - IDN schema
--
-- Run this ONCE on your Supabase project:
--   Supabase dashboard -> SQL Editor -> New query -> paste -> Run
--
-- Until this runs, the IDN tab will say the tables are not set up. After it
-- runs, IDN is a real multi-user network: posts and DMs sync between every
-- signed-in account.
--
-- WHY THE POLICIES MATTER
-- The anon key in the page is public by design; anyone can read it out of
-- the HTML. Row Level Security is the only thing standing between that key
-- and your data. Every table below has RLS enabled and explicit policies.
-- If you add a table later, enable RLS on it too, or that key can read and
-- write the whole thing.
-- ===========================================================================

-- ---------------------------------------------------------------- profiles
-- Mirrors auth.users so one account can look another up by display name
-- (needed to start a DM) without exposing the auth schema.
create table if not exists public.idn_profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  pfp_url      text,
  created_at   timestamptz not null default now()
);

create unique index if not exists idn_profiles_name_key
  on public.idn_profiles (lower(display_name));

alter table public.idn_profiles enable row level security;

drop policy if exists "profiles readable by signed-in users" on public.idn_profiles;
create policy "profiles readable by signed-in users"
  on public.idn_profiles for select
  to authenticated
  using (true);

drop policy if exists "own profile insert" on public.idn_profiles;
create policy "own profile insert"
  on public.idn_profiles for insert
  to authenticated
  with check (auth.uid() = id);

drop policy if exists "own profile update" on public.idn_profiles;
create policy "own profile update"
  on public.idn_profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Keep idn_profiles in step with auth.users automatically, so signing up
-- is enough to become findable - the client never has to remember to
-- create its own profile row.
create or replace function public.idn_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.idn_profiles (id, display_name, pfp_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'user_pfp'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists idn_on_auth_user_created on auth.users;
create trigger idn_on_auth_user_created
  after insert on auth.users
  for each row execute function public.idn_handle_new_user();

-- Backfill anyone who signed up before this schema existed.
insert into public.idn_profiles (id, display_name, pfp_url)
select u.id,
       coalesce(u.raw_user_meta_data->>'display_name', split_part(u.email, '@', 1)),
       u.raw_user_meta_data->>'user_pfp'
from auth.users u
on conflict (id) do nothing;

-- ------------------------------------------------------------------- posts
create table if not exists public.idn_posts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  body        text not null default '',
  image_url   text,
  views       integer not null default 0,
  created_at  timestamptz not null default now(),
  constraint idn_posts_body_len check (char_length(body) <= 1000),
  constraint idn_posts_not_empty check (char_length(body) > 0 or image_url is not null)
);

create index if not exists idn_posts_created_idx on public.idn_posts (created_at desc);

alter table public.idn_posts enable row level security;

drop policy if exists "posts readable by signed-in users" on public.idn_posts;
create policy "posts readable by signed-in users"
  on public.idn_posts for select to authenticated using (true);

drop policy if exists "post as yourself" on public.idn_posts;
create policy "post as yourself"
  on public.idn_posts for insert to authenticated
  with check (auth.uid() = author_id);

drop policy if exists "delete your own posts" on public.idn_posts;
create policy "delete your own posts"
  on public.idn_posts for delete to authenticated
  using (auth.uid() = author_id);

-- View counter as a function: a plain UPDATE policy would let anyone
-- rewrite anyone's post row, and two simultaneous viewers would overwrite
-- each other's increment.
-- (the view counter is defined further down, in the part that makes it
--  count each person once instead of every page load)

-- ----------------------------------------------------------------- replies
create table if not exists public.idn_replies (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.idn_posts(id) on delete cascade,
  author_id   uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  body        text not null,
  created_at  timestamptz not null default now(),
  constraint idn_replies_body_len check (char_length(body) between 1 and 1000)
);

create index if not exists idn_replies_post_idx on public.idn_replies (post_id, created_at);

alter table public.idn_replies enable row level security;

drop policy if exists "replies readable by signed-in users" on public.idn_replies;
create policy "replies readable by signed-in users"
  on public.idn_replies for select to authenticated using (true);

drop policy if exists "reply as yourself" on public.idn_replies;
create policy "reply as yourself"
  on public.idn_replies for insert to authenticated
  with check (auth.uid() = author_id);

drop policy if exists "delete your own replies" on public.idn_replies;
create policy "delete your own replies"
  on public.idn_replies for delete to authenticated
  using (auth.uid() = author_id);

-- ----------------------------------------------------------- conversations
create table if not exists public.idn_conversations (
  id           uuid primary key default gen_random_uuid(),
  members      uuid[] not null,
  member_names text[] not null default '{}',
  created_at   timestamptz not null default now(),
  constraint idn_conv_two_members check (array_length(members, 1) = 2)
);

create index if not exists idn_conv_members_idx on public.idn_conversations using gin (members);

alter table public.idn_conversations enable row level security;

-- The important one: you only ever see rows you are a member of.
drop policy if exists "see conversations you are in" on public.idn_conversations;
create policy "see conversations you are in"
  on public.idn_conversations for select to authenticated
  using (auth.uid() = any (members));

drop policy if exists "start a conversation you are in" on public.idn_conversations;
create policy "start a conversation you are in"
  on public.idn_conversations for insert to authenticated
  with check (auth.uid() = any (members));

-- ---------------------------------------------------------------- messages
create table if not exists public.idn_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.idn_conversations(id) on delete cascade,
  sender_id       uuid not null references auth.users(id) on delete cascade,
  sender_name     text not null,
  body            text not null,
  created_at      timestamptz not null default now(),
  constraint idn_messages_body_len check (char_length(body) between 1 and 2000)
);

create index if not exists idn_messages_conv_idx
  on public.idn_messages (conversation_id, created_at);

alter table public.idn_messages enable row level security;

-- Membership is checked against the conversation row, so a message can
-- never be read by somebody outside the thread even if they guess its id.
drop policy if exists "read messages in your conversations" on public.idn_messages;
create policy "read messages in your conversations"
  on public.idn_messages for select to authenticated
  using (exists (
    select 1 from public.idn_conversations c
    where c.id = conversation_id and auth.uid() = any (c.members)
  ));

drop policy if exists "send messages to your conversations" on public.idn_messages;
create policy "send messages to your conversations"
  on public.idn_messages for insert to authenticated
  with check (
    auth.uid() = sender_id
    and exists (
      select 1 from public.idn_conversations c
      where c.id = conversation_id and auth.uid() = any (c.members)
    )
  );

-- ------------------------------------------------------------------- reports
-- Lets anyone flag a post or reply. Reports are write-only for ordinary
-- people: you can file one, but you cannot read anyone else's, which stops
-- the report list itself becoming a thing to browse. Only an admin reading
-- the table in the Supabase dashboard sees them.
create table if not exists public.idn_reports (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null,                   -- 'post' or 'reply'
  target_id    uuid not null,
  reporter_id  uuid references auth.users (id) on delete set null,
  reason       text not null,
  note         text,
  created_at   timestamptz not null default now(),
  constraint idn_reports_kind_ok check (kind in ('post', 'reply')),
  constraint idn_reports_reason_ok check (
    reason in ('spam', 'harassment', 'sexual', 'violence', 'other')
  ),
  constraint idn_reports_note_len check (note is null or char_length(note) <= 500)
);

create index if not exists idn_reports_target_idx
  on public.idn_reports (kind, target_id, created_at);

-- One report per person per thing, so a single person cannot pile on.
create unique index if not exists idn_reports_once_idx
  on public.idn_reports (kind, target_id, reporter_id)
  where reporter_id is not null;

alter table public.idn_reports enable row level security;

-- Anyone signed in may file a report, as themselves.
drop policy if exists idn_reports_insert on public.idn_reports;
create policy idn_reports_insert on public.idn_reports
  for insert to authenticated
  with check (auth.uid() = reporter_id);

-- Deliberately no select policy: with RLS on and nothing granting select,
-- nobody can read this table through the site at all. Read it in the
-- Supabase dashboard (Table editor -> idn_reports), which bypasses RLS.

-- ------------------------------------------------------------------ realtime
-- Lets the site receive new posts/messages without polling.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.idn_posts;
    alter publication supabase_realtime add table public.idn_replies;
    alter publication supabase_realtime add table public.idn_messages;
  end if;
exception when duplicate_object then
  null; -- already added, fine
end $$;

-- ===========================================================================
-- Done. Reload Iodine and open IDN.
-- ===========================================================================


-- ===========================================================================
-- Iodine III - Iodine Network, part 2
--
-- RUN assets/schema.sql FIRST, then run this one. Both are safe to run
-- again later; nothing here deletes anything you already have.
--
-- In Supabase: left sidebar -> SQL Editor -> New query -> paste -> Run.
--
-- This adds: likes and dislikes, reactions on messages, group chats,
-- avatars that show on posts, bans that actually stop people, IDN+, the
-- ramon admin account, and voice calling.
--
-- A NOTE ON STORAGE, since you are on the free plan.
-- Everything here is text and numbers, which is tiny. The thing that
-- fills a free database is images, so posts hold a LINK to an image, not
-- the image itself, and the site refuses anything over 2MB. Views, likes
-- and dislikes are counters on a row rather than one row per click, which
-- is the difference between a few hundred bytes and a few megabytes once
-- people start using it. Anything that only matters to one person on one
-- computer - what you have played, your colours, what you have already
-- seen - never touches the server at all.
-- ===========================================================================

-- ------------------------------------------------------------ avatars
-- Posts and messages carry the author's picture so the feed does not have
-- to look up every author separately (which on a feed of 40 posts is 40
-- extra queries).
alter table public.idn_posts    add column if not exists author_pfp text;
alter table public.idn_replies  add column if not exists author_pfp text;
alter table public.idn_messages add column if not exists sender_pfp text;

-- ------------------------------------------------- likes and dislikes
-- Two counters on the post, plus a small row recording who voted so a
-- person cannot vote twice and can change their mind. The row holds no
-- text, so even heavy use stays cheap.
alter table public.idn_posts add column if not exists likes    integer not null default 0;
alter table public.idn_posts add column if not exists dislikes integer not null default 0;

create table if not exists public.idn_votes (
  post_id   uuid not null references public.idn_posts(id) on delete cascade,
  voter_id  uuid not null references auth.users(id) on delete cascade,
  value     smallint not null,
  primary key (post_id, voter_id),
  constraint idn_votes_value_ok check (value in (-1, 1))
);

alter table public.idn_votes enable row level security;

drop policy if exists idn_votes_own on public.idn_votes;
create policy idn_votes_own on public.idn_votes
  for all to authenticated
  using (auth.uid() = voter_id)
  with check (auth.uid() = voter_id);

-- Casting a vote, changing it, or taking it back - all in one call, so
-- the counters can never drift out of step with the votes.
-- NOTE ON THE PARAMETER NAMES. They are all prefixed p_ on purpose.
-- PostgreSQL refuses a query where a parameter name also matches a
-- column name in the same statement - "column reference is ambiguous" -
-- and the first version of this used `post_id` and `value`, which are
-- both column names in idn_votes. The whole function failed, so no vote
-- ever registered. Prefixing makes the collision impossible.
-- Dropped first for the same reason: an earlier version of this file
-- returned different column names, and changing those is also a return
-- type change as far as PostgreSQL is concerned.
drop function if exists public.idn_vote(uuid, smallint);

create or replace function public.idn_vote(p_post_id uuid, p_value smallint)
returns table (n_likes integer, n_dislikes integer, my_vote smallint)
language plpgsql
security definer
set search_path = public
as $$
declare
  previous smallint := 0;
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if p_value not in (-1, 0, 1) then
    raise exception 'bad vote';
  end if;

  select v.value into previous from public.idn_votes v
    where v.post_id = p_post_id and v.voter_id = me;
  previous := coalesce(previous, 0);

  if p_value = 0 then
    delete from public.idn_votes v
      where v.post_id = p_post_id and v.voter_id = me;
  else
    insert into public.idn_votes (post_id, voter_id, value)
      values (p_post_id, me, p_value)
      on conflict (post_id, voter_id) do update set value = excluded.value;
  end if;

  update public.idn_posts p set
    likes    = greatest(0, p.likes    + (case when p_value   =  1 then 1 else 0 end)
                                      - (case when previous  =  1 then 1 else 0 end)),
    dislikes = greatest(0, p.dislikes + (case when p_value   = -1 then 1 else 0 end)
                                      - (case when previous  = -1 then 1 else 0 end))
    where p.id = p_post_id;

  return query
    select p.likes, p.dislikes, p_value
    from public.idn_posts p where p.id = p_post_id;
end;
$$;

grant execute on function public.idn_vote(uuid, smallint) to authenticated;

-- ---------------------------------------------------- views that work
-- The old counter went up every single time a post appeared on screen,
-- including on every refresh, which made the number meaningless. This
-- one counts a person once per post, so "views" means people.
create table if not exists public.idn_views (
  post_id    uuid not null references public.idn_posts(id) on delete cascade,
  viewer_id  uuid not null references auth.users(id) on delete cascade,
  primary key (post_id, viewer_id)
);

alter table public.idn_views enable row level security;

drop policy if exists idn_views_own on public.idn_views;
create policy idn_views_own on public.idn_views
  for all to authenticated
  using (auth.uid() = viewer_id)
  with check (auth.uid() = viewer_id);

-- DROP FIRST. schema.sql created this returning void; this version
-- returns the new total instead. PostgreSQL refuses to change a return
-- type with CREATE OR REPLACE - "cannot change return type of existing
-- function" - and that error stopped this whole file part-way through,
-- which is why idn_plus and everything after it never got created.
drop function if exists public.idn_bump_views(uuid);

create or replace function public.idn_bump_views(p_post_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  fresh boolean := false;
  total integer;
begin
  if me is not null then
    insert into public.idn_views (post_id, viewer_id)
      values (p_post_id, me)
      on conflict do nothing;
    fresh := found;
  end if;

  if fresh then
    update public.idn_posts p set views = p.views + 1 where p.id = p_post_id;
  end if;

  select p.views into total from public.idn_posts p where p.id = p_post_id;
  return coalesce(total, 0);
end;
$$;

grant execute on function public.idn_bump_views(uuid) to authenticated;

-- -------------------------------------------------------- group chats
-- The old rule was "a conversation has exactly two people". Dropping it
-- is all a group chat needs; everything else already works off the member
-- list. A name is optional - without one the site shows the members.
alter table public.idn_conversations drop constraint if exists idn_conv_two_members;
alter table public.idn_conversations add column if not exists title text;
alter table public.idn_conversations add column if not exists owner_id uuid references auth.users(id) on delete set null;

alter table public.idn_conversations drop constraint if exists idn_conv_size;
alter table public.idn_conversations add constraint idn_conv_size
  check (array_length(members, 1) between 2 and 25);

-- Members can rename a group and add people; the member list is the
-- permission, same as it already is for reading.
drop policy if exists idn_conv_update on public.idn_conversations;
create policy idn_conv_update on public.idn_conversations
  for update to authenticated
  using (auth.uid() = any (members))
  with check (auth.uid() = any (members));

-- ---------------------------------------------------- chat reactions
-- One row per person per emoji per message. Kept to a short fixed set so
-- this cannot become a place to type things.
create table if not exists public.idn_reactions (
  message_id uuid not null references public.idn_messages(id) on delete cascade,
  reactor_id uuid not null references auth.users(id) on delete cascade,
  emoji      text not null,
  primary key (message_id, reactor_id, emoji),
  constraint idn_reactions_known check (emoji in ('👍','❤️','😂','😮','😢','🔥'))
);

alter table public.idn_reactions enable row level security;

-- You may react in a conversation you are part of, and only as yourself.
drop policy if exists idn_reactions_read on public.idn_reactions;
create policy idn_reactions_read on public.idn_reactions
  for select to authenticated
  using (
    exists (
      select 1 from public.idn_messages m
      join public.idn_conversations c on c.id = m.conversation_id
      where m.id = message_id and auth.uid() = any (c.members)
    )
  );

drop policy if exists idn_reactions_write on public.idn_reactions;
create policy idn_reactions_write on public.idn_reactions
  for all to authenticated
  using (auth.uid() = reactor_id)
  with check (
    auth.uid() = reactor_id
    and exists (
      select 1 from public.idn_messages m
      join public.idn_conversations c on c.id = m.conversation_id
      where m.id = message_id and auth.uid() = any (c.members)
    )
  );

-- --------------------------------------------------- short-form videos
-- The scrolling video tab. Like posts, this stores a LINK, never a file -
-- video would eat a free plan in an afternoon.
create table if not exists public.idn_clips (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  author_pfp  text,
  caption     text not null default '',
  video_url   text not null,
  poster_url  text,
  views       integer not null default 0,
  likes       integer not null default 0,
  created_at  timestamptz not null default now(),
  constraint idn_clips_caption_len check (char_length(caption) <= 300)
);

create index if not exists idn_clips_new_idx on public.idn_clips (created_at desc);

alter table public.idn_clips enable row level security;

drop policy if exists idn_clips_read on public.idn_clips;
create policy idn_clips_read on public.idn_clips
  for select to anon, authenticated using (true);

drop policy if exists idn_clips_insert on public.idn_clips;
create policy idn_clips_insert on public.idn_clips
  for insert to authenticated with check (auth.uid() = author_id);

drop policy if exists idn_clips_delete on public.idn_clips;
create policy idn_clips_delete on public.idn_clips
  for delete to authenticated using (auth.uid() = author_id);

-- -------------------------------------------------------- admin + bans
-- Who may use the admin tab. Seeded with ramon and metalworks by display
-- name; the site checks this table, so adding an admin is a row here.
create table if not exists public.idn_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  added_at   timestamptz not null default now()
);

alter table public.idn_admins enable row level security;

-- Anyone may ask "am I an admin"; only the database can write the table.
drop policy if exists idn_admins_read on public.idn_admins;
create policy idn_admins_read on public.idn_admins
  for select to authenticated using (true);

create or replace function public.idn_is_admin(who uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.idn_admins a where a.user_id = who);
$$;

grant execute on function public.idn_is_admin(uuid) to authenticated;

-- Bans. A ban with no end date is permanent.
create table if not exists public.idn_bans (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  reason     text,
  until      timestamptz,
  banned_by  uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.idn_bans enable row level security;

-- You can see your own ban, which is how the site tells you about it.
-- Admins see all of them.
drop policy if exists idn_bans_read on public.idn_bans;
create policy idn_bans_read on public.idn_bans
  for select to authenticated
  using (auth.uid() = user_id or public.idn_is_admin());

create or replace function public.idn_my_ban()
returns table (reason text, until timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select b.reason, b.until from public.idn_bans b
   where b.user_id = auth.uid()
     and (b.until is null or b.until > now());
$$;

grant execute on function public.idn_my_ban() to authenticated;

-- A ban has to actually stop someone, which means the database refusing
-- their writes - hiding the buttons in the page stops nobody. Every
-- write policy below now also asks "are they banned".
create or replace function public.idn_blocked(who uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.idn_bans b
     where b.user_id = who and (b.until is null or b.until > now())
  );
$$;

grant execute on function public.idn_blocked(uuid) to authenticated;

drop policy if exists idn_posts_insert on public.idn_posts;
create policy idn_posts_insert on public.idn_posts
  for insert to authenticated
  with check (auth.uid() = author_id and not public.idn_blocked());

drop policy if exists idn_replies_insert on public.idn_replies;
create policy idn_replies_insert on public.idn_replies
  for insert to authenticated
  with check (auth.uid() = author_id and not public.idn_blocked());

drop policy if exists idn_messages_insert on public.idn_messages;
create policy idn_messages_insert on public.idn_messages
  for insert to authenticated
  with check (auth.uid() = sender_id and not public.idn_blocked());

drop policy if exists idn_clips_insert on public.idn_clips;
create policy idn_clips_insert on public.idn_clips
  for insert to authenticated
  with check (auth.uid() = author_id and not public.idn_blocked());

-- Admins can ban and unban. Deliberately not "anyone signed in".
drop policy if exists idn_bans_write on public.idn_bans;
create policy idn_bans_write on public.idn_bans
  for all to authenticated
  using (public.idn_is_admin())
  with check (public.idn_is_admin());

-- Admins can delete anyone's post, reply or clip.
drop policy if exists idn_posts_admin_delete on public.idn_posts;
create policy idn_posts_admin_delete on public.idn_posts
  for delete to authenticated
  using (auth.uid() = author_id or public.idn_is_admin());

drop policy if exists idn_replies_admin_delete on public.idn_replies;
create policy idn_replies_admin_delete on public.idn_replies
  for delete to authenticated
  using (auth.uid() = author_id or public.idn_is_admin());

-- Admins can read reports (nobody else can, by design).
drop policy if exists idn_reports_admin_read on public.idn_reports;
create policy idn_reports_admin_read on public.idn_reports
  for select to authenticated
  using (public.idn_is_admin());

-- -------------------------------------------------------------- IDN+
-- Doubles how many game collections someone sees. Either an admin grants
-- it, or the person redeems a key.
create table if not exists public.idn_plus (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  until      timestamptz,
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.idn_plus enable row level security;

drop policy if exists idn_plus_read on public.idn_plus;
create policy idn_plus_read on public.idn_plus
  for select to authenticated
  using (auth.uid() = user_id or public.idn_is_admin());

drop policy if exists idn_plus_write on public.idn_plus;
create policy idn_plus_write on public.idn_plus
  for all to authenticated
  using (public.idn_is_admin())
  with check (public.idn_is_admin());

-- Keys an admin hands out. A key is single use: redeeming it stamps who
-- used it, and a used key cannot be redeemed again.
create table if not exists public.idn_plus_keys (
  code       text primary key,
  months     integer not null default 1,
  used_by    uuid references auth.users(id) on delete set null,
  used_at    timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint idn_plus_keys_months_ok check (months between 1 and 120)
);

alter table public.idn_plus_keys enable row level security;

-- Nobody may browse the key list - that would be the whole point gone.
-- Admins can make them; redeeming happens through the function below,
-- which checks the code without ever handing the table over.
drop policy if exists idn_plus_keys_admin on public.idn_plus_keys;
create policy idn_plus_keys_admin on public.idn_plus_keys
  for all to authenticated
  using (public.idn_is_admin())
  with check (public.idn_is_admin());

create or replace function public.idn_redeem_plus(code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  row_months integer;
begin
  if me is null then return 'Sign in first.'; end if;

  select k.months into row_months from public.idn_plus_keys k
    where upper(k.code) = upper(idn_redeem_plus.code) and k.used_by is null
    for update;

  if row_months is null then
    return 'That key is not valid, or it has already been used.';
  end if;

  update public.idn_plus_keys k
     set used_by = me, used_at = now()
   where upper(k.code) = upper(idn_redeem_plus.code);

  insert into public.idn_plus (user_id, until)
    values (me, now() + (row_months || ' months')::interval)
    on conflict (user_id) do update
      set until = greatest(coalesce(public.idn_plus.until, now()), now())
                  + (row_months || ' months')::interval;

  return 'ok';
end;
$$;

grant execute on function public.idn_redeem_plus(text) to authenticated;

create or replace function public.idn_has_plus(who uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.idn_plus p
     where p.user_id = who and (p.until is null or p.until > now())
  );
$$;

grant execute on function public.idn_has_plus(uuid) to authenticated;

-- ----------------------------------------------------------- calling
-- Voice calls connect the two browsers directly to each other; this table
-- only carries the handshake that lets them find each other. Rows are
-- throwaway - delete anything older than a few minutes and nothing is
-- lost. No audio ever passes through here.
create table if not exists public.idn_call_signals (
  id              bigserial primary key,
  conversation_id uuid not null references public.idn_conversations(id) on delete cascade,
  sender_id       uuid not null references auth.users(id) on delete cascade,
  kind            text not null,
  payload         jsonb not null,
  created_at      timestamptz not null default now(),
  constraint idn_call_kind_ok check (kind in ('offer', 'answer', 'ice', 'hangup', 'ring'))
);

create index if not exists idn_call_conv_idx
  on public.idn_call_signals (conversation_id, created_at);

alter table public.idn_call_signals enable row level security;

drop policy if exists idn_call_members on public.idn_call_signals;
create policy idn_call_members on public.idn_call_signals
  for all to authenticated
  using (
    exists (select 1 from public.idn_conversations c
             where c.id = conversation_id and auth.uid() = any (c.members))
  )
  with check (
    auth.uid() = sender_id
    and exists (select 1 from public.idn_conversations c
                 where c.id = conversation_id and auth.uid() = any (c.members))
  );

-- Housekeeping, so the free plan is not slowly filled by old handshakes.
create or replace function public.idn_sweep_calls()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.idn_call_signals where created_at < now() - interval '10 minutes';
$$;

grant execute on function public.idn_sweep_calls() to authenticated;


-- ------------------------------------------------------- copies of the site
-- Records which address an account is using the site from. If someone
-- takes the files and puts them on their own domain, the accounts on that
-- copy show up in the admin tab.
--
-- A LIST ONLY. Nobody is banned for appearing here, and that is on
-- purpose: a school's own proxy, a preview deploy and a stolen copy look
-- identical from here, so acting on it automatically would hit your own
-- users first. Ramon and metalworks look at the list and decide.
create table if not exists public.idn_copies (
  user_id      uuid not null references auth.users(id) on delete cascade,
  host         text not null,
  display_name text,
  last_seen    timestamptz not null default now(),
  primary key (user_id, host)
);

create index if not exists idn_copies_host_idx on public.idn_copies (host, last_seen desc);

alter table public.idn_copies enable row level security;

-- Anyone may record their own; only admins may read the list.
drop policy if exists idn_copies_write on public.idn_copies;
create policy idn_copies_write on public.idn_copies
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists idn_copies_admin_read on public.idn_copies;
create policy idn_copies_admin_read on public.idn_copies
  for select to authenticated
  using (public.idn_is_admin() or auth.uid() = user_id);

-- ------------------------------------------------------------ realtime
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.idn_call_signals; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.idn_reactions;    exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.idn_clips;        exception when duplicate_object then null; end;
  end if;
end $$;

-- ===========================================================================
-- LAST STEP - make yourself an admin.
--
-- Accounts have to exist before they can be made admins, so sign in once
-- as each of them first, then run this. It matches on the name you signed
-- up with.
-- ===========================================================================
insert into public.idn_admins (user_id)
select p.id from public.idn_profiles p
 where lower(p.display_name) in ('ramon', 'metalworks')
on conflict (user_id) do nothing;

-- Check it worked:
--   select display_name from idn_profiles
--    where id in (select user_id from idn_admins);


-- ===========================================================================
-- Iodine III - Iodine Network, part 3
--
-- RUN schema.sql, THEN schema-v2.sql, THEN THIS ONE.
-- Safe to run again at any time; nothing here deletes anything.
-- In Supabase: SQL Editor -> New query -> paste -> Run.
--
-- This file is about IDN+ and the broadcasts (global message, pop-up,
-- jumpscare), and it fixes two things that never worked.
-- ===========================================================================

-- ===========================================================================
-- IDN+ : who can give it, and who starts with it
-- ===========================================================================

-- Giving someone IDN+ used to be a straight write into the idn_plus
-- table. That only worked for an admin, and it needed the page to look
-- the person up first and then write - two steps that could half-happen.
-- Doing it in one function fixes both: the dealer can use it too, and
-- the lookup and the write cannot come apart.

-- The IDN+ dealer. NOT an admin: the only thing this account can do is
-- hand out IDN+ and make keys. Bans, reports and everything else in the
-- admin panel stay shut to them.
create or replace function public.idn_is_dealer(who uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.idn_profiles p
     where p.id = who and lower(p.display_name) = 'idnplusdealer'
  );
$$;

grant execute on function public.idn_is_dealer(uuid) to authenticated;

-- Hands IDN+ to someone by name. Admins and the dealer only.
-- Granting again extends rather than replacing.
create or replace function public.idn_grant_plus(p_name text, p_months integer)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
  months integer := greatest(1, least(120, coalesce(p_months, 1)));
begin
  if not (public.idn_is_admin() or public.idn_is_dealer()) then
    return 'Only an admin or the IDN+ dealer can do that.';
  end if;

  select p.id into target from public.idn_profiles p
   where lower(p.display_name) = lower(trim(p_name))
   limit 1;

  if target is null then
    return 'No IDN user called "' || p_name || '".';
  end if;

  insert into public.idn_plus (user_id, until, granted_by)
    values (target, now() + (months || ' months')::interval, auth.uid())
    on conflict (user_id) do update
      set until = greatest(coalesce(public.idn_plus.until, now()), now())
                  + (months || ' months')::interval,
          granted_by = auth.uid();

  return 'ok';
end;
$$;

grant execute on function public.idn_grant_plus(text, integer) to authenticated;

create or replace function public.idn_revoke_plus(p_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
begin
  if not (public.idn_is_admin() or public.idn_is_dealer()) then
    return 'Only an admin or the IDN+ dealer can do that.';
  end if;

  select p.id into target from public.idn_profiles p
   where lower(p.display_name) = lower(trim(p_name)) limit 1;

  if target is null then return 'No IDN user called "' || p_name || '".'; end if;

  delete from public.idn_plus where user_id = target;
  return 'ok';
end;
$$;

grant execute on function public.idn_revoke_plus(text) to authenticated;

-- Who currently has it.
create or replace function public.idn_plus_list()
returns table (who text, ends_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select p.display_name, pl.until
    from public.idn_plus pl
    join public.idn_profiles p on p.id = pl.user_id
   where public.idn_is_admin() or public.idn_is_dealer()
   order by pl.until desc nulls first
   limit 200;
$$;

grant execute on function public.idn_plus_list() to authenticated;

-- The dealer may make keys as well as grant directly.
drop policy if exists idn_plus_keys_admin on public.idn_plus_keys;
create policy idn_plus_keys_admin on public.idn_plus_keys
  for all to authenticated
  using (public.idn_is_admin() or public.idn_is_dealer())
  with check (public.idn_is_admin() or public.idn_is_dealer());

-- ------------------------------------------------- everyone gets a day
-- A free day of IDN+ on signing up, and the same for everyone who
-- already has an account. It is a trigger rather than something the page
-- does, so it cannot be skipped and cannot be claimed twice.
create or replace function public.idn_welcome_plus()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  forever boolean := lower(new.display_name) in ('ramon', 'metalworks');
begin
  /* The owners' accounts keep it permanently (a null end date), whether
     they existed before this file was run or sign up afterwards. The
     backfill below only catches accounts that already exist, so without
     this an owner signing up later would get the same one day as
     everybody else. */
  insert into public.idn_plus (user_id, until)
    values (new.id, case when forever then null else now() + interval '1 day' end)
    on conflict (user_id) do update
      set until = case when forever then null else public.idn_plus.until end;
  return new;
end;
$$;

drop trigger if exists idn_welcome_plus_trg on public.idn_profiles;
create trigger idn_welcome_plus_trg
  after insert on public.idn_profiles
  for each row execute function public.idn_welcome_plus();

-- Everyone who already signed up gets the same free day.
insert into public.idn_plus (user_id, until)
select p.id, now() + interval '1 day' from public.idn_profiles p
on conflict (user_id) do nothing;

-- ramon and metalworks keep it for good. A null end date means no end.
insert into public.idn_plus (user_id, until)
select p.id, null from public.idn_profiles p
 where lower(p.display_name) in ('ramon', 'metalworks')
on conflict (user_id) do update set until = null;


-- ===========================================================================
-- Banning, in one call
--
-- Banning used to be: look the person up from the page, then write a row.
-- Two steps, either of which could fail quietly, and the write needed the
-- admin check to pass from the browser's side. One function fixes all of
-- that - the check, the lookup and the write happen together, and it
-- answers in plain words when something is wrong.
-- ===========================================================================

create or replace function public.idn_ban(p_name text, p_reason text, p_hours integer)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
  ends timestamptz;
begin
  if not public.idn_is_admin() then
    return 'Only an admin can ban someone.';
  end if;

  select p.id into target from public.idn_profiles p
   where lower(p.display_name) = lower(trim(p_name)) limit 1;

  if target is null then
    return 'No IDN user called "' || p_name || '".';
  end if;

  if public.idn_is_admin(target) then
    return 'That account is an admin. Remove them from idn_admins first.';
  end if;

  if p_hours is null or p_hours <= 0 then ends := null;             -- forever
  else ends := now() + (p_hours || ' hours')::interval;
  end if;

  insert into public.idn_bans (user_id, reason, until, banned_by)
    values (target, nullif(trim(coalesce(p_reason, '')), ''), ends, auth.uid())
    on conflict (user_id) do update
      set reason = excluded.reason,
          until = excluded.until,
          banned_by = excluded.banned_by,
          created_at = now();

  return 'ok';
end;
$$;

grant execute on function public.idn_ban(text, text, integer) to authenticated;

create or replace function public.idn_unban(p_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
begin
  if not public.idn_is_admin() then
    return 'Only an admin can do that.';
  end if;

  select p.id into target from public.idn_profiles p
   where lower(p.display_name) = lower(trim(p_name)) limit 1;

  if target is null then return 'No IDN user called "' || p_name || '".'; end if;

  delete from public.idn_bans where user_id = target;
  return 'ok';
end;
$$;

grant execute on function public.idn_unban(text) to authenticated;

-- The ban list, with names rather than raw ids.
create or replace function public.idn_ban_list()
returns table (who text, reason text, ends_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select p.display_name, b.reason, b.until
    from public.idn_bans b
    join public.idn_profiles p on p.id = b.user_id
   where public.idn_is_admin()
   order by b.created_at desc
   limit 200;
$$;

grant execute on function public.idn_ban_list() to authenticated;

-- ===========================================================================
-- Profile pictures
--
-- A picture set at sign-up went into the account's metadata and nowhere
-- else, and there was no way to change it afterwards. This writes it to
-- the profile row, which is what posts and messages read.
-- ===========================================================================

create or replace function public.idn_set_avatar(p_url text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return 'Sign in first.'; end if;
  if p_url is not null and char_length(p_url) > 400000 then
    return 'That picture is too big.';
  end if;

  update public.idn_profiles set pfp_url = p_url where id = auth.uid();
  if not found then
    insert into public.idn_profiles (id, display_name, pfp_url)
      values (auth.uid(),
              coalesce((select raw_user_meta_data->>'display_name'
                          from auth.users where id = auth.uid()), 'user'),
              p_url)
      on conflict (id) do update set pfp_url = excluded.pfp_url;
  end if;

  return 'ok';
end;
$$;

grant execute on function public.idn_set_avatar(text) to authenticated;

-- Posts and messages carry the author's picture so a feed of forty does
-- not mean forty extra lookups. Changing your picture updates the ones
-- you have already sent, so your face does not go stale across the feed.
create or replace function public.idn_sync_avatar()
returns void
language sql
security definer
set search_path = public
as $$
  update public.idn_posts    set author_pfp = p.pfp_url
    from public.idn_profiles p where p.id = auth.uid() and idn_posts.author_id = auth.uid();
  update public.idn_replies  set author_pfp = p.pfp_url
    from public.idn_profiles p where p.id = auth.uid() and idn_replies.author_id = auth.uid();
  update public.idn_messages set sender_pfp = p.pfp_url
    from public.idn_profiles p where p.id = auth.uid() and idn_messages.sender_id = auth.uid();
$$;

grant execute on function public.idn_sync_avatar() to authenticated;

-- ===========================================================================
-- Broadcasts: global message, pop-up, jumpscare
--
-- These only ever fired on the admin's own screen, because there was
-- nowhere to put them. Now they are rows everyone's page watches, so
-- sending one reaches every person with the site open.
-- ===========================================================================

create table if not exists public.idn_broadcasts (
  id          bigserial primary key,
  kind        text not null,
  body        text,
  image_url   text,
  sent_by     uuid references auth.users(id) on delete set null,
  sender_name text,
  expires_at  timestamptz not null default (now() + interval '1 hour'),
  created_at  timestamptz not null default now(),
  constraint idn_broadcasts_kind_ok check (kind in ('message', 'popup', 'jumpscare')),
  constraint idn_broadcasts_body_len check (body is null or char_length(body) <= 500)
);

create index if not exists idn_broadcasts_live_idx
  on public.idn_broadcasts (created_at desc);

alter table public.idn_broadcasts enable row level security;

-- Everyone reads them; only admins send them.
drop policy if exists idn_broadcasts_read on public.idn_broadcasts;
create policy idn_broadcasts_read on public.idn_broadcasts
  for select to anon, authenticated using (true);

drop policy if exists idn_broadcasts_write on public.idn_broadcasts;
create policy idn_broadcasts_write on public.idn_broadcasts
  for all to authenticated
  using (public.idn_is_admin())
  with check (public.idn_is_admin());

-- The newest one still inside its lifetime. The page asks for this and
-- shows anything it has not shown before.
create or replace function public.idn_latest_broadcast()
returns table (id bigint, kind text, body text, image_url text,
               sender_name text, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, b.kind, b.body, b.image_url, b.sender_name, b.created_at
    from public.idn_broadcasts b
   where b.expires_at > now()
   order by b.created_at desc
   limit 1;
$$;

grant execute on function public.idn_latest_broadcast() to anon, authenticated;

-- Housekeeping, so this cannot slowly fill a free plan.
create or replace function public.idn_sweep_broadcasts()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.idn_broadcasts where created_at < now() - interval '7 days';
$$;

grant execute on function public.idn_sweep_broadcasts() to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.idn_broadcasts; exception when duplicate_object then null; end;
  end if;
end $$;

-- ===========================================================================
-- Done. Reload Iodine.
--
-- Check it worked:
--   select display_name from idn_profiles
--    where id in (select user_id from idn_plus);
-- ===========================================================================

-- ===========================================================================
-- Save data: one row per account, holding that person's game saves.
--
-- Kept deliberately small, because this runs on a free plan:
--   * ONE row per person, overwritten - never a history.
--   * The browser gzips it before sending, so most saves are a few KB.
--   * Hard cap of 200 KB per person, enforced here, not just in the page.
-- The browser keeps its own copy too, so if this server is down or full,
-- nothing is lost and the person can still export to a file.
-- ===========================================================================
create table if not exists public.idn_saves (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       text not null,
  updated_at timestamptz not null default now()
);

-- added separately so re-running this file on an older copy still adds it
alter table public.idn_saves drop constraint if exists idn_saves_size;
alter table public.idn_saves add constraint idn_saves_size check (length(data) <= 204800);

alter table public.idn_saves enable row level security;

drop policy if exists idn_saves_read  on public.idn_saves;
drop policy if exists idn_saves_write on public.idn_saves;
drop policy if exists idn_saves_edit  on public.idn_saves;
drop policy if exists idn_saves_drop  on public.idn_saves;

-- only ever your own row
create policy idn_saves_read on public.idn_saves
  for select to authenticated using (user_id = auth.uid());
create policy idn_saves_write on public.idn_saves
  for insert to authenticated with check (user_id = auth.uid() and not public.idn_blocked());
create policy idn_saves_edit on public.idn_saves
  for update to authenticated using (user_id = auth.uid())
  with check (user_id = auth.uid() and not public.idn_blocked());
create policy idn_saves_drop on public.idn_saves
  for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.idn_saves to authenticated;

-- ===========================================================================
-- Pictures and GIFs in private messages.
-- Stored inline like post pictures, but kept smaller: photos are shrunk in
-- the browser to about 300 KB, and a GIF (kept as-is so it still moves) may
-- be up to 1 MB. The server enforces the ceiling and that it really is an
-- image, so an edited page cannot push anything else in.
-- ===========================================================================
alter table public.idn_messages add column if not exists image_url text;

alter table public.idn_messages drop constraint if exists idn_messages_body_len;
alter table public.idn_messages drop constraint if exists idn_messages_content;
alter table public.idn_messages add constraint idn_messages_content check (
  char_length(body) <= 2000
  and (char_length(body) >= 1 or image_url is not null)
);

alter table public.idn_messages drop constraint if exists idn_messages_image;
alter table public.idn_messages add constraint idn_messages_image check (
  image_url is null
  or (image_url ~ '^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=]+$'
      and length(image_url) <= 1400000)
);

-- A flag the message list can read without pulling every picture down.
-- Pictures are then fetched one at a time as they scroll into view, which
-- keeps a long chat full of GIFs from costing megabytes every time it opens.
alter table public.idn_messages
  add column if not exists has_image boolean generated always as (image_url is not null) stored;

-- ===========================================================================
-- IDN+ keys: strictly one use each, and no guessing.
--   * redeeming is ONE atomic statement: the key is claimed and stamped in
--     the same step, so two people pressing at the same moment cannot
--     both get it
--   * once used, a key can never be un-used - not even by an admin or the
--     dealer editing the table - so it cannot be recycled
--   * codes are stored upper-case and must be unique ignoring case
--   * 10 wrong keys in an hour and that account has to wait, so nobody
--     can sit there trying codes until one works
-- ===========================================================================
update public.idn_plus_keys set code = upper(code) where code <> upper(code);
create unique index if not exists idn_plus_keys_code_upper on public.idn_plus_keys (upper(code));

create or replace function public.idn_plus_keys_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.code := upper(new.code);
    new.used_by := null;
    new.used_at := null;
    return new;
  end if;
  if old.used_by is not null and (new.used_by is distinct from old.used_by
                                  or new.used_at is distinct from old.used_at
                                  or new.code <> old.code) then
    raise exception 'That key has been used. Used keys cannot be changed or reused.';
  end if;
  return new;
end;
$$;

drop trigger if exists idn_plus_keys_guard on public.idn_plus_keys;
create trigger idn_plus_keys_guard before insert or update on public.idn_plus_keys
  for each row execute function public.idn_plus_keys_guard();

create table if not exists public.idn_key_attempts (
  user_id uuid not null references auth.users(id) on delete cascade,
  at      timestamptz not null default now()
);
create index if not exists idn_key_attempts_idx on public.idn_key_attempts (user_id, at);
alter table public.idn_key_attempts enable row level security;
-- no policies: only the function below touches it

create or replace function public.idn_redeem_plus(code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  row_months integer;
  wrong integer;
begin
  if me is null then return 'Sign in first.'; end if;

  delete from public.idn_key_attempts where at < now() - interval '1 day';
  select count(*) into wrong from public.idn_key_attempts
   where user_id = me and at > now() - interval '1 hour';
  if wrong >= 10 then
    return 'Too many wrong keys. Try again in an hour.';
  end if;

  update public.idn_plus_keys k
     set used_by = me, used_at = now()
   where upper(k.code) = upper(trim(idn_redeem_plus.code))
     and k.used_by is null
  returning k.months into row_months;

  if row_months is null then
    insert into public.idn_key_attempts (user_id) values (me);
    return 'That key is not valid, or it has already been used.';
  end if;

  insert into public.idn_plus (user_id, until)
    values (me, now() + (row_months || ' months')::interval)
    on conflict (user_id) do update
      set until = greatest(coalesce(public.idn_plus.until, now()), now())
                  + (row_months || ' months')::interval;

  return 'ok';
end;
$$;

grant execute on function public.idn_redeem_plus(text) to authenticated;

-- ===========================================================================
-- Chats: deleting them, adding people to groups, and honest member names.
-- ===========================================================================

-- A chat is a group if it was made as one, even after it shrinks to two.
alter table public.idn_conversations add column if not exists is_group boolean not null default false;
update public.idn_conversations set is_group = true
 where not is_group and (title is not null or array_length(members, 1) > 2);

-- Member names always come from the real profiles, never from the page,
-- so nobody can start a chat that claims to include someone it does not.
create or replace function public.idn_conv_names()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.member_names := array(
    select coalesce(p.display_name, 'Unknown')
      from unnest(new.members) with ordinality as m(id, n)
      left join public.idn_profiles p on p.id = m.id
     order by m.n);
  return new;
end;
$$;
drop trigger if exists idn_conv_names on public.idn_conversations;
create trigger idn_conv_names before insert or update of members on public.idn_conversations
  for each row execute function public.idn_conv_names();

-- Editing a chat row directly is limited to renaming it. Adding people and
-- leaving go through the functions below, which check who is asking.
revoke update on public.idn_conversations from authenticated;
grant update (title) on public.idn_conversations to authenticated;

-- "Deleted" one-to-one chats are hidden for that person only; the other
-- person keeps theirs. A new message brings it back.
create table if not exists public.idn_conv_hidden (
  user_id         uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.idn_conversations(id) on delete cascade,
  primary key (user_id, conversation_id)
);
alter table public.idn_conv_hidden enable row level security;
drop policy if exists idn_conv_hidden_own on public.idn_conv_hidden;
create policy idn_conv_hidden_own on public.idn_conv_hidden
  for select to authenticated using (user_id = auth.uid());
grant select on public.idn_conv_hidden to authenticated;

create or replace function public.idn_conv_unhide()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.idn_conv_hidden where conversation_id = new.conversation_id;
  return new;
end;
$$;
drop trigger if exists idn_conv_unhide on public.idn_messages;
create trigger idn_conv_unhide after insert on public.idn_messages
  for each row execute function public.idn_conv_unhide();

-- Leave a group, or hide a one-to-one chat.
create or replace function public.idn_leave_conversation(p_conv uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  c public.idn_conversations%rowtype;
begin
  if me is null then return 'Sign in first.'; end if;
  select * into c from public.idn_conversations where id = p_conv for update;
  if not found or not (me = any (c.members)) then return 'You are not in that chat.'; end if;

  if not c.is_group then
    insert into public.idn_conv_hidden (user_id, conversation_id) values (me, p_conv)
      on conflict do nothing;
    return 'ok';
  end if;

  if array_length(c.members, 1) <= 2 then
    -- the last two: leaving would break the size rule, so the chat goes
    delete from public.idn_conversations where id = p_conv;
    return 'ok';
  end if;

  update public.idn_conversations
     set members = array_remove(members, me)
   where id = p_conv;
  return 'ok';
end;
$$;
grant execute on function public.idn_leave_conversation(uuid) to authenticated;

-- Add people to a group you are in, by IDN ID.
create or replace function public.idn_add_to_group(p_conv uuid, p_names text[])
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  c public.idn_conversations%rowtype;
  n text;
  who uuid;
  added integer := 0;
begin
  if me is null then return 'Sign in first.'; end if;
  if public.idn_blocked() then return 'You cannot do that right now.'; end if;
  select * into c from public.idn_conversations where id = p_conv for update;
  if not found or not (me = any (c.members)) then return 'You are not in that chat.'; end if;
  if not c.is_group then return 'You can only add people to a group chat.'; end if;

  foreach n in array coalesce(p_names, '{}') loop
    select p.id into who from public.idn_profiles p where lower(p.display_name) = lower(trim(n)) limit 1;
    if who is null then return 'No IDN user called "' || trim(n) || '".'; end if;
    if not (who = any (c.members)) then
      c.members := array_append(c.members, who);
      added := added + 1;
    end if;
  end loop;

  if array_length(c.members, 1) > 25 then return 'A group can have at most 25 people.'; end if;
  if added = 0 then return 'They are already in this chat.'; end if;

  update public.idn_conversations set members = c.members where id = p_conv;
  return 'ok';
end;
$$;
grant execute on function public.idn_add_to_group(uuid, text[]) to authenticated;
