-- ============================================================================
--  990 인연 · 가입 대기(pending) · 운영자 가입 승인 (증분 SQL)
-- ----------------------------------------------------------------------------
--  사용법
--   1) Supabase 대시보드 → 왼쪽 SQL Editor → New query
--   2) 이 파일 전체를 붙여넣고 RUN
--   3) 여러 번 다시 실행해도 안전합니다 (idempotent)
--
--  이 스크립트가 바꾸는 것
--   · 새로 가입한 회원은 profiles.status = 'pending' (가입 대기) 로 들어옵니다.
--     → 앱에 들어오지 못하고 "가입 승인 대기 중" 화면만 보입니다.
--   · 운영자 콘솔에서 [가입 대기] 탭 → 승인하면 'active' 로 바뀌어 입장합니다.
--     반려하면 'rejected' 가 되고 같은 화면에서 안내만 보입니다.
--   · 이미 활동 중인 기존 회원('active')과 이용 정지('suspended')는 그대로 둡니다.
--     (아래 4번의 안전 장치까지 포함해 한 명도 잠기지 않습니다)
--   · 승인/반려는 SECURITY DEFINER 함수(admin_review_signup)만 할 수 있고,
--     is_admin() 검사를 통과해야 하며, 모든 처리는 admin_logs 에 남습니다.
--
--  ⚠ 비밀키(service_role)는 어디에도 쓰지 않습니다.
--  ⚠ 이 파일만 따로 실행해도 되고, 새로 설치할 때는 supabase_schema.sql 안에
--     같은 내용이 들어 있어 그것만 실행해도 됩니다.
-- ============================================================================

-- ============================================================================
-- 0. 마이그레이션 기준 시각 — "이 시각 이전에 가입한 사람"은 기존 회원으로 봅니다.
--    한 번만 기록되고, 다시 실행해도 바뀌지 않습니다.
-- ============================================================================
alter table public.admin_config add column if not exists signup_approval_since timestamptz;
update public.admin_config
   set signup_approval_since = now()
 where id = 1
   and signup_approval_since is null;

-- ============================================================================
-- 1. profiles.status 기본값 → 'pending'
--    status 값: 'pending'(가입 대기) | 'active'(입장 가능) | 'rejected'(가입 반려)
--               | 'suspended'(이용 정지)
--    · 앱에서 새 프로필 줄을 만들 때 status 를 직접 넣을 수 없으므로(열 권한),
--      새 줄은 언제나 이 기본값을 따릅니다.
--    · 이미 있는 줄은 기본값 변경과 관계없이 그대로 유지됩니다.
-- ============================================================================
alter table public.profiles alter column status set default 'pending';

comment on column public.profiles.status is
  '''pending'' 가입 승인 대기 / ''active'' 입장 가능 / ''rejected'' 가입 반려 / ''suspended'' 이용 정지';

-- ============================================================================
-- 2. 가입 트리거 — 새 회원은 'pending', 운영자 이메일(admin_config.admin_email)은 'active'
--    (운영자 이메일은 서버 설정값이라 가입자가 스스로 정할 수 없습니다)
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

-- ============================================================================
-- 3. 운영자 계정은 가입 승인 대상이 아닙니다.
--    (admin_claim 으로 PIN 을 통과한 계정 = is_admin)
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

-- ============================================================================
-- 4. 기존 회원 안전 장치 — 이 기능을 켜기 전에 가입한 계정은 한 명도 잠기지 않게
--    (신규 가입자는 auth.users.created_at 이 기준 시각보다 뒤라 여기에 걸리지 않습니다)
-- ============================================================================
update public.profiles p
   set status = 'active'
  from auth.users u
 where u.id = p.id
   and p.status = 'pending'
   and u.created_at < (select c.signup_approval_since from public.admin_config c where c.id = 1);
   /* signup_approval_since 가 비어 있으면(NULL) 아무 줄도 바뀌지 않습니다 — 한 번도 잠그지 않는 쪽으로 안전하게. */

-- 운영자(is_admin) 계정과 관리자 이메일 계정도 그대로 활동 상태로 둡니다.
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
-- 5. 운영자 콘솔 — 가입 대기/반려 목록 (이메일은 열 권한으로 막혀 있어 함수로만 전달)
--    반환: [{ id, nickname, gender, birth_year, age, email, job, region,
--             status, created_at }]
-- ============================================================================
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

-- ============================================================================
-- 6. 가입 승인 / 반려
--    p_approve = true  → status 'active'   (입장 가능)
--    p_approve = false → status 'rejected' (가입 반려 · 사유는 admin_logs 에 기록)
-- ============================================================================
-- (재실행 안전) 예전 2개 인자 버전이 남아 있으면 먼저 정리
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

  update public.profiles
     set status = v_status
   where id = p_id;

  v_name := coalesce(v_row.nickname, v_row.email, p_id::text);

  insert into public.admin_logs (action, target_name, actor, detail)
  values (case when v_status = 'active' then '가입 승인' else '가입 반려' end,
          v_name, 'admin',
          coalesce(nullif(btrim(coalesce(p_note, '')), ''),
                   case when v_status = 'active' then '가입 승인 · 입장 가능' else '가입 반려' end));

  return jsonb_build_object('ok', true, 'status', v_status);
end $$;

-- ============================================================================
-- 7. 실행 권한 — 로그인한 사용자에게만 (함수 안에서 is_admin() 검사)
-- ============================================================================
grant execute on function public.admin_signup_list() to authenticated;
grant execute on function public.admin_review_signup(uuid, boolean, text) to authenticated;

-- ============================================================================
-- 8. 확인용 (선택) — 실행하면 아래 표에 결과가 보입니다.
-- ============================================================================
select p.status, count(*) as members
  from public.profiles p
 group by p.status
 order by p.status;

-- 가입 대기 목록 미리보기
select p.created_at, p.nickname, p.email, p.gender, p.birth_year, p.status
  from public.profiles p
 where p.status in ('pending', 'rejected')
 order by p.created_at asc;
