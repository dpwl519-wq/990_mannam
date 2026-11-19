-- ============================================================================
--  990 인연 · Supabase 스키마 (v1.0)
-- ----------------------------------------------------------------------------
--  사용법
--   1) Supabase 대시보드 → 왼쪽 SQL Editor → New query
--   2) 이 파일 전체를 붙여넣고 RUN (한 번만 실행하면 됩니다)
--   3) 여러 번 다시 실행해도 안전합니다 (idempotent)
--
--  이 스크립트가 만드는 것
--   · 테이블 9개 + 운영 설정 1개 : profiles, verifications, likes_matches,
--     messages, reviews, charge_requests, reports, admin_logs, admin_config
--   · RLS 정책 + 열(column) 단위 권한 : 본인 것만 쓰기, 활성 프로필만 읽기
--   · 서버 함수(RPC) : 매칭권 차감·48시간 자동 반환·매칭 성사·후기 300P·
--     충전 요청·관리자 승인(매칭권 지급)·신고 정지 등 원자 처리
--   · 가입 시 자동 프로필 생성 트리거
--   · 데모 프로필 6명 시드
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
  updated_at     timestamptz not null default now(),
  constraint admin_config_single_row check (id = 1)
);
insert into public.admin_config (id) values (1) on conflict (id) do nothing;

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
  priorities      jsonb not null default '{"priorities":[],"mbti":[],"ageMin":30,"ageMax":40,"areas":["서울 전역"],"values":[]}'::jsonb,
  match_tickets   int  not null default 3,
  points          int  not null default 0,
  verified        boolean not null default false,
  status          text not null default 'active',         -- 'active' | 'suspended'
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
      ('blocked_phones','jsonb not null default ''[]''::jsonb'),
      ('blocked_profiles','jsonb not null default ''[]''::jsonb'),
      ('is_demo','boolean not null default false'), ('is_admin','boolean not null default false'),
      ('demo_seeded','boolean not null default false')
    ) as t(n, tp) loop
    execute format('alter table public.profiles add column if not exists %I %s', c.n, c.tp);
  end loop;
end $$;

create index if not exists profiles_status_idx on public.profiles (status, gender);

-- ============================================================================
-- 2. verifications — 직장인 인증 제출
-- ============================================================================
create table if not exists public.verifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  method        text not null default 'doc',              -- 'email' | 'doc'
  company       text default '',
  company_email text,
  doc_name      text,
  doc_preview   text,                                     -- 서류 이미지 data URL(축소본)
  status        text not null default 'pending',           -- 'pending' | 'approved' | 'rejected'
  reviewed_by   text,
  reviewed_at   timestamptz,
  note          text default '',                          -- 승인/반려 메모(반려 사유)
  created_at    timestamptz not null default now()
);
create index if not exists verifications_status_idx on public.verifications (status, created_at desc);
create index if not exists verifications_user_idx on public.verifications (user_id, created_at desc);

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
                        check (status in ('liked','matched','passed','expired_refunded')),
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

-- 내 지갑·안전 설정 (남에게 보이면 안 되는 값만 모아서 반환)
create or replace function public.my_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id,
    'match_tickets', p.match_tickets,
    'points', p.points,
    'verified', p.verified,
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
      -- 상대가 먼저 보낸 호감 → 서로 호감, 매칭 성사 (매칭권은 이미 쓴 상태)
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
create or replace function public.pass_profile(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  insert into public.likes_matches (from_user, to_user, status)
  values (auth.uid(), p_target, 'passed');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.undo_pass(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  delete from public.likes_matches
   where id = (select id from public.likes_matches
                where from_user = auth.uid() and to_user = p_target and status = 'passed'
                order by created_at desc limit 1);
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
    update public.profiles set is_admin = true where id = auth.uid();
    insert into public.admin_logs (action, target_name, actor, detail)
    values ('관리자 콘솔 로그인', coalesce(v_email,''), 'admin', '');
    v_ok := true;
  end if;
  return jsonb_build_object('ok', v_ok);
end $$;

create or replace function public.admin_review_verification(p_id uuid, p_approve boolean, p_note text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.verifications; v_name text;
begin
  if not public.is_admin() then raise exception '관리자만 처리할 수 있어요.'; end if;
  select * into v_row from public.verifications where id = p_id for update;
  if v_row.id is null then raise exception '제출 건을 찾을 수 없어요.'; end if;

  update public.verifications
     set status = case when p_approve then 'approved' else 'rejected' end,
         reviewed_by = 'admin', reviewed_at = now(), note = coalesce(p_note,'')
   where id = p_id;

  if p_approve then
    update public.profiles set verified = true where id = v_row.user_id;
  end if;

  select nickname into v_name from public.profiles where id = v_row.user_id;
  insert into public.admin_logs (action, target_name, actor, detail)
  values (case when p_approve then '인증 승인' else '인증 반려' end,
          coalesce(v_name, v_row.user_id::text), 'admin', coalesce(p_note, v_row.company, ''));

  return jsonb_build_object('ok', true);
end $$;

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

-- ============================================================================
-- 11. 가입 시 프로필 자동 생성
-- ============================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_year int := nullif(new.raw_user_meta_data->>'birth_year','')::int;
begin
  insert into public.profiles (id, email, nickname, gender, birth_year, age)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data->>'nickname',''), split_part(coalesce(new.email,'회원'),'@',1)),
    nullif(new.raw_user_meta_data->>'gender',''),
    v_year,
    case when v_year is not null then extract(year from now())::int - v_year else null end
  )
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

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
              height, bio, priorities, verified, status, avatar_data,
              hobbies, values_list, photo_captions, dist_km, job_stable,
              nonsmoker, is_demo, created_at)
  on public.profiles to authenticated;
