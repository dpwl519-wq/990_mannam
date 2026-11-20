-- ============================================================================
--  990 인연 · 운영자 매칭 v2 (증분 SQL)
-- ----------------------------------------------------------------------------
--  사용법
--   1) Supabase 대시보드 → SQL Editor → New query
--   2) 이 파일 전체를 붙여넣고 RUN
--   3) 여러 번 다시 실행해도 안전합니다 (idempotent)
--
--  이 파일이 하는 일
--   ① 신규 가입 기본 매칭권 3장 → 2장 (profiles.match_tickets 기본값)
--   ② 매일 매칭 시간제 — 10:00 오픈 · 20:00 마감 (Asia/Seoul)
--        · 운영자(admin)는 시간 제한 없이 확인 (테스트·미리보기)
--        · 운영자 콘솔에서 전체 회원 시간제를 잠시 끌 수 있음 (match_window_enabled)
--   ③ 운영자 회원 열람 — 회원 전체 목록 admin_member_list() · 상세 admin_member_detail()
--   ④ 운영자 매칭권 지급/차감 — admin_adjust_tickets() + admin_logs 기록
--   ⑤ 다음 날 인연 자동 배정 — daily_matches 표 + admin_generate_next_day_matches()
--        · 20:30 이후 운영자가 버튼으로 실행하거나, pg_cron 이 매일 20:30(KST)에 호출
--        · 20:30 이전에 눌러도 '내일' 배정을 미리 만들어 둘 뿐입니다
--   ⑥ 운영자 수기 조정 — admin_set_daily_match() (교체 · 추가 · 삭제) + 후보 목록
--   ⑦ 회원별 배정·결과 리스트업 — admin_daily_board() (대기 · 수락 · 거절 + 사유)
--
--  ⚠ 비밀키(service_role)는 어디에도 쓰지 않습니다. 프론트에는 publishable 키만.
--  ⚠ 아래 함수는 모두 SECURITY DEFINER + is_admin() 검사로 보호됩니다.
--     (auth.uid() 가 없는 서버·스케줄러 호출만 예외 — admin_generate_next_day_matches)
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. 신규 가입 기본 매칭권 3장 → 2장
--    (handle_new_user 트리거는 match_tickets 를 적지 않으므로 기본값이 그대로 들어갑니다)
-- ============================================================================
alter table public.profiles add column if not exists height_verified boolean not null default false;
alter table public.profiles alter column match_tickets set default 2;

-- 데모(예시) 프로필은 운영자 화면에서만 보이는 샘플이라 3장이던 값을 2장으로 맞춥니다.
update public.profiles
   set match_tickets = 2
 where coalesce(is_demo, false) = true
   and match_tickets = 3;

-- ============================================================================
-- 2. 운영 설정 — 매칭 시간대 (분 단위 · Asia/Seoul 기준)
--    match_window_enabled : 전체 회원 시간제 ON/OFF (운영자 콘솔의 테스트 토글)
--    match_open_min       : 600  = 10:00
--    match_close_min      : 1200 = 20:00
--    match_auto_min       : 1230 = 20:30 (다음 날 자동 배정 기준 시각)
-- ============================================================================
insert into public.admin_config (id) values (1) on conflict (id) do nothing;

alter table public.admin_config add column if not exists match_window_enabled boolean not null default true;
alter table public.admin_config add column if not exists match_open_min       int     not null default 600;
alter table public.admin_config add column if not exists match_close_min      int     not null default 1200;
alter table public.admin_config add column if not exists match_auto_min       int     not null default 1230;

comment on column public.admin_config.match_window_enabled is
  '오늘의 인연 시간제(10:00~20:00) 전체 ON/OFF — 운영자 테스트용';
comment on column public.admin_config.match_open_min is '오늘의 인연 오픈 시각 (자정부터 분·Asia/Seoul) 기본 600=10:00';
comment on column public.admin_config.match_close_min is '오늘의 인연 마감 시각 (자정부터 분·Asia/Seoul) 기본 1200=20:00';

-- ============================================================================
-- 3. 작은 헬퍼 — 선호 나이(정수), 사진 개수, 사진 배열
--    (priorities jsonb 안의 값이 비어 있거나 글자여도 오류 없이 NULL 로 돌려줍니다)
-- ============================================================================
create or replace function public.pref_int(p jsonb, p_key text) returns int
language sql immutable as $$
  select case
           when coalesce(p->>p_key, '') ~ '^-?[0-9]{1,3}$' then (p->>p_key)::int
           else null
         end;
$$;

create or replace function public.profile_photo_count(p_raw text) returns int
language plpgsql immutable as $$
declare
  v   text  := btrim(coalesce(p_raw, ''));
  v_j jsonb;
begin
  if v = '' then return 0; end if;
  if left(v, 1) <> '[' then return 1; end if;
  begin
    v_j := v::jsonb;
  exception when others then
    return 0;
  end;
  if jsonb_typeof(v_j) <> 'array' then return 0; end if;
  return jsonb_array_length(v_j);
end $$;

create or replace function public.profile_photos(p_raw text) returns jsonb
language plpgsql immutable as $$
declare
  v   text  := btrim(coalesce(p_raw, ''));
  v_j jsonb;
begin
  if v = '' then return '[]'::jsonb; end if;
  if left(v, 1) <> '[' then return jsonb_build_array(v); end if;
  begin
    v_j := v::jsonb;
  exception when others then
    return '[]'::jsonb;
  end;
  return case when jsonb_typeof(v_j) = 'array' then v_j else '[]'::jsonb end;
end $$;

