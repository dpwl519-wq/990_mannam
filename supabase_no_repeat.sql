-- ============================================================================
--  990 인연 · 영구 중복 차단 + 하루 두 장 서버 동기화 (증분 마이그레이션)
-- ----------------------------------------------------------------------------
--  사용법
--   Supabase 대시보드 → 왼쪽 SQL Editor → New query → 이 파일 전체를 붙여넣고 RUN
--   (한 번만 실행하면 됩니다. 여러 번 다시 실행해도 안전합니다 — idempotent)
--
--  이 스크립트가 더하는 것
--   1) seen_targets — 내가 이미 본(배정받은) · 건너뛴 · 호감 보낸 · 매칭된 · 차단한 ·
--      신고한 상대를 기기와 무관하게 '영구히' 기록하는 표.
--   2) today_deck()  — 오늘의 인연 두 장을 DB에서 직접 골라 배정합니다.
--      이미 본 상대는 어떤 기기·브라우저·새로고침에서도 다시 내려가지 않습니다.
--      (하루 두 장 한도도 DB에 남으므로 기기를 바꿔도 2장을 넘지 않습니다)
--   3) likes_matches 자동 기록 트리거 — 건너뛰기·호감·매칭이 생기는 순간
--      seen_targets 에 함께 남습니다. (직전 건너뛰기 취소는 건너뛰기 기록만 지우고,
--      '이 사람을 봤다'는 사실은 남겨서 내일 다시 뜨지 않게 합니다)
--   4) 백필 — 지금까지 쌓인 건너뛰기·호감·매칭·차단·신고 기록을 seen_targets 로 옮깁니다.
--
--  ⚠ 이 파일은 기존 표·함수를 지우지 않습니다. 추가와 함수 교체만 합니다.
--  ⚠ 비밀키(service_role)는 쓰지 않습니다. 앱은 publishable 키로 함수만 호출합니다.
-- ============================================================================

-- ============================================================================
-- 1. seen_targets — '내가 이미 본 상대' 영구 명부
--    · (user_id, target_id) 한 쌍에 한 줄. 한 번 들어가면 지워지지 않습니다.
--    · reason  : served(오늘의 인연으로 배정) · liked · matched · passed(건너뛰기)
--                · ended(대화 종료) · expired_refunded(48시간 무응답) ·
--                blocked(차단) · reported(신고)
--    · served_on : 오늘의 인연으로 배정된 날 (하루 두 장 계산에 씁니다)
--    · target_ident : 같은 사람이 번호·이메일을 그대로 두고 다시 가입해도
--                     다시 뜨지 않도록 남기는 해시(원본은 저장하지 않습니다)
-- ============================================================================
create table if not exists public.seen_targets (
  user_id      uuid not null references public.profiles(id) on delete cascade,
  target_id    uuid not null references public.profiles(id) on delete cascade,
  reason       text not null default 'served',
  served_on    date,
  target_ident text,
  created_at   timestamptz not null default now(),
  primary key (user_id, target_id)
);

alter table public.seen_targets add column if not exists served_on    date;
alter table public.seen_targets add column if not exists target_ident text;
alter table public.seen_targets add column if not exists reason       text not null default 'served';

create index if not exists seen_targets_user_idx   on public.seen_targets (user_id, served_on);
create index if not exists seen_targets_target_idx on public.seen_targets (target_id);
create index if not exists seen_targets_ident_idx  on public.seen_targets (user_id, target_ident)
  where target_ident is not null;

comment on table public.seen_targets is
  '내가 이미 본 상대의 영구 명부 — 오늘의 인연은 이 표에 있는 사람을 다시 내려주지 않습니다.';
comment on column public.seen_targets.target_ident is
  '같은 사람이 다시 가입해도 다시 뜨지 않게 하는 해시(전화번호 해시 또는 이메일 md5). 원본은 저장하지 않습니다.';

-- ============================================================================
-- 2. 같은 사람 식별용 해시 (번호 우선 · 없으면 이메일)
--    앱에는 노출하지 않습니다(실행 권한을 회수). 서버 함수 안에서만 씁니다.
-- ============================================================================
create or replace function public.profile_ident(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    nullif(btrim(coalesce(p.phone_hash, '')), ''),
    case when coalesce(btrim(coalesce(p.email, '')), '') <> ''
         then md5(lower(btrim(p.email))) end)
  from public.profiles p
  where p.id = p_id;
$$;
revoke all on function public.profile_ident(uuid) from public, anon, authenticated;

-- ============================================================================
-- 3. 건너뛰기 · 호감 · 매칭이 생기면 자동으로 seen_targets 에 기록
--    (pass_profile · send_like · respond_like 함수를 고치지 않아도 됩니다)
-- ============================================================================
create or replace function public.record_seen_target() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.from_user is null or new.to_user is null then
    return new;
  end if;
  insert into public.seen_targets (user_id, target_id, reason, target_ident, created_at)
  values (
    new.from_user,
    new.to_user,
    case when coalesce(new.status, '') in ('liked','matched','passed','ended','expired_refunded')
         then new.status else 'seen' end,
    public.profile_ident(new.to_user),
    coalesce(new.created_at, now())
  )
  on conflict (user_id, target_id) do nothing;
  return new;
end $$;

drop trigger if exists likes_matches_seen_trg on public.likes_matches;
create trigger likes_matches_seen_trg
  after insert on public.likes_matches
  for each row execute function public.record_seen_target();