grant insert (id, nickname, gender, birth_year, age, job, company, region, mbti,
              height, bio, priorities, avatar_data, phone_hash, hobbies,
              values_list, photo_captions, dist_km, job_stable, nonsmoker)
  on public.profiles to authenticated;
grant update (nickname, gender, birth_year, age, job, company, region, mbti,
              height, bio, priorities, avatar_data, phone_hash, hobbies,
              values_list, photo_captions, dist_km, job_stable, nonsmoker)
  on public.profiles to authenticated;

revoke all on public.verifications from anon, authenticated;
grant select on public.verifications to authenticated;
grant insert (user_id, method, company, company_email, doc_name, doc_preview, status)
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
  public.admin_claim(text), public.admin_review_verification(uuid, boolean, text),
  public.admin_review_charge(uuid, boolean, text), public.admin_review_report(uuid, text),
  public.admin_restore_user(uuid), public.admin_save_payment(text, text, text, text)
  to authenticated;

-- ============================================================================
-- 14. 데모 프로필 6명 (앱에서 '데모' 표시로 구분, 관리자 화면에서만 삭제 가능)
-- ============================================================================
insert into public.profiles
  (id, email, nickname, gender, birth_year, age, job, company, company_domain, region, mbti, height,
   bio, match_tickets, points, verified, status, hidden_company, hobbies, values_list, photo_captions,
   dist_km, job_stable, nonsmoker, is_demo)
values
  ('a0000000-0000-4000-8000-000000000001', 'dohyun@example.com', '김도현', 'male', 1990, 36,
   '건축가', '성수건축', 'seongsu-arch.com', '성수동', 'ENFJ', 182,
   '주말엔 전시 보러 가고, 집에서는 커피 내려 마셔요. 말이 잘 통하는 사람이면 좋겠어요.',
   3, 0, true, 'active', true,
   '["전시·건축","홈카페","러닝"]', '["다정한 대화","꾸준함"]', '["성수동 작업실","주말 홈카페","전시 보러 가는 날"]',
   1.2, true, true, true),
  ('a0000000-0000-4000-8000-000000000002', 'junho@example.com', '이준호', 'male', 1992, 34,
   '프로덕트 디자이너', '스튜디오 모노', 'studio-mono.kr', '망원동', 'INFP', 178,
   '필름카메라 들고 동네를 자주 걸어요. 조용한 데서 오래 이야기하는 걸 좋아합니다.',
   3, 0, true, 'active', true,
   '["필름카메라","망원시장","재즈"]', '["진솔함","존중"]', '["망원동 산책","필름 스캔하는 밤","단골 재즈바"]',
   8.4, true, true, true),
  ('a0000000-0000-4000-8000-000000000003', 'jihoon@example.com', '박지훈', 'male', 1993, 33,
   '초등 교사', '늘봄초등학교', 'neulbom.es.kr', '일산', 'ISFJ', 176,
   '아이들을 가르쳐요. 주말엔 등산이나 요리로 쉬어요. 편안한 사람이 좋습니다.',
   3, 0, false, 'active', true,
   '["등산","요리","독서"]', '["편안함","성실함"]', '["교실 풍경","주말 등산","요리하는 밤"]',
   24, true, true, true),
  ('a0000000-0000-4000-8000-000000000004', 'woojin@example.com', '정우진', 'male', 1989, 37,
   '데이터 엔지니어', '데이터브릿지', 'databridge.io', '판교', 'ISTJ', 180,
   '클라이밍과 위스키를 좋아해요. 계획한 건 끝까지 해내는 편입니다.',
   3, 0, false, 'active', true,
   '["클라이밍","위스키","독서"]', '["신뢰","계획성"]', '["퇴근 후 클라이밍","위스키 한 잔","독서하는 주말"]',
   19, true, false, true),
  ('a0000000-0000-4000-8000-000000000005', 'jihoo@example.com', '서지후', 'male', 1991, 35,
   '사진작가', '프레임워크 스튜디오', 'framework.studio', '연남동', 'ENTJ', 179,
   '빛이 좋은 시간에 사진을 찍어요. 대화는 솔직한 쪽이 좋습니다.',
   3, 0, false, 'active', true,
   '["필름카메라","전시·출사","재즈바"]', '["진솔함","자유로움"]', '["연남동 스냅","작업실 한 컷","노을 출사"]',
   6, false, false, true),
  ('a0000000-0000-4000-8000-000000000006', 'yuna@example.com', '최유나', 'female', 1994, 32,
   '마케터', '한빛상사', 'hanbit.co.kr', '성수동', 'ESFJ', 165,
   '브랜드 마케팅을 해요. 주말엔 베이킹과 전시를 좋아합니다.',
   3, 0, false, 'active', true,
   '["베이킹","전시","요가"]', '["유머 코드","안정적인 생활"]', '["동네 카페","베이킹하는 밤","전시 관람"]',
   2.5, true, true, true)
on conflict (id) do nothing;

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
union all select 'verifications', count(*) from public.verifications
union all select 'likes_matches', count(*) from public.likes_matches
union all select 'messages', count(*) from public.messages
union all select 'reviews', count(*) from public.reviews
union all select 'charge_requests', count(*) from public.charge_requests
union all select 'reports', count(*) from public.reports
union all select 'admin_logs', count(*) from public.admin_logs
union all select 'admin_config', count(*) from public.admin_config;