-- ============================================================================
-- 4. 매칭 시간 창 — 지금 열려 있는지 (Asia/Seoul)
--    · 운영자(profiles.is_admin)에게는 항상 open = true
--    · match_window_enabled = false 이면 모든 회원에게 open = true (테스트 모드)
--    · next_open_at : 지금 닫혀 있을 때 다음 오픈 시각(timestamptz)
-- ============================================================================
create or replace function public.match_window_state(p_day date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c         public.admin_config;
  v_local   timestamp := (now() at time zone 'Asia/Seoul');
  v_day     date      := coalesce(p_day, v_local::date);
  v_open    int;
  v_close   int;
  v_start   timestamp;
  v_end     timestamp;
  v_next    timestamp;
  v_admin   boolean   := coalesce(public.is_admin(), false);
  v_enabled boolean;
  v_is_open boolean;
begin
  select * into c from public.admin_config where id = 1;
  v_open    := coalesce(c.match_open_min, 600);
  v_close   := coalesce(c.match_close_min, 1200);
  v_enabled := coalesce(c.match_window_enabled, true);

  v_start := v_day::timestamp + make_interval(mins => greatest(0, least(v_open, 1439)));
  v_end   := v_day::timestamp + make_interval(mins => greatest(0, least(v_close, 1440)));

  v_is_open := case
                 when v_admin or not v_enabled then true
                 else (v_local >= v_start and v_local < v_end)
               end;

  v_next := case
              when v_local < v_start then v_start
              when v_local >= v_end  then v_start + interval '1 day'
              else v_start
            end;

  return jsonb_build_object(
    'ok',          true,
    'server',      true,
    'enabled',     v_enabled,
    'admin',       v_admin,
    'open',        v_is_open,
    'day',         v_day,
    'open_min',    v_open,
    'close_min',   v_close,
    'auto_min',    coalesce(c.match_auto_min, 1230),
    'opens_at',    (v_start at time zone 'Asia/Seoul'),
    'closes_at',   (v_end   at time zone 'Asia/Seoul'),
    'next_open_at',(v_next  at time zone 'Asia/Seoul'),
    'now_kst',     (v_local at time zone 'Asia/Seoul')
  );
end $$;
grant execute on function public.match_window_state(date) to authenticated;

-- ============================================================================
-- 5. daily_matches — 날짜별로 배정된 인연 (하루 최대 2명이 기본, 운영자는 5명까지)
--    · user_id   : 인연을 받는 회원
--    · match_date: 그 인연이 열리는 날 (Asia/Seoul 날짜)
--    · slot      : 1, 2, 3 … (자동 배정은 1·2, 운영자 추가는 다음 번호)
--    · target_id : 소개되는 상대 회원
--    · assigned_by: 'auto'(20:30 자동) · 'admin'(수기 교체·추가)
--    · outcome   : 'pending'(대기) · 'accepted'(수락) · 'declined'(거절)
--    · reason    : 회원이 고른 거절/수락 사유 (예: "직장 · 나이")
-- ============================================================================
create table if not exists public.daily_matches (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  match_date  date not null,
  slot        int  not null default 1,
  target_id   uuid not null references public.profiles(id) on delete cascade,
  assigned_by text not null default 'auto',
  outcome     text not null default 'pending',
  reason      text,
  outcome_at  timestamptz,
  created_at  timestamptz not null default now(),
  primary key (user_id, match_date, slot),
  constraint daily_matches_not_self check (user_id <> target_id)
);

alter table public.daily_matches add column if not exists assigned_by text not null default 'auto';
alter table public.daily_matches add column if not exists outcome     text not null default 'pending';
alter table public.daily_matches add column if not exists reason      text;
alter table public.daily_matches add column if not exists outcome_at  timestamptz;

create unique index if not exists daily_matches_day_target_uidx
  on public.daily_matches (user_id, match_date, target_id);
create index if not exists daily_matches_day_idx    on public.daily_matches (match_date, user_id);
create index if not exists daily_matches_target_idx on public.daily_matches (match_date, target_id);

comment on table public.daily_matches is
  '날짜별 오늘의 인연 배정 — 20:30 자동 배정 또는 운영자 수기 교체. 결과(수락·거절·사유)도 여기에 남습니다.';

alter table public.daily_matches enable row level security;

drop policy if exists daily_matches_select on public.daily_matches;
create policy daily_matches_select on public.daily_matches for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

revoke all on public.daily_matches from anon, authenticated;
grant select (user_id, match_date, slot, target_id, assigned_by, outcome, outcome_at, created_at)
  on public.daily_matches to authenticated;

-- ============================================================================
-- 6. 결과 자동 기록 — 호감을 보내면 그 날의 배정이 '수락'으로 바뀝니다
--    (건너뛰기·거절은 pass_profile 함수에서 사유와 함께 기록합니다)
-- ============================================================================
create or replace function public.sync_daily_match_outcome() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_day date := (coalesce(new.created_at, now()) at time zone 'Asia/Seoul')::date;
begin
  if coalesce(new.status, '') in ('liked', 'matched') then
    update public.daily_matches
       set outcome = 'accepted',
           outcome_at = coalesce(outcome_at, now())
     where user_id = new.from_user
       and target_id = new.to_user
       and outcome = 'pending'
       and match_date between v_day - 1 and v_day + 1;
  end if;
  return new;
end $$;

drop trigger if exists likes_matches_daily_outcome on public.likes_matches;
create trigger likes_matches_daily_outcome
  after insert on public.likes_matches
  for each row execute function public.sync_daily_match_outcome();

-- ============================================================================
-- 7. today_deck() — 오늘의 인연 두 장 (시간제 + 운영자 배정 반영)
--    · 10:00 이전·20:00 이후에는 카드를 내려주지 않고 closed = true 를 돌려줍니다
--      (운영자·시간제 OFF 는 예외, 이미 성사된 매칭·대화는 이 함수와 무관)
--    · 그 날 daily_matches 에 배정된 상대가 있으면 그 두 분을 먼저 내려줍니다
--    · 배정이 모자라면 기존 규칙(성별·선호·중복 차단)대로 채웁니다
-- ============================================================================
create or replace function public.today_deck(p_limit int default 2)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me        uuid := auth.uid();
  v_day       date := (now() at time zone 'Asia/Seoul')::date;
  v_limit     int  := greatest(1, least(coalesce(p_limit, 2), 5));
  v_me_row    public.profiles;
  v_show_demo boolean := true;
  v_window    jsonb;
  v_ids       uuid[] := '{}'::uuid[];
  v_pre       uuid[] := '{}'::uuid[];
  v_served    int;
  v_need      int;
  v_new       uuid;
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;

  select * into v_me_row from public.profiles where id = v_me;
  if v_me_row.id is null then
    return jsonb_build_object('ok', false, 'server', true, 'ready', false,
                              'day', v_day, 'limit', v_limit, 'ids', '[]'::jsonb);
  end if;

  /* 프로필 등록 전(가입 대기 포함)에는 카드를 배정하지 않습니다. */
  if not coalesce(v_me_row.is_admin, false) then
    if v_me_row.status <> 'active'
       or coalesce(btrim(v_me_row.nickname), '') = ''
       or coalesce(v_me_row.gender, '') = ''
       or coalesce(btrim(v_me_row.job), '') = ''
       or coalesce(btrim(v_me_row.region), '') = ''
       or coalesce(btrim(v_me_row.mbti), '') = ''
       or coalesce(v_me_row.height, 0) <= 0
       or coalesce(btrim(v_me_row.bio), '') = ''
       or coalesce(btrim(v_me_row.avatar_data), '') = ''
    then
      return jsonb_build_object('ok', true, 'server', true, 'ready', false,
                                'day', v_day, 'limit', v_limit, 'ids', '[]'::jsonb);
    end if;
  end if;

  /* 매칭 시간제 — 20:00~익일 10:00 은 닫힘 */
  v_window := public.match_window_state(v_day);
  if not coalesce((v_window->>'open')::boolean, true) then
    return jsonb_build_object(
      'ok',      true,
      'server',  true,
      'ready',   true,
      'closed',  true,
      'day',     v_day,
      'limit',   v_limit,
      'window',  v_window,
      'ids',     '[]'::jsonb,
      'count',   0
    );
  end if;

  select coalesce(ac.show_demo, true) into v_show_demo
    from public.admin_config ac where ac.id = 1;
  v_show_demo := coalesce(v_show_demo, true);

  /* 같은 회원이 두 기기에서 동시에 불러도 두 장을 넘지 않게 한 줄씩 세워 둡니다. */
  perform pg_advisory_xact_lock(hashtext('990.today_deck'), hashtext(v_me::text));

  /* ① 운영자가 미리 배정한 상대 (오늘 날짜) */
  select coalesce(array_agg(dm.target_id order by dm.slot), '{}'::uuid[])
    into v_pre
    from public.daily_matches dm
    join public.profiles t on t.id = dm.target_id
   where dm.user_id = v_me
     and dm.match_date = v_day
     and t.status = 'active'
     and not (coalesce(v_me_row.blocked_profiles, '[]'::jsonb) ? dm.target_id::text)
     and not exists (select 1 from public.likes_matches lm
                      where (lm.from_user = v_me and lm.to_user = dm.target_id)
                         or (lm.from_user = dm.target_id and lm.to_user = v_me));

  if coalesce(array_length(v_pre, 1), 0) > 0 then
    insert into public.seen_targets (user_id, target_id, reason, served_on, target_ident, created_at)
    select v_me, x.id, 'served', v_day, public.profile_ident(x.id), now()
      from unnest(v_pre) as x(id)
    on conflict (user_id, target_id) do nothing;
  end if;

  /* ② 오늘 내려준 두 장 — 운영자 배정이 먼저, 나머지는 내려준 순서대로
        (두 기기·새로고침에서도 같은 두 분이 나오도록 DB 기록을 그대로 씁니다) */
  select array_agg(t.target_id order by t.ord, t.created_at)
    into v_ids
    from (
      select s.target_id,
             s.created_at,
             coalesce(array_position(v_pre, s.target_id), 0) as ord
        from public.seen_targets s
       where s.user_id = v_me and s.served_on = v_day
    ) t;

  v_ids := coalesce(v_ids, '{}'::uuid[]);
  if coalesce(array_length(v_ids, 1), 0) > v_limit then
    v_ids := v_ids[1:v_limit];
  end if;

  select count(*) into v_served
    from public.seen_targets
   where user_id = v_me and served_on = v_day;

  v_need := v_limit - coalesce(array_length(v_ids, 1), 0);
  if coalesce(v_served, 0) >= v_limit then
    v_need := 0;
  end if;

  /* ③ 모자라면 기존 규칙대로 한 명씩 (중복·차단·같은 회사 등 모두 제외) */
  while v_need > 0 loop
    v_new := null;
    insert into public.seen_targets (user_id, target_id, reason, served_on, target_ident, created_at)
    select v_me, c.id, 'served', v_day, c.ident, now()
      from (
        select p.id,
               coalesce(
                 nullif(btrim(coalesce(p.phone_hash, '')), ''),
                 case when coalesce(btrim(coalesce(p.email, '')), '') <> ''
                      then md5(lower(btrim(p.email))) end) as ident
          from public.profiles p
         where p.id <> v_me
           and p.status = 'active'
           and coalesce(p.gender, '') <> ''
           and (coalesce(v_me_row.gender, '') = '' or p.gender <> v_me_row.gender)
           and (v_show_demo or coalesce(p.is_demo, false) = false)
           and (not coalesce(v_me_row.hidden_company, true)
                or coalesce(btrim(p.company), '') = ''
                or coalesce(btrim(v_me_row.company), '') = ''
                or btrim(p.company) <> btrim(v_me_row.company))
           and not (coalesce(v_me_row.blocked_profiles, '[]'::jsonb) ? p.id::text)
           and not exists (select 1 from public.likes_matches lm
                            where (lm.from_user = v_me and lm.to_user = p.id)
                               or (lm.from_user = p.id and lm.to_user = v_me))
           and not exists (select 1 from public.reports r
                            where r.reporter_id = v_me and r.target_user_id = p.id)
           and not exists (select 1 from public.seen_targets s
                            where s.user_id = v_me and s.target_id = p.id)
           and not exists (select 1 from public.seen_targets s
                            where s.user_id = v_me
                              and s.target_ident is not null
                              and s.target_ident in (
                                nullif(btrim(coalesce(p.phone_hash, '')), ''),
                                case when coalesce(btrim(coalesce(p.email, '')), '') <> ''
                                     then md5(lower(btrim(p.email))) end))
         order by md5(p.id::text || v_me::text || v_day::text)
         limit 1
      ) c
    on conflict (user_id, target_id) do nothing
    returning target_id into v_new;

    exit when v_new is null;

    v_ids  := v_ids || v_new;
    v_need := v_need - 1;
  end loop;

  return jsonb_build_object(
    'ok',     true,
    'server', true,
    'ready',  true,
    'closed', false,
    'day',    v_day,
    'limit',  v_limit,
    'window', v_window,
    'ids',    to_jsonb(v_ids),
    'count',  coalesce(array_length(v_ids, 1), 0)
  );
end $$;
grant execute on function public.today_deck(int) to authenticated;

-- ============================================================================
-- 8. send_like / pass_profile — 시간제 + 거절 사유 기록
--    (pass_profile 은 사유를 받도록 인자를 하나 늘립니다. 예전 1개 인자 호출도 그대로 동작)
-- ============================================================================
create or replace function public.send_like(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_row public.likes_matches;
  v_tickets int;
  v_status text;
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;
  if p_target = v_me then raise exception '나 자신에게는 보낼 수 없어요.'; end if;

  if not public.is_admin() then
    if not coalesce((public.match_window_state((now() at time zone 'Asia/Seoul')::date)->>'open')::boolean, true) then
      raise exception '지금은 매칭 시간이 아니에요. 매일 10:00~20:00에 인연을 확인할 수 있어요.';
    end if;
  end if;

  select status into v_status from public.profiles where id = p_target;
  if v_status is null then raise exception '상대 프로필을 찾을 수 없어요.'; end if;
  if v_status <> 'active' then raise exception '지금은 호감을 보낼 수 없는 프로필이에요.'; end if;

  select * into v_row from public.likes_matches
   where pair_key = least(v_me::text,p_target::text) || '|' || greatest(v_me::text,p_target::text)
     and status in ('liked','matched')
   limit 1;

  if v_row.id is not null then
    if v_row.status = 'matched' then
      return jsonb_build_object('status','matched','match_id',v_row.id,'already',true);
    elsif v_row.from_user = v_me then
      return jsonb_build_object('status','liked','match_id',v_row.id,'already',true);
    else
      update public.likes_matches
         set status = 'matched', matched_at = now(), expires_at = null
       where id = v_row.id
       returning * into v_row;
      return jsonb_build_object('status','matched','match_id',v_row.id,'already',false);
    end if;
  end if;

  select match_tickets into v_tickets from public.profiles where id = v_me for update;
  if coalesce(v_tickets,0) < 1 then raise exception '매칭권이 없어요. 충전 후 다시 시도해 주세요.'; end if;
  update public.profiles set match_tickets = match_tickets - 1 where id = v_me;

  insert into public.likes_matches (from_user, to_user, status, expires_at)
  values (v_me, p_target, 'liked', now() + interval '48 hours')
  returning * into v_row;

  return jsonb_build_object('status','liked','match_id',v_row.id,'already',false);
end $$;
grant execute on function public.send_like(uuid) to authenticated;

drop function if exists public.pass_profile(uuid);

create or replace function public.pass_profile(p_target uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := auth.uid();
  v_day  date := (now() at time zone 'Asia/Seoul')::date;
  v_note text := left(coalesce(nullif(btrim(coalesce(p_reason, '')), ''), ''), 200);
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;

  if not public.is_admin() then
    if not coalesce((public.match_window_state(v_day)->>'open')::boolean, true) then
      raise exception '지금은 매칭 시간이 아니에요. 매일 10:00~20:00에 인연을 확인할 수 있어요.';
    end if;
  end if;

  insert into public.likes_matches (from_user, to_user, status)
  values (v_me, p_target, 'passed');

  /* 오늘(또는 내일 미리 본) 배정이 있었다면 결과를 거절 + 사유로 남깁니다 */
  update public.daily_matches
     set outcome = 'declined',
         reason = case when v_note = '' then reason else v_note end,
         outcome_at = now()
   where user_id = v_me
     and target_id = p_target
     and outcome = 'pending'
     and match_date between v_day - 1 and v_day + 1;

  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.pass_profile(uuid, text) to authenticated;

create or replace function public.undo_pass(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me  uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Seoul')::date;
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;

  delete from public.likes_matches
   where id = (select id from public.likes_matches
                where from_user = v_me and to_user = p_target and status = 'passed'
                order by created_at desc limit 1)
     and from_user = v_me;

  update public.daily_matches
     set outcome = 'pending', reason = null, outcome_at = null
   where user_id = v_me
     and target_id = p_target
     and outcome = 'declined'
     and match_date between v_day - 1 and v_day + 1;

  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.undo_pass(uuid) to authenticated;

-- ============================================================================
-- 9. 운영자 — 매칭 시간제 ON/OFF (전체 회원 · 테스트용)
-- ============================================================================
create or replace function public.admin_set_match_window(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_enabled boolean := coalesce(p_enabled, true);
begin
  if not public.is_admin() then raise exception '관리자만 바꿀 수 있어요.'; end if;
  update public.admin_config
     set match_window_enabled = v_enabled, updated_at = now()
   where id = 1;

  insert into public.admin_logs (action, target_name, actor, detail)
  values ('매칭 시간제', 'admin_config', 'admin',
          case when v_enabled then 'ON · 10:00~20:00' else 'OFF · 시간 제한 없이 확인' end);

  return jsonb_build_object('ok', true, 'enabled', v_enabled);
end $$;
grant execute on function public.admin_set_match_window(boolean) to authenticated;

-- ============================================================================
-- 10. 운영자 — 매칭권 직접 지급 / 차감
--     p_delta : +1, +2 … (지급) / -1 … (차감). 결과 잔액을 돌려줍니다.
--     p_reason: '1기 후기 보상', '이벤트 지급' 처럼 사유 메모 (admin_logs 에 남습니다)
-- ============================================================================
create or replace function public.admin_adjust_tickets(p_target uuid, p_delta int, p_reason text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name   text;
  v_before int;
  v_after  int;
  v_delta  int := coalesce(p_delta, 0);
  v_reason text := left(coalesce(btrim(coalesce(p_reason, '')), ''), 200);
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  if p_target is null then raise exception '회원을 찾을 수 없어요.'; end if;
  if v_delta = 0 then raise exception '조정할 매칭권 수를 입력해 주세요.'; end if;
  if v_delta > 100 or v_delta < -100 then raise exception '한 번에 100장까지만 조정할 수 있어요.'; end if;

  select coalesce(match_tickets, 0), coalesce(nullif(btrim(coalesce(nickname, '')), ''), email, p_target::text)
    into v_before, v_name
    from public.profiles where id = p_target
   for update;

  if v_name is null then raise exception '회원을 찾을 수 없어요.'; end if;
  if v_before + v_delta < 0 then
    raise exception '보유 매칭권이 %장이라 %장을 차감할 수 없어요.', v_before, abs(v_delta);
  end if;

  update public.profiles
     set match_tickets = coalesce(match_tickets, 0) + v_delta
   where id = p_target
  returning match_tickets into v_after;

  insert into public.admin_logs (action, target_name, actor, detail)
  values (case when v_delta > 0 then '매칭권 지급' else '매칭권 차감' end,
          v_name, 'admin',
          v_before || '장 → ' || v_after || '장' ||
          case when v_reason = '' then '' else ' · ' || v_reason end);

  return jsonb_build_object('ok', true, 'tickets', v_after, 'before', v_before, 'delta', v_delta);
end $$;
grant execute on function public.admin_adjust_tickets(uuid, int, text) to authenticated;

-- ============================================================================
-- 11. 운영자 — 회원 전체 목록 (사진은 상세에서만 · 목록은 사진 장수만)
-- ============================================================================
create or replace function public.admin_member_list(p_query text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
begin
  if not public.is_admin() then raise exception '관리자만 볼 수 있어요.'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',              p.id,
             'nickname',        p.nickname,
             'email',           p.email,
             'gender',          p.gender,
             'birth_year',      p.birth_year,
             'age',             p.age,
             'region',          p.region,
             'areas',           case when jsonb_typeof(p.priorities->'areas') = 'array'
                                     then p.priorities->'areas' else '[]'::jsonb end,
             'height',          p.height,
             'mbti',            p.mbti,
             'job',             p.job,
             'company',         p.company,
             'verified',        coalesce(p.verified, false),
             'height_verified', coalesce(p.height_verified, false),
             'status',          p.status,
             'match_tickets',   coalesce(p.match_tickets, 0),
             'points',          coalesce(p.points, 0),
             'is_demo',         coalesce(p.is_demo, false),
             'is_admin',        coalesce(p.is_admin, false),
             'photo_count',     public.profile_photo_count(p.avatar_data),
             'created_at',      p.created_at
           ) order by
             case coalesce(p.status, '') when 'pending' then 0 when 'active' then 1 else 2 end,
             p.created_at)
      from public.profiles p
     where coalesce(p.is_admin, false) = false
       and (v_q = ''
            or position(v_q in lower(coalesce(p.nickname, ''))) > 0
            or position(v_q in lower(coalesce(p.email, ''))) > 0
            or position(v_q in lower(coalesce(p.region, ''))) > 0
            or position(v_q in lower(coalesce(p.job, ''))) > 0)
  ), '[]'::jsonb);
end $$;
grant execute on function public.admin_member_list(text) to authenticated;

create or replace function public.admin_member_detail(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p     public.profiles;
  v_day date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not public.is_admin() then raise exception '관리자만 볼 수 있어요.'; end if;
  select * into p from public.profiles where id = p_id;
  if p.id is null then raise exception '회원을 찾을 수 없어요.'; end if;

  return jsonb_build_object(
    'id',              p.id,
    'nickname',        p.nickname,
    'email',           p.email,
    'gender',          p.gender,
    'birth_year',      p.birth_year,
    'age',             p.age,
    'region',          p.region,
    'priorities',      coalesce(p.priorities, '{}'::jsonb),
    'height',          p.height,
    'mbti',            p.mbti,
    'job',             p.job,
    'company',         p.company,
    'bio',             p.bio,
    'hobbies',         coalesce(p.hobbies, '[]'::jsonb),
    'values_list',     coalesce(p.values_list, '[]'::jsonb),
    'verified',        coalesce(p.verified, false),
    'height_verified', coalesce(p.height_verified, false),
    'status',          p.status,
    'match_tickets',   coalesce(p.match_tickets, 0),
    'points',          coalesce(p.points, 0),
    'is_demo',         coalesce(p.is_demo, false),
    'hidden_company',  coalesce(p.hidden_company, true),
    'created_at',      p.created_at,
    'photos',          public.profile_photos(p.avatar_data),
    'photo_captions',  coalesce(p.photo_captions, '[]'::jsonb),
    'today',           coalesce((
        select jsonb_agg(jsonb_build_object(
                 'slot', dm.slot,
                 'target_id', dm.target_id,
                 'nickname', t.nickname,
                 'outcome', dm.outcome,
                 'reason', dm.reason)
               order by dm.slot)
          from public.daily_matches dm
          left join public.profiles t on t.id = dm.target_id
         where dm.user_id = p.id and dm.match_date = v_day), '[]'::jsonb),
    'received_pending', coalesce((
        select count(*) from public.likes_matches lm
         where lm.to_user = p.id and lm.status = 'liked'), 0),
    'matches',         coalesce((
        select count(*) from public.likes_matches lm
         where lm.status = 'matched' and (lm.from_user = p.id or lm.to_user = p.id)), 0)
  );
end $$;
grant execute on function public.admin_member_detail(uuid) to authenticated;

-- ============================================================================
-- 12. 운영자 — 다음 날 인연 자동 배정 (20:30 이후 실행 · 스케줄러도 호출 가능)
--     · 대상: 승인(active) + 프로필이 다 채워진 실제 회원
--     · 상대: 반대 성별 · 이미 본 사람 제외(seen_targets) · 호감/매칭/신고/차단 제외
--             · 선호 나이·선호 지역이 맞으면 우선 · 그날 배정이 적은 사람 우선
--     · 이미 배정된 자리는 건드리지 않고 빈자리만 채웁니다 (운영자 수기 조정 보존)
-- ============================================================================
create or replace function public.admin_generate_next_day_matches(p_day date default null, p_limit int default 2)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day       date := coalesce(p_day, (now() at time zone 'Asia/Seoul')::date + 1);
  v_limit     int  := greatest(1, least(coalesce(p_limit, 2), 5));
  v_show_demo boolean;
  v_m         record;
  v_need      int;
  v_rows      int := 0;
  v_members   int := 0;
  v_age_min   int;
  v_age_max   int;
begin
  /* 앱에서 부르면 관리자만, 스케줄러(auth.uid() 없음)는 그대로 실행 */
  if auth.uid() is not null and not public.is_admin() then
    raise exception '관리자만 실행할 수 있어요.';
  end if;

  select coalesce(ac.show_demo, true) into v_show_demo from public.admin_config ac where ac.id = 1;
  v_show_demo := coalesce(v_show_demo, true);

  for v_m in
    select p.* from public.profiles p
     where p.status = 'active'
       and coalesce(p.is_demo, false) = false
       and coalesce(p.is_admin, false) = false
       and coalesce(btrim(p.nickname), '') <> ''
       and coalesce(btrim(p.gender), '') <> ''
       and coalesce(btrim(p.job), '') <> ''
       and coalesce(btrim(p.region), '') <> ''
       and coalesce(btrim(p.mbti), '') <> ''
       and coalesce(p.height, 0) > 0
       and coalesce(btrim(p.bio), '') <> ''
       and coalesce(btrim(p.avatar_data), '') <> ''
     order by p.created_at
  loop
    v_members := v_members + 1;
    v_age_min := public.pref_int(v_m.priorities, 'ageMin');
    v_age_max := public.pref_int(v_m.priorities, 'ageMax');

    select v_limit - count(*) into v_need
      from public.daily_matches dm
     where dm.user_id = v_m.id and dm.match_date = v_day;

    while coalesce(v_need, 0) > 0 loop
      insert into public.daily_matches (user_id, match_date, slot, target_id, assigned_by)
      select v_m.id,
             v_day,
             coalesce((select max(dm.slot) from public.daily_matches dm
                        where dm.user_id = v_m.id and dm.match_date = v_day), 0) + 1,
             c.id,
             'auto'
        from (
          select p2.id,
                 (case when v_age_min is not null and v_age_max is not null
                        and coalesce(p2.age, (extract(year from now())::int - coalesce(p2.birth_year, 0)))
                            between v_age_min and v_age_max
                       then 3 else 0 end)
               + (case when jsonb_typeof(v_m.priorities->'areas') = 'array'
                        and exists (
                          select 1 from jsonb_array_elements_text(v_m.priorities->'areas') a
                           where btrim(a) <> ''
                             and (a like '%전체' or a like '%전역'
                                  or p2.region = btrim(a)
                                  or p2.region like btrim(a) || '%'
                                  or btrim(a) like p2.region || '%')
                        ) then 2 else 0 end)
               + (case when coalesce(v_m.age, 0) > 0 and coalesce(p2.age, 0) > 0
                        and abs(p2.age - v_m.age) <= 3 then 1 else 0 end)
                 as score,
                 (select count(*) from public.daily_matches dm
                   where dm.match_date = v_day and dm.target_id = p2.id) as load
            from public.profiles p2
           where p2.id <> v_m.id
             and p2.status = 'active'
             and coalesce(p2.gender, '') <> ''
             and p2.gender <> v_m.gender
             and (v_show_demo or coalesce(p2.is_demo, false) = false)
             and (not coalesce(v_m.hidden_company, true)
                  or coalesce(btrim(p2.company), '') = ''
                  or coalesce(btrim(v_m.company), '') = ''
                  or btrim(p2.company) <> btrim(v_m.company))
             and not (coalesce(v_m.blocked_profiles, '[]'::jsonb) ? p2.id::text)
             and not exists (select 1 from public.likes_matches lm
                              where (lm.from_user = v_m.id and lm.to_user = p2.id)
                                 or (lm.from_user = p2.id and lm.to_user = v_m.id))
             and not exists (select 1 from public.reports r
                              where r.reporter_id = v_m.id and r.target_user_id = p2.id)
             and not exists (select 1 from public.seen_targets s
                              where s.user_id = v_m.id and s.target_id = p2.id)
             and not exists (select 1 from public.seen_targets s
                              where s.user_id = v_m.id
                                and s.target_ident is not null
                                and s.target_ident in (
                                  nullif(btrim(coalesce(p2.phone_hash, '')), ''),
                                  case when coalesce(btrim(coalesce(p2.email, '')), '') <> ''
                                       then md5(lower(btrim(p2.email))) end))
             and not exists (select 1 from public.daily_matches dm
                              where dm.user_id = v_m.id and dm.match_date = v_day
                                and dm.target_id = p2.id)
           order by load asc, score desc, md5(p2.id::text || v_m.id::text || v_day::text)
           limit 1
        ) c
      on conflict do nothing;

      exit when not found;
      v_rows := v_rows + 1;
      v_need := v_need - 1;
    end loop;
  end loop;

  insert into public.admin_logs (action, target_name, actor, detail)
  values ('다음 날 매칭 자동 배정', v_day::text, 'admin',
          v_members || '명 회원 · ' || v_rows || '건 배정');

  return jsonb_build_object('ok', true, 'day', v_day, 'members', v_members,
                            'assigned', v_rows, 'limit', v_limit);
end $$;
grant execute on function public.admin_generate_next_day_matches(date, int) to authenticated;

-- ============================================================================
-- 13. 운영자 — 수기 조정 (교체 · 추가 · 삭제)
--     p_target 이 NULL 이면 그 자리를 삭제합니다.
--     p_slot 이 NULL 이면 빈자리(다음 번호)에 추가합니다.
-- ============================================================================
create or replace function public.admin_set_daily_match(
  p_user uuid, p_day date, p_target uuid default null, p_slot int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_user_name   text;
  v_target_name text;
  v_slot        int := p_slot;
  v_slots       jsonb;
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  if p_user is null or p_day is null then raise exception '회원과 날짜를 확인해 주세요.'; end if;

  select coalesce(nullif(btrim(coalesce(nickname, '')), ''), email, p_user::text)
    into v_user_name from public.profiles where id = p_user;
  if v_user_name is null then raise exception '회원을 찾을 수 없어요.'; end if;

  /* 삭제 */
  if p_target is null then
    delete from public.daily_matches
     where user_id = p_user and match_date = p_day
       and (p_slot is null or slot = p_slot);

    insert into public.admin_logs (action, target_name, actor, detail)
    values ('매칭 배정 삭제', v_user_name, 'admin',
            p_day::text || case when p_slot is null then ' · 전체' else ' · ' || p_slot || '번' end);
  else
    if p_target = p_user then raise exception '본인을 배정할 수 없어요.'; end if;
    select coalesce(nullif(btrim(coalesce(nickname, '')), ''), email, p_target::text)
      into v_target_name from public.profiles where id = p_target and status = 'active';
    if v_target_name is null then raise exception '배정할 회원을 찾을 수 없어요(승인 완료 회원만).'; end if;

    if v_slot is null then
      v_slot := coalesce((select max(slot) from public.daily_matches
                           where user_id = p_user and match_date = p_day), 0) + 1;
    end if;
    if v_slot < 1 or v_slot > 5 then raise exception '한 사람당 하루 5명까지만 배정할 수 있어요.'; end if;

    begin
      insert into public.daily_matches (user_id, match_date, slot, target_id, assigned_by)
      values (p_user, p_day, v_slot, p_target, 'admin')
      on conflict (user_id, match_date, slot) do update
         set target_id  = excluded.target_id,
             assigned_by = 'admin',
             outcome    = 'pending',
             reason     = null,
             outcome_at = null,
             created_at = now();
    exception when unique_violation then
      raise exception '이미 그 날 배정된 회원이에요. 다른 분을 골라 주세요.';
    end;

    insert into public.admin_logs (action, target_name, actor, detail)
    values ('매칭 수기 배정', v_user_name, 'admin',
            p_day::text || ' · ' || v_slot || '번 · ' || v_target_name);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'slot', slot, 'target_id', target_id,
           'nickname', (select t.nickname from public.profiles t where t.id = target_id),
           'assigned_by', assigned_by, 'outcome', outcome, 'reason', reason)
         order by slot), '[]'::jsonb)
    into v_slots
    from public.daily_matches
   where user_id = p_user and match_date = p_day;

  return jsonb_build_object('ok', true, 'day', p_day, 'slot', v_slot, 'slots', v_slots);
end $$;
grant execute on function public.admin_set_daily_match(uuid, date, uuid, int) to authenticated;

-- ============================================================================
-- 14. 운영자 — 회원별 배정·결과 리스트업 (오늘 / 내일)
-- ============================================================================
create or replace function public.admin_daily_board(p_day date default null, p_include_demo boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day  date := coalesce(p_day, (now() at time zone 'Asia/Seoul')::date);
  v_rows jsonb;
begin
  if not public.is_admin() then raise exception '관리자만 볼 수 있어요.'; end if;

  select coalesce(jsonb_agg(x.row order by x.gender, x.nickname), '[]'::jsonb)
    into v_rows
    from (
      select
        coalesce(p.gender, '') as gender,
        coalesce(p.nickname, '') as nickname,
        jsonb_build_object(
          'id',            p.id,
          'nickname',      p.nickname,
          'gender',        p.gender,
          'age',           p.age,
          'birth_year',    p.birth_year,
          'region',        p.region,
          'match_tickets', coalesce(p.match_tickets, 0),
          'is_demo',       coalesce(p.is_demo, false),
          'status',        p.status,
          'slots',         coalesce((
            select jsonb_agg(jsonb_build_object(
                     'slot',        dm.slot,
                     'target_id',   dm.target_id,
                     'nickname',    t.nickname,
                     'gender',      t.gender,
                     'age',         t.age,
                     'birth_year',  t.birth_year,
                     'region',      t.region,
                     'job',         t.job,
                     'height',      t.height,
                     'is_demo',     coalesce(t.is_demo, false),
                     'status',      t.status,
                     'photo_count', public.profile_photo_count(t.avatar_data),
                     'assigned_by', dm.assigned_by,
                     'outcome',     dm.outcome,
                     'reason',      dm.reason,
                     'outcome_at',  dm.outcome_at,
                     'matched',     exists (select 1 from public.likes_matches lm
                                             where lm.status = 'matched'
                                               and ((lm.from_user = p.id and lm.to_user = dm.target_id)
                                                 or (lm.from_user = dm.target_id and lm.to_user = p.id)))
                   ) order by dm.slot)
              from public.daily_matches dm
              left join public.profiles t on t.id = dm.target_id
             where dm.user_id = p.id and dm.match_date = v_day), '[]'::jsonb)
        ) as row
        from public.profiles p
       where p.status = 'active'
         and coalesce(p.is_admin, false) = false
         and (p_include_demo or coalesce(p.is_demo, false) = false)
    ) x;

  return jsonb_build_object(
    'ok',     true,
    'day',    v_day,
    'window', public.match_window_state(v_day),
    'rows',   v_rows
  );
end $$;
grant execute on function public.admin_daily_board(date, boolean) to authenticated;

-- ============================================================================
-- 15. 운영자 — 수기 배정 후보 (그 날 아직 배정 안 된 · 아직 본 적 없는 회원)
-- ============================================================================
create or replace function public.admin_daily_candidates(
  p_user uuid, p_day date default null, p_query text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day date := coalesce(p_day, (now() at time zone 'Asia/Seoul')::date + 1);
  v_me  public.profiles;
  v_q   text := lower(btrim(coalesce(p_query, '')));
begin
  if not public.is_admin() then raise exception '관리자만 볼 수 있어요.'; end if;
  select * into v_me from public.profiles where id = p_user;
  if v_me.id is null then raise exception '회원을 찾을 수 없어요.'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',          p.id,
             'nickname',    p.nickname,
             'gender',      p.gender,
             'age',         p.age,
             'birth_year',  p.birth_year,
             'region',      p.region,
             'job',         p.job,
             'height',      p.height,
             'is_demo',     coalesce(p.is_demo, false),
             'photo_count', public.profile_photo_count(p.avatar_data),
             'area_hit',    (jsonb_typeof(v_me.priorities->'areas') = 'array' and exists (
                               select 1 from jsonb_array_elements_text(v_me.priorities->'areas') a
                                where btrim(a) <> ''
                                  and (a like '%전체' or a like '%전역'
                                       or p.region = btrim(a)
                                       or p.region like btrim(a) || '%'
                                       or btrim(a) like p.region || '%'))),
             'age_hit',     (public.pref_int(v_me.priorities, 'ageMin') is not null
                             and public.pref_int(v_me.priorities, 'ageMax') is not null
                             and coalesce(p.age, 0) between public.pref_int(v_me.priorities, 'ageMin')
                                                        and public.pref_int(v_me.priorities, 'ageMax'))
           ) order by p.nickname)
      from public.profiles p
     where p.id <> v_me.id
       and p.status = 'active'
       and coalesce(p.is_admin, false) = false
       and (coalesce(v_me.gender, '') = '' or coalesce(p.gender, '') <> v_me.gender)
       and (v_q = ''
            or position(v_q in lower(coalesce(p.nickname, ''))) > 0
            or position(v_q in lower(coalesce(p.region, ''))) > 0
            or position(v_q in lower(coalesce(p.job, ''))) > 0)
       and not exists (select 1 from public.daily_matches dm
                        where dm.user_id = v_me.id and dm.match_date = v_day
                          and dm.target_id = p.id)
       and not exists (select 1 from public.likes_matches lm
                        where (lm.from_user = v_me.id and lm.to_user = p.id)
                           or (lm.from_user = p.id and lm.to_user = v_me.id))
       and not exists (select 1 from public.seen_targets s
                        where s.user_id = v_me.id and s.target_id = p.id)
  ), '[]'::jsonb);
