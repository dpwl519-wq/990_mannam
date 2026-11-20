-- ============================================================================
--  990 인연 · Supabase 스키마 (v1.0)
-- ----------------------------------------------------------------------------
--  사용법
--   1) Supabase 대시보드 → 왼쪽 SQL Editor → New query
--   2) 이 파일 전체를 붙여넣고 RUN (한 번만 실행하면 됩니다)
--   3) 여러 번 다시 실행해도 안전합니다 (idempotent)
--
--  이 스크립트가 만드는 것
--   · 테이블 10개 + 운영 설정 1개 : profiles, verifications, likes_matches,
--     messages, reviews, charge_requests, reports, admin_logs, admin_config,
--     photo_unlocks(사진 열람권 기록)
--   · RLS 정책 + 열(column) 단위 권한 : 본인 것만 쓰기, 활성 프로필만 읽기
--   · 서버 함수(RPC) : 매칭권 차감·48시간 자동 반환·매칭 성사·후기 300P·
--     충전 요청·관리자 승인(매칭권 지급)·신고 정지 등 원자 처리
--   · 가입 시 자동 프로필 생성 트리거
--   · 데모 프로필 14명 시드 (사진은 기본 비공개 · 매칭권 1장으로 열람)
--
--  ⚠ 비밀키(service_role)는 어디에도 쓰지 않습니다. 프론트에는 publishable 키만.
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 0. 운영 설정 (관리자 PIN · 입금 계좌 · 카카오페이 ID)
--    이 테이블은 어떤 사용자도 직접 읽을 수 없습니다(정책 없음).
--    아래 SECURITY DEFINER 함수를 통해서만 접근합니다.
-- ============================================================================
create table if not exists public.admin_config (
  id             int primary key default 1,
  admin_email    text default '',              -- (선택) 이 이메일로 로그인하면 관리자
  admin_pin      text default '990418',        -- 관리자 콘솔 PIN (아래에서 바꿔 쓰세요)
  bank_name      text default '카카오뱅크',
  bank_account   text default '3333-00-0000000',
  account_holder text default '예지',
  kakaopay_id    text default '990yeonin',
  show_demo      boolean not null default true,  -- 데모 회원을 모든 회원 화면에 보일지 (운영자 콘솔)
  signup_approval_since timestamptz,             -- 가입 승인 기능을 켠 시각 (이전 가입자는 기존 회원으로 봅니다)
  updated_at     timestamptz not null default now(),
  constraint admin_config_single_row check (id = 1)
);
alter table public.admin_config add column if not exists show_demo boolean not null default true;
alter table public.admin_config add column if not exists signup_approval_since timestamptz;
insert into public.admin_config (id) values (1) on conflict (id) do nothing;
/* 가입 승인 기준 시각 — 한 번만 기록되고 다시 실행해도 바뀌지 않습니다. */
update public.admin_config set signup_approval_since = now()
 where id = 1 and signup_approval_since is null;

-- 관리자 PIN 바꾸기 예시 (원하는 값으로 바꿔 실행):
--   update public.admin_config set admin_pin = '123456' where id = 1;
-- 관리자 이메일 자동 인식(선택):
--   update public.admin_config set admin_email = '내이메일@example.com' where id = 1;

-- ============================================================================
-- 1. profiles — 회원 프로필
-- ============================================================================
create table if not exists public.profiles (
  id              uuid primary key,                       -- auth.users.id (데모 프로필은 고정 uuid)
  email           text,
  nickname        text,
  gender          text,                                   -- 'male' | 'female'
  birth_year      int,
  age             int,
  job             text,
  company         text,
  company_domain  text,
  region          text,
  mbti            text,
  height          int,
  bio             text,
  priorities      jsonb not null default '{"priorities":[],"mbti":[],"ageMin":30,"ageMax":40,"areas":["서울시 전역"],"values":[]}'::jsonb,
  match_tickets   int  not null default 2,
  points          int  not null default 0,
  verified        boolean not null default false,         -- 직장인 인증(회사 메일·서류) 승인 여부
  height_verified boolean not null default false,          -- 키 인증(건강검진·신체검사서) 승인 여부 — 직장인 인증과 별개
  status          text not null default 'pending',        -- 'pending'(가입 대기) | 'active' | 'rejected' | 'suspended'
  avatar_data     text,                                   -- 사진(data URL) 배열 JSON 문자열
  phone_hash      text,
  hidden_company  boolean not null default true,           -- 같은 회사 숨기기
  -- 앱 화면에서 쓰는 보조 열
  hobbies         jsonb not null default '[]'::jsonb,
  values_list     jsonb not null default '[]'::jsonb,
  photo_captions  jsonb not null default '[]'::jsonb,
  dist_km         numeric,
  job_stable      boolean not null default false,
  nonsmoker       boolean,
  religion        text,                                  -- 종교 (무교·기독교·천주교·불교·기타, 선택 입력)
  tattoo          text,                                  -- 문신 (없음·작은 타투 있음·있음)
  drinking        text,                                  -- 주량 (비음주·가끔·적당히·줄기는 편)
  smoking         text,                                  -- 흡연 (비흡연·전자담배·흡연) — nonsmoker 열과 함께 갱신
  blocked_phones  jsonb not null default '[]'::jsonb,     -- [{hash, masked, at}] 번호 원본은 저장하지 않음
  blocked_profiles jsonb not null default '[]'::jsonb,
  is_demo         boolean not null default false,
  is_admin        boolean not null default false,
  demo_seeded     boolean not null default false,
  created_at      timestamptz not null default now()
);

-- 이미 만들어 둔 경우에도 빠진 열을 채워 넣습니다(재실행 안전).
do $$
declare c record;
begin
  for c in select * from (values
      ('email','text'), ('nickname','text'), ('gender','text'), ('birth_year','int'), ('age','int'),
      ('job','text'), ('company','text'), ('company_domain','text'), ('region','text'), ('mbti','text'),
      ('height','int'), ('bio','text'), ('avatar_data','text'), ('phone_hash','text'),
      ('hobbies','jsonb not null default ''[]''::jsonb'),
      ('values_list','jsonb not null default ''[]''::jsonb'),
      ('photo_captions','jsonb not null default ''[]''::jsonb'),
      ('dist_km','numeric'), ('job_stable','boolean not null default false'), ('nonsmoker','boolean'),
      ('religion','text'), ('tattoo','text'), ('drinking','text'), ('smoking','text'),
      ('blocked_phones','jsonb not null default ''[]''::jsonb'),
      ('blocked_profiles','jsonb not null default ''[]''::jsonb'),
      ('is_demo','boolean not null default false'), ('is_admin','boolean not null default false'),
      ('demo_seeded','boolean not null default false')
    ) as t(n, tp) loop
    execute format('alter table public.profiles add column if not exists %I %s', c.n, c.tp);
  end loop;
end $$;

-- 키 인증 상태 열 — 직장인 인증(verified)과 완전히 분리해서 관리합니다(재실행 안전).
alter table public.profiles add column if not exists height_verified boolean not null default false;

-- 신규 가입 기본 매칭권은 2장입니다(베타 1기 무료 매칭권 2장). 예전에 만든 DB 도 2장으로 맞춥니다.
alter table public.profiles alter column match_tickets set default 2;