-- ============================================================================
-- 4. note_seen() — 차단 · 신고도 영구 명부에 남기기 (앱이 함께 호출)
--    차단 목록을 나중에 풀어도 이미 본 사람은 다시 소개되지 않습니다.
-- ============================================================================
create or replace function public.note_seen(p_target uuid, p_reason text default 'blocked')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;
  if p_target is null or p_target = v_me then
    return jsonb_build_object('ok', false);
  end if;
  insert into public.seen_targets (user_id, target_id, reason, target_ident)
  values (v_me, p_target, coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'blocked'),
          public.profile_ident(p_target))
  on conflict (user_id, target_id) do nothing;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.note_seen(uuid, text) to authenticated;

-- ============================================================================
-- 5. today_deck() — 오늘의 인연 두 장을 DB에서 골라 배정하고 돌려줍니다
--    · 이미 배정된 두 장은 그대로 돌려줍니다 (기기를 바꿔도 같은 두 분)
--    · 하루 두 장을 넘겨 배정하지 않습니다 (DB에 남는 한도)
--    · 아래 사람은 후보에서 'DB 단계에서' 완전히 빠집니다
--        - 나 자신 · 활성(active) 아닌 회원 · 성별 미입력 회원 · 같은 성별
--        - 나와 이미 어떤 기록(likes_matches)이라도 있는 상대
--          → 건너뛰기 · 호감 · 매칭 · 대화 종료 · 48시간 무응답 전부 포함
--        - 이미 본 상대(seen_targets) · 같은 번호·이메일로 다시 가입한 상대
--        - 내가 차단한 상대(blocked_profiles) · 내가 신고한 상대(reports)
--        - 지인 번호로 차단한 번호 · (같은 회사 숨기기 ON 이면) 같은 회사
--        - 운영자가 데모 회원 노출을 꺼 두었을 때의 데모 회원
--    · 프로필 등록을 마치지 않은 회원에게는 카드를 배정하지 않습니다
--      (오늘의 두 장을 낭비하지 않도록)
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
  v_ids       uuid[] := '{}'::uuid[];
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

  select coalesce(ac.show_demo, true) into v_show_demo
    from public.admin_config ac where ac.id = 1;
  v_show_demo := coalesce(v_show_demo, true);

  /* 같은 회원이 두 기기에서 동시에 불러도 두 장을 넘지 않게 한 줄씩 세워 둡니다. */
  perform pg_advisory_xact_lock(hashtext('990.today_deck'), hashtext(v_me::text));

  select coalesce(array_agg(target_id order by created_at), '{}'::uuid[])
    into v_ids
    from public.seen_targets
   where user_id = v_me and served_on = v_day;

  v_need := v_limit - coalesce(array_length(v_ids, 1), 0);

  /* 후보가 없을 때까지(또는 두 장을 채울 때까지) 한 명씩 배정합니다. */
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
    'day',    v_day,
    'limit',  v_limit,
    'ids',    to_jsonb(v_ids),
    'count',  coalesce(array_length(v_ids, 1), 0)
  );
end $$;
grant execute on function public.today_deck(int) to authenticated;

-- ============================================================================
-- 6. Row Level Security · 권한 — 내 명부는 나만 읽습니다 (쓰기는 함수만)
-- ============================================================================
alter table public.seen_targets enable row level security;

drop policy if exists seen_targets_select on public.seen_targets;
create policy seen_targets_select on public.seen_targets for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

revoke all on public.seen_targets from anon, authenticated;
-- target_ident(번호·이메일 해시)는 앱에 내려보내지 않습니다.
grant select (user_id, target_id, reason, served_on, created_at)
  on public.seen_targets to authenticated;

-- ============================================================================
-- 7. 백필 — 지금까지의 기록을 영구 명부로 옮깁니다 (이미 있으면 건너뜀)
-- ============================================================================
-- 7-1. 건너뛰기 · 호감 · 매칭 · 대화 종료 · 무응답 반환
insert into public.seen_targets (user_id, target_id, reason, target_ident, created_at)
select lm.from_user,
       lm.to_user,
       coalesce(nullif(lm.status, ''), 'seen'),
       public.profile_ident(lm.to_user),
       coalesce(lm.created_at, now())
  from public.likes_matches lm
on conflict (user_id, target_id) do nothing;

-- 7-2. 차단한 상대 (blocked_profiles 는 uuid 문자열 배열)
insert into public.seen_targets (user_id, target_id, reason, target_ident)
select p.id, b.value::uuid, 'blocked', public.profile_ident(b.value::uuid)
  from public.profiles p
  cross join lateral jsonb_array_elements_text(coalesce(p.blocked_profiles, '[]'::jsonb)) as b(value)
 where b.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   and exists (select 1 from public.profiles t where t.id = b.value::uuid)
on conflict (user_id, target_id) do nothing;

-- 7-3. 신고한 상대
insert into public.seen_targets (user_id, target_id, reason, target_ident, created_at)
select r.reporter_id, r.target_user_id, 'reported', public.profile_ident(r.target_user_id),
       coalesce(r.created_at, now())
  from public.reports r
on conflict (user_id, target_id) do nothing;

-- ============================================================================
-- 8. 확인용 (선택) — 실행하면 아래 표에 결과가 보입니다.
-- ============================================================================
select 'seen_targets' as table_name, count(*) as rows from public.seen_targets
union all select 'likes_matches', count(*) from public.likes_matches
union all select 'profiles', count(*) from public.profiles;