end $$;
grant execute on function public.admin_daily_candidates(uuid, date, text) to authenticated;

-- ============================================================================
-- 16. 스케줄러 (선택) — 매일 20:30(KST) = 11:30(UTC) 에 다음 날 배정
--     Supabase 대시보드 → Database → Extensions 에서 pg_cron 을 켠 뒤 한 번만 실행하세요.
--     (버튼으로 직접 눌러도 되니, 자동화가 필요할 때만 쓰면 됩니다)
-- ----------------------------------------------------------------------------
--  select cron.schedule(
--    '990-next-day-matches',
--    '30 11 * * *',
--    $cron$ select public.admin_generate_next_day_matches(); $cron$
--  );
--  -- 예약 확인: select * from cron.job;
--  -- 예약 취소: select cron.unschedule('990-next-day-matches');
-- ============================================================================

-- ============================================================================
-- 17. 확인용 — 실행하면 아래 표에 결과가 보입니다
-- ============================================================================
select 'profiles'                    as table_name, count(*) as rows from public.profiles
union all select 'profiles 기본 매칭권', count(*) from public.profiles where match_tickets = 2
union all select 'daily_matches',    count(*) from public.daily_matches
union all select 'seen_targets',     count(*) from public.seen_targets
union all select 'likes_matches',    count(*) from public.likes_matches
union all select 'admin_logs',       count(*) from public.admin_logs;