comment on column public.profiles.status is
  '''pending'' 가입 승인 대기 / ''active'' 입장 가능 / ''rejected'' 가입 반려 / ''suspended'' 이용 정지';

create index if not exists profiles_status_idx on public.profiles (status, gender);

-- ============================================================================
-- 2. verifications — 직장인 인증 제출
-- ============================================================================
create table if not exists public.verifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  method        text not null default 'doc',              -- 'email' | 'doc' (직장인 인증) / 'height' (키 인증)
  company       text default '',
  company_email text,
  doc_name      text,
  doc_preview   text,                                     -- 서류 이미지 data URL(축소본)
  claimed_height int,                                     -- 키 인증(method='height')일 때 회원이 적은 키(cm)
  status        text not null default 'pending',           -- 'pending' | 'approved' | 'rejected'
  reviewed_by   text,
  reviewed_at   timestamptz,
  note          text default '',                          -- 승인/반려 메모(반려 사유)
  created_at    timestamptz not null default now()
);
create index if not exists verifications_status_idx on public.verifications (status, created_at desc);
create index if not exists verifications_user_idx on public.verifications (user_id, created_at desc);
alter table public.verifications add column if not exists claimed_height int;

-- ============================================================================
-- 3. likes_matches — 호감 · 건너뛰기 · 매칭 (한 쌍당 한 줄)
--    from_user = 먼저 호감을 보낸 사람, to_user = 받은 사람
--    status: liked(답변 대기) / matched(매칭) / passed(거절·건너뛰기) /
--            expired_refunded(48시간 무응답 → 매칭권 반환)
-- ============================================================================
create table if not exists public.likes_matches (
  id                    uuid primary key default gen_random_uuid(),
  from_user             uuid not null references public.profiles(id) on delete cascade,
  to_user               uuid not null references public.profiles(id) on delete cascade,
  status                text not null default 'liked'
                        check (status in ('liked','matched','passed','expired_refunded','ended')),
  matched_at            timestamptz,
  expires_at            timestamptz,
  met_confirmed_by_from boolean not null default false,
  met_confirmed_by_to   boolean not null default false,
  planned_at            timestamptz,
  pair_key              text,
  created_at            timestamptz not null default now(),
  constraint likes_matches_not_self check (from_user <> to_user)
);
-- 한 쌍은 '대기/매칭' 상태의 줄을 하나만 가질 수 있습니다(동시 클릭 중복 방지).
create unique index if not exists likes_matches_pair_active_uidx
  on public.likes_matches (pair_key) where status in ('liked','matched');
create index if not exists likes_matches_from_idx on public.likes_matches (from_user, status);
create index if not exists likes_matches_to_idx   on public.likes_matches (to_user, status);

create or replace function public.likes_matches_pair_key() returns trigger
language plpgsql as $$
begin
  new.pair_key := least(new.from_user::text, new.to_user::text) || '|' ||
                  greatest(new.from_user::text, new.to_user::text);
  return new;
end $$;
drop trigger if exists likes_matches_pair_key_trg on public.likes_matches;
create trigger likes_matches_pair_key_trg
  before insert or update of from_user, to_user on public.likes_matches
  for each row execute function public.likes_matches_pair_key();

-- ============================================================================
-- 4. messages — 매칭된 대화
-- ============================================================================
create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  match_id   uuid not null references public.likes_matches(id) on delete cascade,
  sender_id  uuid not null references public.profiles(id) on delete cascade,
  body       text not null,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists messages_match_idx on public.messages (match_id, created_at);

-- ============================================================================
-- 5. reviews — 만남 후기 (+300P)
-- ============================================================================
create table if not exists public.reviews (
  id             uuid primary key default gen_random_uuid(),
  match_id       uuid not null references public.likes_matches(id) on delete cascade,
  author_id      uuid not null references public.profiles(id) on delete cascade,
  rating         int,
  content        text,
  points_awarded int not null default 300,
  created_at     timestamptz not null default now(),
  unique (match_id, author_id)                            -- 한 만남에 후기 1회
);

-- ============================================================================
-- 6. charge_requests — 계좌이체/카카오페이 입금 확인형 충전 요청
-- ============================================================================
create table if not exists public.charge_requests (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles(id) on delete cascade,
  package_name   text not null,
  tickets        int not null,
  amount_krw     int not null,
  depositor_name text not null,
  status         text not null default 'pending',          -- 'pending' | 'approved' | 'rejected'
  note           text default '',
  reviewed_at    timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists charge_requests_status_idx on public.charge_requests (status, created_at desc);

-- ============================================================================
-- 7. reports — 신고
-- ============================================================================
create table if not exists public.reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid not null references public.profiles(id) on delete cascade,
  target_user_id uuid not null references public.profiles(id) on delete cascade,
  reason         text not null,
  detail         text default '',
  status         text not null default 'open',             -- 'open' | 'suspended' | 'dismissed'
  reviewed_at    timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists reports_status_idx on public.reports (status, created_at desc);

-- ============================================================================
-- 8. admin_logs — 운영 처리 이력
-- ============================================================================
create table if not exists public.admin_logs (
  id          uuid primary key default gen_random_uuid(),
  action      text not null,
  target_name text default '',
  actor       text default 'admin',
  detail      text default '',
  created_at  timestamptz not null default now()
);

-- ============================================================================
-- 9. 공통 헬퍼
-- ============================================================================
-- 관리자 여부 (SECURITY DEFINER → RLS 재귀 없이 profiles 조회)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

-- 회사명 · 인증된 키 · 인증 플래그는 인증 절차로만 바뀝니다.
-- 앱을 고쳐 직접 요청해도 서버에서 막습니다(관리자 승인 함수는 대상 회원이 아니므로 영향 없음).
create or replace function public.guard_verified_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and old.id = auth.uid() then
    new.company := old.company;
    new.verified := old.verified;
    new.height_verified := old.height_verified;
    if coalesce(old.height_verified, false) then
      new.height := old.height;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard_verified on public.profiles;
create trigger profiles_guard_verified before update on public.profiles
  for each row execute function public.guard_verified_profile_fields();

-- 지역 이름 통일 — "서울 성동구" · "성수동" → "서울시 성동구"
-- (이미 "서울시 성동구" 처럼 정리된 값은 그대로 둡니다: 재실행 안전)
create or replace function public.normalize_region(p_value text) returns text
language plpgsql immutable as $$
declare
  v text := regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g');
  pr record;
begin
  if v = '' then return ''; end if;
  /* 동네 이름 → 시·군·구 */
  v := case v
    when '성수' then '서울시 성동구'
    when '성수동' then '서울시 성동구'
    when '성동' then '서울시 성동구'
    when '망원' then '서울시 마포구'
    when '망원동' then '서울시 마포구'
    when '연남' then '서울시 마포구'
    when '연남동' then '서울시 마포구'
    when '마포' then '서울시 마포구'
    when '판교' then '경기도 성남시'
    when '분당' then '경기도 성남시'
    when '일산' then '경기도 고양시'
    else v end;
  /* 시·도 짧은 이름 → 정식 표기 */
  for pr in select * from (values
      ('서울','서울시'), ('부산','부산시'), ('대구','대구시'), ('인천','인천시'),
      ('광주','광주시'), ('대전','대전시'), ('울산','울산시'), ('세종','세종시'),
      ('경기','경기도'), ('강원','강원도'), ('충북','충청북도'), ('충남','충청남도'),
      ('전북','전라북도'), ('전남','전라남도'), ('경북','경상북도'), ('경남','경상남도'),
      ('제주','제주도')) as t(old, full) loop
    if v = pr.old then return pr.full; end if;
    if v = pr.full then return v; end if;
    if position(pr.old || ' ' in v) = 1 then return pr.full || substr(v, length(pr.old) + 1); end if;
  end loop;
  return v;
end $$;

-- 회사 메일 도메인에서 회사 이름 추정 (승인 시 회사명 입력이 비어 있을 때만 쓰는 마지막 수단)
create or replace function public.company_from_email(p_email text) returns text
language sql immutable as $$
  select case
    when p_email is null or position('@' in p_email) = 0 then null
    else nullif(regexp_replace(
      regexp_replace(lower(split_part(p_email, '@', 2)), '\.(co|or|ac|go|ne|es|com|net|org|kr)$', '', 'g'),
      '\.', ' ', 'g'), '')
  end;
$$;

-- 내 지갑·안전 설정 (남에게 보이면 안 되는 값만 모아서 반환)
create or replace function public.my_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id,
    'match_tickets', p.match_tickets,
    'points', p.points,
    'verified', p.verified,
    'height_verified', p.height_verified,
    'show_demo', coalesce((select ac.show_demo from public.admin_config ac where ac.id = 1), true),
    'status', p.status,
    'hidden_company', p.hidden_company,
    'blocked_phones', p.blocked_phones,
    'blocked_profiles', p.blocked_profiles,
    'is_admin', p.is_admin,
    'demo_seeded', p.demo_seeded,
    'email', p.email
  ) from public.profiles p where p.id = auth.uid();
$$;

-- 48시간 무응답 → 매칭권 자동 반환 (여러 번 불러도 한 번만 처리됨)
create or replace function public.expire_likes() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id, from_user from public.likes_matches
            where status = 'liked' and expires_at is not null and expires_at < now()
  loop
    update public.likes_matches set status = 'expired_refunded' where id = r.id and status = 'liked';
    if found then
      update public.profiles set match_tickets = match_tickets + 1 where id = r.from_user;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- 호감 보내기 (매칭권 1장 차감, 상대가 먼저 보냈다면 즉시 매칭)
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

-- 건너뛰기 / 되돌리기
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

-- 받은 호감 수락 / 거절
create or replace function public.respond_like(p_match uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.likes_matches;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  select * into v_row from public.likes_matches where id = p_match for update;
  if v_row.id is null then raise exception '호감을 찾을 수 없어요.'; end if;
  if v_row.to_user <> auth.uid() then raise exception '내가 받은 호감만 응답할 수 있어요.'; end if;
  if v_row.status <> 'liked' then return jsonb_build_object('status', v_row.status); end if;

  if p_accept then
    update public.likes_matches
       set status = 'matched', matched_at = now(), expires_at = null
     where id = p_match;
    return jsonb_build_object('status','matched','match_id',p_match);
  else
    update public.likes_matches set status = 'passed' where id = p_match;
    return jsonb_build_object('status','passed');
  end if;
end $$;

-- 대화 종료 (양쪽 공통) — 누가 호출해도 같은 방이 닫힙니다
create or replace function public.end_chat(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.likes_matches;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  select * into v_row from public.likes_matches where id = p_match for update;
  if v_row.id is null then raise exception '대화방을 찾을 수 없어요.'; end if;
  if auth.uid() not in (v_row.from_user, v_row.to_user) then raise exception '이 대화를 종료할 수 없어요.'; end if;
  if v_row.status = 'ended' then return jsonb_build_object('status','ended','already',true); end if;
  if v_row.status <> 'matched' then raise exception '매칭된 대화만 종료할 수 있어요.'; end if;
  update public.likes_matches set status = 'ended' where id = p_match;
  return jsonb_build_object('status','ended','already',false);
end $$;

-- 메시지 보내기 / 읽음 처리
create or replace function public.send_message(p_match uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.likes_matches; v_msg public.messages; v_body text := btrim(coalesce(p_body,''));
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  if v_body = '' then raise exception '메시지를 입력해 주세요.'; end if;
  if length(v_body) > 500 then v_body := left(v_body, 500); end if;

  select * into v_row from public.likes_matches where id = p_match;
  if v_row.id is null then raise exception '대화방을 찾을 수 없어요.'; end if;
  if auth.uid() not in (v_row.from_user, v_row.to_user) then raise exception '이 대화에 참여할 수 없어요.'; end if;
  if v_row.status <> 'matched' then raise exception '매칭된 대화에서만 메시지를 보낼 수 있어요.'; end if;

  insert into public.messages (match_id, sender_id, body)
  values (p_match, auth.uid(), v_body)
  returning * into v_msg;

  return jsonb_build_object('id', v_msg.id, 'created_at', v_msg.created_at);
end $$;

create or replace function public.mark_read(p_match uuid) returns int
language plpgsql security definer set search_path = public as $$
declare v_row public.likes_matches; n int;
begin
  if auth.uid() is null then return 0; end if;
  select * into v_row from public.likes_matches where id = p_match;
  if v_row.id is null or auth.uid() not in (v_row.from_user, v_row.to_user) then return 0; end if;
  update public.messages set read_at = now()
   where match_id = p_match and sender_id <> auth.uid() and read_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- 만남 약속 / 만남 기록
create or replace function public.plan_meeting(p_match uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.likes_matches;
begin
  select * into v_row from public.likes_matches where id = p_match;
  if v_row.id is null or auth.uid() not in (v_row.from_user, v_row.to_user) then
    raise exception '대화방을 찾을 수 없어요.';
  end if;
  update public.likes_matches set planned_at = p_at where id = p_match;
  return jsonb_build_object('ok', true, 'planned_at', p_at);
end $$;

create or replace function public.confirm_met(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.likes_matches;
begin
  select * into v_row from public.likes_matches where id = p_match;
  if v_row.id is null or auth.uid() not in (v_row.from_user, v_row.to_user) then
    raise exception '대화방을 찾을 수 없어요.';
  end if;
  if auth.uid() = v_row.from_user then
    update public.likes_matches set met_confirmed_by_from = true where id = p_match;
  else
    update public.likes_matches set met_confirmed_by_to = true where id = p_match;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 만남 후기 + 300P 적립 (한 만남에 1회)
create or replace function public.submit_review(p_match uuid, p_rating int, p_content text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row public.likes_matches;
  v_met boolean;
  v_points int;
  v_award int := 300;
begin
  select * into v_row from public.likes_matches where id = p_match;
  if v_row.id is null or auth.uid() not in (v_row.from_user, v_row.to_user) then
    raise exception '대화방을 찾을 수 없어요.';
  end if;
  if v_row.status <> 'matched' then raise exception '매칭된 인연에만 후기를 남길 수 있어요.'; end if;

  v_met := (auth.uid() = v_row.from_user and v_row.met_confirmed_by_from)
        or (auth.uid() = v_row.to_user   and v_row.met_confirmed_by_to);
  if not v_met then raise exception '먼저 만남을 기록해 주세요.'; end if;

  if exists (select 1 from public.reviews where match_id = p_match and author_id = auth.uid()) then
    raise exception '이미 후기를 남겼어요.';
  end if;

  insert into public.reviews (match_id, author_id, rating, content, points_awarded)
  values (p_match, auth.uid(), coalesce(p_rating, 0), coalesce(p_content,''), v_award);

  update public.profiles set points = points + v_award where id = auth.uid()
  returning points into v_points;

  return jsonb_build_object('ok', true, 'points', v_points, 'awarded', v_award);
end $$;

-- 매칭권 충전 요청 (가격은 서버에서 검증)
create or replace function public.request_charge(p_tickets int, p_amount int, p_depositor text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text; v_row public.charge_requests;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  if p_depositor is null or btrim(p_depositor) = '' then raise exception '입금자명을 적어주세요.'; end if;

  v_name := case
    when p_tickets = 1 and p_amount = 990  then '첫 체험 1장'
    when p_tickets = 3 and p_amount = 2500 then '3장 묶음'
    when p_tickets = 5 and p_amount = 4900 then '5장 묶음'
    else null end;
  if v_name is null then raise exception '충전 상품 정보가 올바르지 않아요.'; end if;

  insert into public.charge_requests (user_id, package_name, tickets, amount_krw, depositor_name, status)
  values (auth.uid(), v_name, p_tickets, p_amount, btrim(p_depositor), 'pending')
  returning * into v_row;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'package', v_name);
end $$;

-- 포인트로 매칭권 전환 (990P = 1장)
create or replace function public.redeem_points() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_points int; v_tickets int; v_cost int := 990;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  select points, match_tickets into v_points, v_tickets from public.profiles where id = auth.uid() for update;
  if coalesce(v_points,0) < v_cost then raise exception '포인트가 부족해요. (990P 필요)'; end if;
  update public.profiles
     set points = points - v_cost, match_tickets = match_tickets + 1
   where id = auth.uid()
  returning points, match_tickets into v_points, v_tickets;
  return jsonb_build_object('points', v_points, 'tickets', v_tickets);
end $$;

-- 안전 설정 저장 (같은 회사 숨기기 · 차단 번호 · 차단 프로필)
create or replace function public.update_safety(
  p_hidden_company boolean default null,
  p_blocked_phones jsonb default null,
  p_blocked_profiles jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  update public.profiles
     set hidden_company  = coalesce(p_hidden_company, hidden_company),
         blocked_phones  = coalesce(p_blocked_phones, blocked_phones),
         blocked_profiles = coalesce(p_blocked_profiles, blocked_profiles)
   where id = auth.uid();
  return public.my_state();
end $$;

-- 입금 계좌 안내 (사용자에게 보여줄 값만)
create or replace function public.get_payment_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'bank_name', bank_name, 'bank_account', bank_account,
    'account_holder', account_holder, 'kakaopay_id', kakaopay_id)
  from public.admin_config where id = 1;
$$;

-- ============================================================================
-- 10. 관리자 함수 (PIN 또는 관리자 이메일로만)
-- ============================================================================
create or replace function public.admin_claim(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.admin_config; v_email text; v_ok boolean := false;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  select * into c from public.admin_config where id = 1;
  select coalesce(p.email,'') into v_email from public.profiles p where p.id = auth.uid();
  if (coalesce(c.admin_pin,'') <> '' and p_pin = c.admin_pin)
     or (coalesce(c.admin_email,'') <> '' and lower(v_email) = lower(c.admin_email)) then
    /* 운영자로 확인되면 가입 대기 상태여도 바로 입장할 수 있게 합니다. */
    update public.profiles
       set is_admin = true,
           status = case when status = 'pending' then 'active' else status end
     where id = auth.uid();
    insert into public.admin_logs (action, target_name, actor, detail)
    values ('관리자 콘솔 로그인', coalesce(v_email,''), 'admin', '');
    v_ok := true;
  end if;
  return jsonb_build_object('ok', v_ok);
end $$;

drop function if exists public.admin_review_verification(uuid, boolean, text);
drop function if exists public.admin_review_verification(uuid, boolean, text, text);

create or replace function public.admin_review_verification(
  p_id uuid, p_approve boolean, p_note text default '', p_company text default null, p_height int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.verifications; v_name text; v_is_height boolean; v_company text; v_height int;
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  select * into v_row from public.verifications where id = p_id for update;
  if v_row.id is null then raise exception '제출 건을 찾을 수 없어요.'; end if;

  v_is_height := coalesce(v_row.method, '') = 'height';

  update public.verifications
     set status = case when p_approve then 'approved' else 'rejected' end,
         reviewed_by = 'admin', reviewed_at = now(), note = coalesce(p_note,'')
   where id = p_id;

  -- 승인 결과는 인증 종류별로 따로 기록합니다.
  --   키 인증(method = 'height')  → height_verified 만 true (verified 는 그대로)
  --   직장인 인증(email · doc)     → verified 를 켜고, 확인된 회사명을 프로필에 기록
  if p_approve then
    if v_is_height then
      -- 키: 관리자가 확인한 값 → 회원이 적은 값 순서로 쓰고, 그 값으로 프로필 키를 고정합니다.
      v_height := coalesce(nullif(p_height, 0), nullif(v_row.claimed_height, 0));
      update public.profiles
         set height_verified = true,
             height = coalesce(v_height, height)
       where id = v_row.user_id;
      if v_height is not null then
        update public.verifications set claimed_height = v_height where id = p_id;
      end if;
    else
      -- 회사명은 회원이 프로필에서 직접 고칠 수 없습니다(열 단위 권한으로 차단).
      -- 승인 화면에서 관리자가 확인한 값 → 제출할 때 적은 회사명 → 메일 도메인 추정 → 기존 값
      v_company := coalesce(
        nullif(btrim(coalesce(p_company, '')), ''),
        nullif(btrim(coalesce(v_row.company, '')), ''),
        public.company_from_email(v_row.company_email)
      );
      update public.profiles
         set verified = true,
             company  = coalesce(v_company, company)
       where id = v_row.user_id;
      if v_company is not null then
        update public.verifications set company = v_company where id = p_id;
      end if;
    end if;
  end if;

  select nickname into v_name from public.profiles where id = v_row.user_id;
  insert into public.admin_logs (action, target_name, actor, detail)
  values (case when p_approve then '인증 승인' else '인증 반려' end,
          coalesce(v_name, v_row.user_id::text), 'admin',
          coalesce(p_note, case when v_is_height then '키 인증' else coalesce(v_company, v_row.company) end, ''));

  return jsonb_build_object('ok', true);
end $$;

-- (재실행 안전) 이미 승인된 키 인증 제출 건이 있으면 height_verified 를 맞춰 둡니다.
update public.profiles p set height_verified = true
 where p.height_verified = false
   and exists (select 1 from public.verifications v
                where v.user_id = p.id and v.method = 'height' and v.status = 'approved');

-- (선택 · 필요할 때만 실행) 예전 함수는 키 인증을 승인해도 직장인 인증(verified)을 켰습니다.
--   키 인증만 받은 회원의 직장인 인증 배지를 정리하려면 아래 주석을 풀고 한 번 실행하세요.
-- update public.profiles p set verified = false
--  where p.verified = true
--    and exists (select 1 from public.verifications v
--                 where v.user_id = p.id and v.method = 'height' and v.status = 'approved')
--    and not exists (select 1 from public.verifications v
--                     where v.user_id = p.id and v.method <> 'height' and v.status = 'approved');

create or replace function public.admin_review_charge(p_id uuid, p_approve boolean, p_note text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.charge_requests; v_name text; v_tickets int;
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  select * into v_row from public.charge_requests where id = p_id for update;
  if v_row.id is null then raise exception '충전 요청을 찾을 수 없어요.'; end if;
  if v_row.status <> 'pending' then raise exception '이미 처리된 요청이에요.'; end if;

  update public.charge_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         reviewed_at = now(), note = coalesce(p_note,'')
   where id = p_id;

  if p_approve then
    update public.profiles
       set match_tickets = match_tickets + v_row.tickets
     where id = v_row.user_id
    returning match_tickets into v_tickets;
  end if;

  select nickname into v_name from public.profiles where id = v_row.user_id;
  insert into public.admin_logs (action, target_name, actor, detail)
  values (case when p_approve then '충전 승인' else '충전 반려' end,
          coalesce(v_name, v_row.user_id::text), 'admin',
          v_row.package_name || ' · ' || v_row.amount_krw || '원 · 입금자 ' || v_row.depositor_name);

  return jsonb_build_object('ok', true, 'tickets', v_tickets);
end $$;

create or replace function public.admin_review_report(p_id uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.reports; v_name text;
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  select * into v_row from public.reports where id = p_id for update;
  if v_row.id is null then raise exception '신고를 찾을 수 없어요.'; end if;

  if p_action = 'suspend' then
    update public.reports set status = 'suspended', reviewed_at = now() where id = p_id;
    update public.profiles set status = 'suspended' where id = v_row.target_user_id;
  else
    update public.reports set status = 'dismissed', reviewed_at = now() where id = p_id;
  end if;

  select nickname into v_name from public.profiles where id = v_row.target_user_id;
  insert into public.admin_logs (action, target_name, actor, detail)
  values (case when p_action = 'suspend' then '신고 이용 정지' else '신고 기각' end,
          coalesce(v_name, v_row.target_user_id::text), 'admin', v_row.reason);

  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_restore_user(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  update public.profiles set status = 'active' where id = p_target;
  select nickname into v_name from public.profiles where id = p_target;
  insert into public.admin_logs (action, target_name, actor, detail)
  values ('이용 정지 해제', coalesce(v_name, p_target::text), 'admin', '');
  return jsonb_build_object('ok', true);
end $$;

-- 가입 대기 · 반려 목록 (이메일은 열 권한으로 막혀 있어 함수로만 전달합니다)
create or replace function public.admin_signup_list() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '관리자만 볼 수 있어요.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',         p.id,
             'nickname',   p.nickname,
             'gender',     p.gender,
             'birth_year', p.birth_year,
             'age',        p.age,
             'email',      p.email,
             'job',        p.job,
             'region',     p.region,
             'status',     p.status,
             'created_at', p.created_at
           ) order by p.created_at asc)
      from public.profiles p
     where p.status in ('pending', 'rejected')
       and coalesce(p.is_demo, false) = false
  ), '[]'::jsonb);
end $$;

-- 가입 승인(active) / 가입 반려(rejected) — 사유는 admin_logs 에 기록됩니다.
drop function if exists public.admin_review_signup(uuid, boolean);
create or replace function public.admin_review_signup (
  p_id uuid, p_approve boolean, p_note text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.profiles; v_name text; v_status text;
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  if p_id is null then raise exception '회원을 찾을 수 없어요.'; end if;

  select * into v_row from public.profiles where id = p_id for update;
  if v_row.id is null then raise exception '회원을 찾을 수 없어요.'; end if;
  if v_row.status not in ('pending', 'rejected') then
    raise exception '가입 대기·반려 상태의 회원만 처리할 수 있어요.';
  end if;

  v_status := case when coalesce(p_approve, false) then 'active' else 'rejected' end;

  update public.profiles set status = v_status where id = p_id;
  v_name := coalesce(v_row.nickname, v_row.email, p_id::text);

  insert into public.admin_logs (action, target_name, actor, detail)
  values (case when v_status = 'active' then '가입 승인' else '가입 반려' end,
          v_name, 'admin',
          coalesce(nullif(btrim(coalesce(p_note, '')), ''),
                   case when v_status = 'active' then '가입 승인 · 입장 가능' else '가입 반려' end));

  return jsonb_build_object('ok', true, 'status', v_status);
end $$;

create or replace function public.admin_save_payment(
  p_bank_name text, p_bank_account text, p_account_holder text, p_kakaopay_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '관리자만 바꿀 수 있어요.'; end if;
  update public.admin_config
     set bank_name = coalesce(p_bank_name, bank_name),
         bank_account = coalesce(p_bank_account, bank_account),
         account_holder = coalesce(p_account_holder, account_holder),
         kakaopay_id = coalesce(p_kakaopay_id, kakaopay_id),
         updated_at = now()
   where id = 1;
  insert into public.admin_logs (action, target_name, actor, detail)
  values ('입금 계좌 변경', 'admin_config', 'admin', coalesce(p_bank_name,'') || ' ' || coalesce(p_bank_account,''));
  return jsonb_build_object('ok', true);
end $$;

-- 데모 회원 노출 ON/OFF — 모든 회원 화면에 바로 적용됩니다.
create or replace function public.admin_set_demo(p_show boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_show boolean := coalesce(p_show, true);
begin
  if not public.is_admin() then raise exception '관리자만 바꿀 수 있어요.'; end if;
  update public.admin_config set show_demo = v_show, updated_at = now() where id = 1;
  insert into public.admin_logs (action, target_name, actor, detail)
  values ('데모 회원 노출', 'admin_config', 'admin', case when v_show then 'ON' else 'OFF' end);
  return jsonb_build_object('ok', true, 'show_demo', v_show);
end $$;

-- ============================================================================
-- 11. 가입 시 프로필 자동 생성 — 새 회원은 'pending'(가입 대기), 운영자 이메일은 'active'
--     (운영자 이메일은 admin_config 의 서버 설정값이라 가입자가 스스로 정할 수 없습니다)
-- ============================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_year   int  := nullif(new.raw_user_meta_data->>'birth_year','')::int;
  v_status text := 'pending';
  v_admin_email text;
begin
  select nullif(lower(btrim(coalesce(admin_email,''))), '')
    into v_admin_email
    from public.admin_config where id = 1;

  if v_admin_email is not null and lower(coalesce(new.email,'')) = v_admin_email then
    v_status := 'active';
  end if;

  insert into public.profiles (id, email, nickname, gender, birth_year, age, status)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data->>'nickname',''), split_part(coalesce(new.email,'회원'),'@',1)),
    nullif(new.raw_user_meta_data->>'gender',''),
    v_year,
    case when v_year is not null then extract(year from now())::int - v_year else null end,
    v_status
  )
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 기존 회원 안전 장치 — 가입 승인 기능을 켜기 전에 가입한 계정은 한 명도 잠기지 않습니다.
-- (신규 가입자는 auth.users.created_at 이 기준 시각보다 뒤라 여기에 걸리지 않습니다)
update public.profiles p
   set status = 'active'
  from auth.users u
 where u.id = p.id
   and p.status = 'pending'
   and u.created_at < (select c.signup_approval_since from public.admin_config c where c.id = 1);
   /* signup_approval_since 가 비어 있으면(NULL) 아무 줄도 바뀌지 않습니다 — 한 번도 잠그지 않는 쪽으로 안전하게. */

update public.profiles
   set status = 'active'
 where status = 'pending'
   and is_admin = true;

update public.profiles p
   set status = 'active'
  from public.admin_config c
 where c.id = 1
   and coalesce(c.admin_email,'') <> ''
   and lower(coalesce(p.email,'')) = lower(c.admin_email)
   and p.status = 'pending';

-- ============================================================================
-- 12. Row Level Security
-- ============================================================================
alter table public.profiles        enable row level security;
alter table public.verifications   enable row level security;
alter table public.likes_matches   enable row level security;
alter table public.messages        enable row level security;
alter table public.reviews         enable row level security;
alter table public.charge_requests enable row level security;
alter table public.reports         enable row level security;
alter table public.admin_logs      enable row level security;
alter table public.admin_config    enable row level security;

-- ---- profiles -------------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or status = 'active' or public.is_admin());

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = auth.uid());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ---- verifications --------------------------------------------------------
drop policy if exists verifications_select on public.verifications;
create policy verifications_select on public.verifications for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists verifications_insert on public.verifications;
create policy verifications_insert on public.verifications for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- ---- likes_matches -------------------------------------------------------
drop policy if exists likes_matches_select on public.likes_matches;
create policy likes_matches_select on public.likes_matches for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid() or public.is_admin());

-- ---- messages ------------------------------------------------------------
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (exists (select 1 from public.likes_matches m
                  where m.id = messages.match_id
                    and (m.from_user = auth.uid() or m.to_user = auth.uid())));

-- ---- reviews -------------------------------------------------------------
drop policy if exists reviews_select on public.reviews;
create policy reviews_select on public.reviews for select to authenticated
  using (author_id = auth.uid() or public.is_admin());

-- ---- charge_requests -----------------------------------------------------
drop policy if exists charge_requests_select on public.charge_requests;
create policy charge_requests_select on public.charge_requests for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- ---- reports -------------------------------------------------------------
drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin());

drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated
  with check (reporter_id = auth.uid());

-- ---- admin_logs (관리자만 읽기, 쓰기는 함수가 대신) ------------------------
drop policy if exists admin_logs_select on public.admin_logs;
create policy admin_logs_select on public.admin_logs for select to authenticated
  using (public.is_admin());

-- ---- admin_config : 정책 없음 = 직접 접근 불가 (함수로만) ------------------

-- ============================================================================
-- 13. 열(column) 단위 권한 — 남에게 보이면 안 되는 값은 아예 못 읽게
-- ============================================================================
revoke all on public.profiles from anon, authenticated;
grant select (id, nickname, gender, birth_year, age, job, company, region, mbti,
              height, bio, priorities, verified, height_verified, status, avatar_data,
              hobbies, values_list, photo_captions, dist_km, job_stable,
              nonsmoker, is_demo, created_at)
  on public.profiles to authenticated;
grant insert (id, nickname, gender, birth_year, age, job, region, mbti,
              height, bio, priorities, avatar_data, phone_hash, hobbies,
              values_list, photo_captions, dist_km, job_stable, nonsmoker)
  on public.profiles to authenticated;
-- 회사명은 직장인 인증 승인 함수만 기록합니다(본인이 임의로 바꿀 수 없음).
grant update (nickname, gender, birth_year, age, job, region, mbti,
              height, bio, priorities, avatar_data, phone_hash, hobbies,
              values_list, photo_captions, dist_km, job_stable, nonsmoker)
  on public.profiles to authenticated;

revoke all on public.verifications from anon, authenticated;
grant select on public.verifications to authenticated;
grant insert (user_id, method, company, company_email, doc_name, doc_preview, claimed_height, status)
  on public.verifications to authenticated;

revoke all on public.likes_matches from anon, authenticated;
grant select on public.likes_matches to authenticated;

revoke all on public.messages from anon, authenticated;
grant select on public.messages to authenticated;

revoke all on public.reviews from anon, authenticated;
grant select on public.reviews to authenticated;

revoke all on public.charge_requests from anon, authenticated;
grant select on public.charge_requests to authenticated;

revoke all on public.reports from anon, authenticated;
grant select on public.reports to authenticated;
grant insert (reporter_id, target_user_id, reason, detail)
  on public.reports to authenticated;

revoke all on public.admin_logs from anon, authenticated;
grant select on public.admin_logs to authenticated;

revoke all on public.admin_config from anon, authenticated;

-- 서버 함수 실행 권한
grant execute on function
  public.is_admin(), public.my_state(), public.expire_likes(), public.send_like(uuid),
  public.pass_profile(uuid), public.undo_pass(uuid), public.respond_like(uuid, boolean),
  public.send_message(uuid, text), public.mark_read(uuid), public.plan_meeting(uuid, timestamptz),
  public.confirm_met(uuid), public.submit_review(uuid, int, text),
  public.request_charge(int, int, text), public.redeem_points(),
  public.update_safety(boolean, jsonb, jsonb), public.get_payment_info(),
  public.admin_claim(text), public.admin_review_verification(uuid, boolean, text, text, integer),
  public.admin_review_charge(uuid, boolean, text), public.admin_review_report(uuid, text),
  public.admin_restore_user(uuid), public.admin_save_payment(text, text, text, text),
  public.admin_set_demo(boolean),
  public.admin_signup_list(), public.admin_review_signup(uuid, boolean, text)
  to authenticated;

-- ============================================================================
-- 13.5 영구 중복 차단 · 하루 두 장 DB 동기화 (supabase_no_repeat.sql 과 같은 내용)
--      · 이미 본 상대(건너뛰기 · 호감 · 매칭 · 차단 · 신고)는 다시 추천하지 않습니다.
--      · 오늘의 두 장은 today_deck() 이 DB에서 정하고, 하루 두 장을 넘지 않습니다.
--
-- 1) seen_targets — '내가 이미 본 상대' 영구 명부
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
-- 2) 같은 사람 식별용 해시 (번호 우선 · 없으면 이메일)
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
-- 3) 건너뛰기 · 호감 · 매칭이 생기면 자동으로 seen_targets 에 기록
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
-- 4) note_seen() — 차단 · 신고도 영구 명부에 남기기 (앱이 함께 호출)
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
-- 5) today_deck() — 오늘의 인연 두 장을 DB에서 골라 배정하고 돌려줍니다
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
-- 6) Row Level Security · 권한 — 내 명부는 나만 읽습니다 (쓰기는 함수만)
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
-- 13-2. 사진 열람권 — 사진은 기본 비공개, 매칭권 1장(990원)으로 열람
--   · photo_unlocks : (viewer_id, target_id) 한 쌍에 한 줄. 한 번 열면 계속 남습니다.
--   · unlock_photo() : 매칭권 1장을 원자적으로 차감하고 열람을 기록
--   · photo_view()   : 본인 · 운영자 · 열람권을 산 상대에게만 사진을 돌려줍니다
-- ============================================================================
create table if not exists public.photo_unlocks (
  viewer_id  uuid not null references public.profiles(id) on delete cascade,
  target_id  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (viewer_id, target_id)
);

create index if not exists photo_unlocks_target_idx on public.photo_unlocks (target_id);

comment on table public.photo_unlocks is
  '매칭권으로 연 사진 기록 — (viewer_id 가 target_id 의 사진을 열람함). 한 번 열면 계속 유지됩니다.';
comment on column public.photo_unlocks.created_at is '사진을 연 시각 (매칭권 1장 차감 시점)';

create or replace function public.unlock_photo(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me      uuid := auth.uid();
  v_tickets int;
  v_status  text;
  v_cost    int := 1;      -- 매칭권 1장 = 990원
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;
  if p_target is null then raise exception '상대 프로필을 찾을 수 없어요.'; end if;
  if p_target = v_me then
    return jsonb_build_object('ok', true, 'already', true, 'self', true);
  end if;

  select status into v_status from public.profiles where id = p_target;
  if v_status is null then raise exception '상대 프로필을 찾을 수 없어요.'; end if;
  if v_status <> 'active' then raise exception '지금은 사진을 열 수 없는 프로필이에요.'; end if;

  /* 이미 열어 둔 사진 — 다시 차감하지 않습니다. */
  if exists (select 1 from public.photo_unlocks u
              where u.viewer_id = v_me and u.target_id = p_target) then
    select match_tickets into v_tickets from public.profiles where id = v_me;
    return jsonb_build_object('ok', true, 'already', true, 'tickets', coalesce(v_tickets, 0));
  end if;

  /* 같은 순간 두 번 눌러도 한 번만 차감되도록 내 줄을 잠급니다. */
  select match_tickets into v_tickets from public.profiles where id = v_me for update;
  if coalesce(v_tickets, 0) < v_cost then
    raise exception '매칭권이 없어요. 충전 후 다시 시도해 주세요.';
  end if;

  update public.profiles
     set match_tickets = match_tickets - v_cost
   where id = v_me
  returning match_tickets into v_tickets;

  insert into public.photo_unlocks (viewer_id, target_id)
  values (v_me, p_target)
  on conflict (viewer_id, target_id) do nothing;

  return jsonb_build_object('ok', true, 'already', false, 'tickets', v_tickets, 'cost', v_cost);
end $$;
grant execute on function public.unlock_photo(uuid) to authenticated;

create or replace function public.photo_view(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me      uuid := auth.uid();
  v_row     public.profiles;
  v_allowed boolean := false;
  v_photos  jsonb := '[]'::jsonb;
  v_raw     text;
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;
  if p_target is null then
    return jsonb_build_object('ok', false, 'locked', true, 'photos', '[]'::jsonb, 'captions', '[]'::jsonb);
  end if;

  select * into v_row from public.profiles where id = p_target;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'locked', true, 'photos', '[]'::jsonb, 'captions', '[]'::jsonb);
  end if;

  v_allowed := (p_target = v_me)
            or public.is_admin()
            or exists (select 1 from public.photo_unlocks u
                        where u.viewer_id = v_me and u.target_id = p_target);

  if not v_allowed then
    return jsonb_build_object('ok', true, 'locked', true,
                              'is_demo', coalesce(v_row.is_demo, false),
                              'photos', '[]'::jsonb, 'captions', '[]'::jsonb);
  end if;

  /* avatar_data 는 JSON 배열 문자열이거나 data URL 한 장입니다. 어느 쪽이든 안전하게 읽습니다. */
  v_raw := btrim(coalesce(v_row.avatar_data, ''));
  begin
    if v_raw = '' then
      v_photos := '[]'::jsonb;
    elsif left(v_raw, 1) = '[' then
      v_photos := v_raw::jsonb;
    else
      v_photos := jsonb_build_array(v_raw);
    end if;
  exception when others then
    v_photos := '[]'::jsonb;
  end;

  return jsonb_build_object(
    'ok', true, 'locked', false,
    'is_demo', coalesce(v_row.is_demo, false),
    'photos', v_photos,
    'captions', coalesce(v_row.photo_captions, '[]'::jsonb)
  );
end $$;
grant execute on function public.photo_view(uuid) to authenticated;

alter table public.photo_unlocks enable row level security;

drop policy if exists photo_unlocks_select on public.photo_unlocks;
create policy photo_unlocks_select on public.photo_unlocks for select to authenticated
  using (viewer_id = auth.uid() or public.is_admin());

revoke all on public.photo_unlocks from anon, authenticated;
grant select (viewer_id, target_id, created_at) on public.photo_unlocks to authenticated;

-- ============================================================================
-- 13-3. 운영자 매칭 v2 — 매칭 시간제 · 날짜별 배정 · 운영자 회원/매칭권 관리
--   (supabase_admin_matching_v2.sql 과 같은 내용입니다. 처음 설치할 때도 이 파일 하나로 충분)
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
    'religion',        p.religion,
    'tattoo',          p.tattoo,
    'drinking',        p.drinking,
    'smoking',         coalesce(nullif(btrim(coalesce(p.smoking, '')), ''),
                                case when coalesce(p.nonsmoker, false) then '비흡연' end),
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
         where lm.status = 'matched' and (lm.from_user = p.id or lm.to_user = p.id)), 0),

    /* 과거 오늘의 인연 전체 — 최신 날짜순.
       ① daily_matches : 20:30 자동 배정 + 운영자 수기 교체 + 결과·사유
       ② seen_targets  : 예전 today_deck 기록(배정 표가 생기기 전 날짜) 중 위에 없는 것
       ③ likes_matches : 수락(호감) · 매칭 · 거절(건너뛰기) · 무응답 · 대화 종료 상태  */
    'history', coalesce((
      with base as (
        select dm.match_date, dm.slot::int as slot, dm.target_id, dm.outcome, dm.reason, dm.outcome_at
          from public.daily_matches dm
         where dm.user_id = p.id
        union all
        select st.served_on, null::int, st.target_id, null::text, null::text, null::timestamptz
          from public.seen_targets st
         where st.user_id = p.id
           and st.served_on is not null
           and not exists (
             select 1 from public.daily_matches dm2
              where dm2.user_id = st.user_id
                and dm2.target_id = st.target_id
                and dm2.match_date = st.served_on)
      ), paired as (
        select m.*, lm.status as like_status
          from base m
          left join lateral (
            select l.status
              from public.likes_matches l
             where (l.from_user = p.id and l.to_user = m.target_id)
                or (l.from_user = m.target_id and l.to_user = p.id)
             order by (l.status = 'matched') desc,
                      (l.from_user = p.id) desc,
                      (l.status in ('liked', 'matched')) desc,
                      l.created_at desc
             limit 1
          ) lm on true
      ), resolved as (
        select pr.*,
               case
                 when pr.like_status = 'matched' then 'matched'
                 when pr.outcome = 'declined' or pr.like_status = 'passed' then 'declined'
                 when pr.like_status = 'expired_refunded' then 'expired'
                 when pr.like_status = 'ended' then 'ended'
                 when pr.outcome = 'accepted' or pr.like_status = 'liked' then 'accepted'
                 else 'pending'
               end as final_outcome
          from paired pr
      )
      select jsonb_agg(jsonb_build_object(
               'date',       to_char(r.match_date, 'YYYY-MM-DD'),
               'slot',       r.slot,
               'target_id',  r.target_id,
               'nickname',   t.nickname,
               'birth_year', t.birth_year,
               'age',        t.age,
               'job',        t.job,
               'outcome',    r.final_outcome,
               'outcome_at', r.outcome_at,
               'reason',     nullif(btrim(coalesce(r.reason, '')), '')
             ) order by r.match_date desc, coalesce(r.slot, 0) asc)
        from resolved r
        left join public.profiles t on t.id = r.target_id
    ), '[]'::jsonb)
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

-- ============================================================================
-- 14. 데모 프로필 14명 (앱에서 '데모' 표시로 구분, 관리자 화면에서만 삭제 가능)
--     6명은 처음부터, 8명은 '데모 후보 추가' 증분 SQL 과 같은 값입니다.
-- ============================================================================
insert into public.profiles
  (id, email, nickname, gender, birth_year, age, job, company, company_domain, region, mbti, height,
   bio, match_tickets, points, verified, status, hidden_company, hobbies, values_list, photo_captions,
   dist_km, job_stable, nonsmoker, is_demo)
values
  ('a0000000-0000-4000-8000-000000000001', 'dohyun@example.com', '김도현', 'male', 1990, 36,
   '건축가', '성수건축', 'seongsu-arch.com', '성수동', 'ENFJ', 182,
   '주말엔 전시 보러 가고, 집에서는 커피 내려 마셔요. 말이 잘 통하는 사람이면 좋겠어요.',
   2, 0, true, 'active', true,
   '["전시·건축","홈카페","러닝"]', '["다정한 대화","꾸준함"]', '["성수동 작업실","주말 홈카페","전시 보러 가는 날"]',
   1.2, true, true, true),
  ('a0000000-0000-4000-8000-000000000002', 'junho@example.com', '이준호', 'male', 1992, 34,
   '프로덕트 디자이너', '스튜디오 모노', 'studio-mono.kr', '망원동', 'INFP', 178,
   '필름카메라 들고 동네를 자주 걸어요. 조용한 데서 오래 이야기하는 걸 좋아합니다.',
   2, 0, true, 'active', true,
   '["필름카메라","망원시장","재즈"]', '["진솔함","존중"]', '["망원동 산책","필름 스캔하는 밤","단골 재즈바"]',
   8.4, true, true, true),
  ('a0000000-0000-4000-8000-000000000003', 'jihoon@example.com', '박지훈', 'male', 1993, 33,
   '초등 교사', '늘봄초등학교', 'neulbom.es.kr', '일산', 'ISFJ', 176,
   '아이들을 가르쳐요. 주말엔 등산이나 요리로 쉬어요. 편안한 사람이 좋습니다.',
   2, 0, false, 'active', true,
   '["등산","요리","독서"]', '["편안함","성실함"]', '["교실 풍경","주말 등산","요리하는 밤"]',
   24, true, true, true),
  ('a0000000-0000-4000-8000-000000000004', 'woojin@example.com', '정우진', 'male', 1989, 37,
   '데이터 엔지니어', '데이터브릿지', 'databridge.io', '판교', 'ISTJ', 180,
   '클라이밍과 위스키를 좋아해요. 계획한 건 끝까지 해내는 편입니다.',
   2, 0, false, 'active', true,
   '["클라이밍","위스키","독서"]', '["신뢰","계획성"]', '["퇴근 후 클라이밍","위스키 한 잔","독서하는 주말"]',
   19, true, false, true),
  ('a0000000-0000-4000-8000-000000000005', 'jihoo@example.com', '서지후', 'male', 1991, 35,
   '사진작가', '프레임워크 스튜디오', 'framework.studio', '연남동', 'ENTJ', 179,
   '빛이 좋은 시간에 사진을 찍어요. 대화는 솔직한 쪽이 좋습니다.',
   2, 0, false, 'active', true,
   '["필름카메라","전시·출사","재즈바"]', '["진솔함","자유로움"]', '["연남동 스냅","작업실 한 컷","노을 출사"]',
   6, false, false, true),
  ('a0000000-0000-4000-8000-000000000006', 'yuna@example.com', '최유나', 'female', 1994, 32,
   '마케터', '한빛상사', 'hanbit.co.kr', '성수동', 'ESFJ', 165,
   '브랜드 마케팅을 해요. 주말엔 베이킹과 전시를 좋아합니다.',
   2, 0, false, 'active', true,
   '["베이킹","전시","요가"]', '["유머 코드","안정적인 생활"]', '["동네 카페","베이킹하는 밤","전시 관람"]',
   2.5, true, true, true)
on conflict (id) do nothing;

-- 데모 후보 8명 더 (남 4 · 여 4) — id 는 ...0007 ~ ...0014 로 고정, already 있으면 건너뜁니다.
insert into public.profiles
  (id, email, nickname, gender, birth_year, age, job, company, company_domain, region, mbti, height,
   bio, match_tickets, points, verified, status, hidden_company, hobbies, values_list, photo_captions,
   dist_km, job_stable, nonsmoker, is_demo, priorities)
values
  ('a0000000-0000-4000-8000-000000000007', 'sejun@example.com', '오세준', 'male', 1988, 38,
   '제품 기획자', '모노랩스', 'monolabs.kr', '서울시 마포구', 'INTJ', 181,
   '앱 기획자로 일해요. 아침엔 한강을 따라 30분즈음 뛰고, 주말엔 전시를 보러 갑니다. 회의가 많은 주라도 저녁에는 책을 읽거나 와인 한 잔을 곰들어는 시간을 꼭 만들어요. 말수가 아주 많은 편은 아니지만, 좋아하는 사람에게는 하루에 있었던 일을 하나씩 나누는 쪽입니다. 서로의 자리를 존중하면서도 오래 이야기할 수 있는 사람이면 좋겠어요. 여행은 계획형이라 짐을 미리 싸 두는 편이고, 최근에는 교토와 타이베이를 다녀왔습니다.',
   2, 0, true, 'active', true,
   '["러닝","와인","전시"]', '["솔직함","꾸준함"]', '["회사 창가","한강 러닝","동네 와인바"]',
   4.2, true, true, true,
   '{"priorities":["personality","job","hobby"],"mbti":[],"ageMin":29,"ageMax":39,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000008', 'minjae@example.com', '권민재', 'male', 1986, 40,
   '세무사', '민재세무회계', 'mj-tax.co.kr', '서울시 강남구', 'ESTJ', 174,
   '작은 사업자들의 장부를 봐 줍니다. 숫자를 다루는 일이라 약속과 시간을 특히 중요하게 생각해요.',
   2, 0, true, 'active', true,
   '["골프","독서","와인"]', '["성실함","책임감"]', '["사무실 장부","주말 라운딩","와인 한 잔"]',
   12.6, true, true, true,
   '{"priorities":["job","personality","habit"],"mbti":[],"ageMin":30,"ageMax":42,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000009', 'seunghyun@example.com', '백승현', 'male', 1994, 32,
   '임상간호사', '푸른병원', 'pureun-hospital.kr', '서울시 송파구', 'ISFP', 178,
   '삼교대 근무라 주말이 꼭 주말은 아니지만, 쉬는 날엔 자전거를 타거나 집에서 파스타를 만듭니다. 조용한 다정함을 좋아해요.',
   2, 0, false, 'active', true,
   '["자전거","요리","영화"]', '["다정함","건강한 생활"]', '["퇴근길 한강","주말 파스타","영화 보는 밤"]',
   16.8, true, true, true,
   '{"priorities":["personality","age","area"],"mbti":[],"ageMin":28,"ageMax":38,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000010', 'jaeyun@example.com', '문재윤', 'male', 1996, 30,
   '백엔드 개발자', '코드베이스', 'codebase.dev', '경기도 성남시', 'INTP', 176,
   '서버 만드는 일을 해요. 주말엔 클라이밍과 보드게임, 평일 저녁엔 동네 카페에서 커피를 마십니다. 말보다 행동이 편한 사람이에요.',
   2, 0, false, 'active', true,
   '["클라이밍","보드게임","커피"]', '["자유로움","호기심"]', '["퇴근 후 클라이밍","보드게임 밤","동네 카페"]',
   21.4, true, false, true,
   '{"priorities":["hobby","personality","looks"],"mbti":[],"ageMin":27,"ageMax":36,"areas":["서울시 전체","경기도 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000011', 'soyoung@example.com', '한소영', 'female', 1992, 34,
   '브랜드 디자이너', '스튜디오 결', 'gyeol.studio', '서울시 마포구', 'INFJ', 168,
   '브랜드의 말투와 표정을 만드는 일을 해요. 주말엔 도자기를 빚거나 전시를 보러 가고, 밤에는 재즈를 틀어 둡니다. 섬세한 이야기를 오래 나눌 수 있는 사람이면 좋겠어요.',
   2, 0, true, 'active', true,
   '["전시","도자기","재즈"]', '["섬세함","존중"]', '["작업실 책상","도자기 굽는 날","재즈바"]',
   6.4, false, true, true,
   '{"priorities":["personality","hobby","job"],"mbti":[],"ageMin":30,"ageMax":41,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000012', 'sera@example.com', '김세라', 'female', 1989, 37,
   '약사', '햇살약국', 'hatsal-pharm.kr', '서울시 노원구', 'ISTJ', 162,
   '동네 약국을 지키고 있어요. 아침 일찍 문을 열고 저녁에 닫는 규칙적인 하루를 살아요. 주말엔 북한산 쪽으로 등산을 다니거나 집에서 빵을 굽니다. 약속은 꼭 지키는 편이에요.',
   2, 0, true, 'active', true,
   '["등산","베이킹","독서"]', '["안정적인 생활","성실함"]', '["약국 창가","주말 등산","빵 굽는 오후"]',
   18.2, true, true, true,
   '{"priorities":["habit","job","personality"],"mbti":[],"ageMin":31,"ageMax":43,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000013', 'haneul@example.com', '정하늘', 'female', 1995, 31,
   '콘텐츠 에디터', '페이지원', 'pageone.kr', '서울시 종로구', 'ENFP', 165,
   '책 만드는 일을 해요. 서촌 골목을 걷다가 마음에 드는 카페를 찾으면 한참 앉아 있습니다. 필름카메라로 일상을 남기는 걸 좋아하고, 우스운 이야기에 잘 넘어가는 편이에요.',
   2, 0, false, 'active', true,
   '["책","카페 투어","필름카메라"]', '["유머 코드","솔직함"]', '["서촌 골목","카페 창가","필름 스캔"]',
   9.6, false, true, true,
   '{"priorities":["personality","hobby","age"],"mbti":[],"ageMin":28,"ageMax":38,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000014', 'sumin@example.com', '배수민', 'female', 1991, 35,
   'HR 매니저', '세림산업', 'serim.co.kr', '경기도 성남시', 'ESTJ', 167,
   '사람을 뽑고 함께 일하는 일을 해요. 계획 세우는 걸 좋아해서 여행도 일정표부터 만듭니다. 주말엔 요가를 하고 와인을 한 잔 마시며 한 주를 정리해요.',
   2, 0, true, 'active', true,
   '["요가","와인","여행"]', '["책임감","계획성"]', '["분당 사무실","주말 요가","여행 일정표"]',
   20.5, true, true, true,
   '{"priorities":["job","personality","style"],"mbti":[],"ageMin":30,"ageMax":40,"areas":["서울시 전체","경기도 전체"],"values":[]}'::jsonb)
on conflict (id) do nothing;

-- 데모 프로필의 생활 정보 — 화면 확인용 값 (이미 채워져 있으면 건드리지 않습니다)
update public.profiles p
   set religion = v.religion,
       tattoo   = v.tattoo,
       drinking = v.drinking,
       smoking  = v.smoking,
       nonsmoker = (v.smoking = '비흡연')
  from (values
    ('a0000000-0000-4000-8000-000000000001'::uuid, '무교',   '없음',           '가끔(1~2잔)',      '비흡연'),
    ('a0000000-0000-4000-8000-000000000002'::uuid, '기독교', '없음',           '적당히(1병 내외)', '비흡연'),
    ('a0000000-0000-4000-8000-000000000003'::uuid, '무교',   '없음',           '비음주',           '비흡연'),
    ('a0000000-0000-4000-8000-000000000004'::uuid, '불교',   '작은 타투 있음', '즐기는 편',        '전자담배'),
    ('a0000000-0000-4000-8000-000000000005'::uuid, '천주교', '없음',           '가끔(1~2잔)',      '비흡연'),
    ('a0000000-0000-4000-8000-000000000006'::uuid, '무교',   '없음',           '가끔(1~2잔)',      '비흡연'),
    ('a0000000-0000-4000-8000-000000000007'::uuid, '무교',   '없음',           '적당히(1병 내외)', '비흡연'),
    ('a0000000-0000-4000-8000-000000000008'::uuid, '기독교', '없음',           '즐기는 편',        '비흡연'),
    ('a0000000-0000-4000-8000-000000000009'::uuid, '무교',   '있음',           '가끔(1~2잔)',      '전자담배'),
    ('a0000000-0000-4000-8000-000000000010'::uuid, '무교',   '없음',           '비음주',           '비흡연'),
    ('a0000000-0000-4000-8000-000000000011'::uuid, '무교',   '작은 타투 있음', '가끔(1~2잔)',      '비흡연'),
    ('a0000000-0000-4000-8000-000000000012'::uuid, '천주교', '없음',           '적당히(1병 내외)', '비흡연'),
    ('a0000000-0000-4000-8000-000000000013'::uuid, '불교',   '없음',           '비음주',           '비흡연'),
    ('a0000000-0000-4000-8000-000000000014'::uuid, '무교',   '없음',           '즐기는 편',        '비흡연')
  ) as v(id, religion, tattoo, drinking, smoking)
 where p.id = v.id
   and p.religion is null
   and p.tattoo   is null
   and p.drinking is null
   and p.smoking  is null;

-- ============================================================================
-- 15. 첫 로그인 때 데모 상호작용 채우기 (받은 호감 2 · 매칭 대화 1 · 심사 대기 2 등)
--     앱이 자동으로 한 번 호출합니다. 필요 없으면 실행하지 않아도 됩니다.
-- ============================================================================
create or replace function public.seed_demo_for_me() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_seeded boolean;
  v_match uuid;
  v_m1 uuid := 'a0000000-0000-4000-8000-000000000001';  -- 김도현
  v_m2 uuid := 'a0000000-0000-4000-8000-000000000002';  -- 이준호
  v_m3 uuid := 'a0000000-0000-4000-8000-000000000003';  -- 박지훈
  v_m4 uuid := 'a0000000-0000-4000-8000-000000000004';  -- 정우진
  v_m5 uuid := 'a0000000-0000-4000-8000-000000000005';  -- 서지후
  v_f1 uuid := 'a0000000-0000-4000-8000-000000000006';  -- 최유나
begin
  if v_me is null then raise exception '로그인이 필요해요.'; end if;
  select demo_seeded into v_seeded from public.profiles where id = v_me;
  if coalesce(v_seeded,false) then return jsonb_build_object('seeded', false); end if;

  begin
    insert into public.likes_matches (from_user, to_user, status, expires_at)
    values (v_m2, v_me, 'liked', now() + interval '40 hours'),
           (v_m4, v_me, 'liked', now() + interval '30 hours')
    on conflict do nothing;
  exception when others then null; end;

  begin
    insert into public.likes_matches (from_user, to_user, status, matched_at, created_at)
    values (v_m5, v_me, 'matched', now() - interval '3 days', now() - interval '3 days')
    on conflict do nothing;
    select id into v_match from public.likes_matches
     where status = 'matched'
       and ((from_user = v_m5 and to_user = v_me) or (from_user = v_me and to_user = v_m5))
     limit 1;
    if v_match is not null and not exists (select 1 from public.messages where match_id = v_match) then
      insert into public.messages (match_id, sender_id, body, created_at) values
        (v_match, v_m5, '안녕하세요 :) 프로필 잘 봤어요. 사진 좋아하신다길래 반가웠어요.', now() - interval '3 days'),
        (v_match, v_me, '반가워요! 요즘은 필름카메라로 동네 사진을 찍고 있어요.', now() - interval '3 days' + interval '40 minutes'),
        (v_match, v_m5, '오, 그거 궁금하네요. 다음에 한 장 보여주실 수 있어요?', now() - interval '1 day');
    end if;
  exception when others then null; end;

  begin
    insert into public.verifications (user_id, method, company, company_email, status, created_at) values
      (v_m1, 'email', '성수건축', 'dohyun@seongsu-arch.com', 'pending', now() - interval '3 hours'),
      (v_m3, 'doc', '늘봄초등학교', null, 'pending', now() - interval '5 hours'),
      (v_m2, 'email', '스튜디오 모노', 'junho@studio-mono.kr', 'approved', now() - interval '2 days');
  exception when others then null; end;

  begin
    insert into public.charge_requests (user_id, package_name, tickets, amount_krw, depositor_name, status, created_at)
    values (v_f1, '5장 묶음', 5, 4900, '최유나', 'pending', now() - interval '7 hours');
  exception when others then null; end;

  begin
    insert into public.reports (reporter_id, target_user_id, reason, detail, status, created_at)
    values (v_f1, v_m4, '허위 프로필 의심', '직장인 인증 배지가 있는데 회사에 그런 사람이 없다고 해요.', 'open', now() - interval '4 hours');
  exception when others then null; end;

  update public.profiles set demo_seeded = true where id = v_me;
  return jsonb_build_object('seeded', true);
end $$;

grant execute on function public.seed_demo_for_me() to authenticated;

-- ============================================================================
-- 16. 확인용 (선택) — 실행하면 아래 표에 결과가 보입니다.
-- ============================================================================
select 'profiles' as table_name, count(*) as rows from public.profiles
union all select 'daily_matches', count(*) from public.daily_matches
union all select 'photo_unlocks', count(*) from public.photo_unlocks
union all select 'verifications', count(*) from public.verifications
union all select 'likes_matches', count(*) from public.likes_matches
union all select 'messages', count(*) from public.messages
union all select 'reviews', count(*) from public.reviews
union all select 'charge_requests', count(*) from public.charge_requests
union all select 'reports', count(*) from public.reports
union all select 'admin_logs', count(*) from public.admin_logs
union all select 'admin_config', count(*) from public.admin_config;
