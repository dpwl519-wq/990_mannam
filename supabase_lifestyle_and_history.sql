-- ============================================================================
-- 990 인연 — 생활 정보(종교 · 문신 · 주량 · 흡연) + 운영자 회원 상세의 '오늘의 인연 히스토리'
--
-- 실행 방법
--   Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣고 Run.
--   여러 번 실행해도 안전합니다(이미 있는 열·함수는 그대로 다시 맞춥니다).
--
-- 이 파일이 하는 일
--   ① profiles 에 religion · tattoo · drinking · smoking 열 추가 (비어 있으면 null)
--      · 앱 화면(내 프로필 / 상대 상세 / 운영 콘솔)이 이 네 값을 읽고 씁니다.
--      · 앱의 '비흡연' 일치(우선순위 '비흡연·음주') 계산이 쓰던 nonsmoker 열과도 맞춰 둡니다.
--   ② 예시(데모) 프로필 14명에 화면 확인용 생활 정보 채우기 (비어 있을 때만)
--   ③ admin_member_detail() 확장 — 생활 정보 + 과거 '오늘의 인연' 전체 히스토리
--      · daily_matches(배정·결과·사유) + seen_targets(예전 today_deck 노출 기록)
--        + likes_matches(수락·매칭·거절 상태)를 합쳐 날짜별로 한 줄씩 돌려줍니다.
--      · 결과값: pending(대기) · accepted(수락) · declined(거절) · matched(매칭 성사)
--                · expired(무응답) · ended(대화 종료)
--
-- ⚠ service_role 비밀키는 쓰지 않습니다. 함수는 SECURITY DEFINER + is_admin() 검사로 보호됩니다.
-- ============================================================================

-- ============================================================================
-- 1. 생활 정보 열
-- ============================================================================
alter table public.profiles add column if not exists religion text;
alter table public.profiles add column if not exists tattoo   text;
alter table public.profiles add column if not exists drinking text;
alter table public.profiles add column if not exists smoking  text;

comment on column public.profiles.religion is '종교 — 무교 · 기독교 · 천주교 · 불교 · 기타 (선택 입력)';
comment on column public.profiles.tattoo   is '문신 — 없음 · 작은 타투 있음 · 있음 (선택 입력)';
comment on column public.profiles.drinking is '주량 — 비음주 · 가끔(1~2잔) · 적당히(1병 내외) · 즐기는 편 (선택 입력)';
comment on column public.profiles.smoking  is '흡연 — 비흡연 · 전자담배 · 흡연 (선택 입력, nonsmoker 열과 함께 갱신)';

-- 앱의 선택지와 같은 값만 들어가게 막아 둡니다(직접 DB 를 고칠 때의 실수 방지).
alter table public.profiles drop constraint if exists profiles_religion_chk;
alter table public.profiles add  constraint profiles_religion_chk
  check (religion is null or religion in ('무교', '기독교', '천주교', '불교', '기타'));

alter table public.profiles drop constraint if exists profiles_tattoo_chk;
alter table public.profiles add  constraint profiles_tattoo_chk
  check (tattoo is null or tattoo in ('없음', '작은 타투 있음', '있음'));

alter table public.profiles drop constraint if exists profiles_drinking_chk;
alter table public.profiles add  constraint profiles_drinking_chk
  check (drinking is null or drinking in ('비음주', '가끔(1~2잔)', '적당히(1병 내외)', '즐기는 편'));

alter table public.profiles drop constraint if exists profiles_smoking_chk;
alter table public.profiles add  constraint profiles_smoking_chk
  check (smoking is null or smoking in ('비흡연', '전자담배', '흡연'));

-- ============================================================================
-- 2. 예시(데모) 프로필 — 운영자 화면 확인용 값 (이미 채워져 있으면 건드리지 않음)
-- ============================================================================
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
-- 3. 운영자 — 회원 상세 (생활 정보 + 오늘의 인연 전체 히스토리)
-- ============================================================================
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
-- 4. 스키마 캐시 새로고침 — 앱에서 새 열이 바로 보이게
-- ============================================================================
notify pgrst, 'reload schema';
