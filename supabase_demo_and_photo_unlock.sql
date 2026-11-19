-- ============================================================================
--  990 인연 · 데모 후보 8명 추가 + 사진 기본 비공개 · 매칭권 열람 (증분)
-- ----------------------------------------------------------------------------
--  사용법
--   1) Supabase 대시보드 → 왼쪽 SQL Editor → New query
--   2) 이 파일 전체를 붙여넣고 RUN (한 번만 실행하면 됩니다)
--   3) 여러 번 다시 실행해도 안전합니다 (idempotent)
--
--  이 스크립트가 더하는 것
--   1) photo_unlocks — '내가 매칭권으로 연 사진' 기록표
--        (viewer_id, target_id) 한 쌍에 한 줄. 한 번 열면 계속 남습니다.
--   2) unlock_photo(target) — 매칭권 1장(990원)을 원자적으로 차감하고 열람을 기록
--        · 이미 연 상대는 다시 차감하지 않습니다 (already = true)
--        · 매칭권이 없으면 아무것도 바꾸지 않고 오류를 돌려줍니다
--        · 같은 순간 두 번 눌러도 한 번만 차감됩니다 (내 프로필 줄 잠금)
--   3) photo_view(target) — 열람 권한이 있을 때만 사진(data URL)을 돌려주는 함수
--        · 본인 · 운영자 · 열람권을 산 상대만 사진을 받습니다
--        · 그 밖에는 locked = true 만 돌려주고 사진은 보내지 않습니다
--   4) 데모 후보 8명 추가 (남 4 · 여 4, id ...0007 ~ ...0014)
--        이미 있으면 다시 넣지 않습니다 (on conflict do nothing)
--
--  ⚠ 이 파일은 기존 표·함수를 지우지 않습니다. 추가와 함수 생성만 합니다.
--  ⚠ 비밀키(service_role)는 쓰지 않습니다. 앱은 publishable 키로 함수만 호출합니다.
--  ⚠ 앱(index.html)은 이 SQL 을 실행하기 전에도 이 기기 기록(localStorage)으로
--     사진 열람 화면이 그대로 동작합니다. 실행하면 계정에 영구 기록되고
--     매칭권 차감이 서버에서 일어납니다.
-- ============================================================================


-- ============================================================================
-- 1. photo_unlocks — 사진 열람 기록
--    · viewer_id : 사진을 연 사람 (나)
--    · target_id : 사진이 열린 상대
--    · 한 번 들어간 줄은 앱에서 지우지 않습니다 (열람은 영구)
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
comment on column public.photo_unlocks.created_at is
  '사진을 연 시각 (매칭권 1장 차감 시점)';

-- ============================================================================
-- 2. unlock_photo() — 매칭권 1장을 차감하고 사진 열람을 기록
--    send_like() 와 같은 방식(내 프로필 줄을 잠그고 차감)으로 처리합니다.
--    이미 연 상대는 차감하지 않고 현재 잔액만 돌려줍니다.
-- ============================================================================
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

-- ============================================================================
-- 3. photo_view() — 열람 권한이 있을 때만 사진(data URL)을 돌려줍니다
--    · 본인 · 운영자(is_admin) · 열람권을 산 상대 → photos / captions
--    · 그 밖 → locked = true (사진은 한 장도 보내지 않습니다)
--    데모 프로필은 저장된 사진이 없어 photos 가 비어 있고, 앱이 예시 그림을 보여 줍니다.
-- ============================================================================
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

-- ============================================================================
-- 4. Row Level Security · 권한 — 내 열람 기록만 읽습니다 (쓰기는 함수만)
-- ============================================================================
alter table public.photo_unlocks enable row level security;

drop policy if exists photo_unlocks_select on public.photo_unlocks;
create policy photo_unlocks_select on public.photo_unlocks for select to authenticated
  using (viewer_id = auth.uid() or public.is_admin());

revoke all on public.photo_unlocks from anon, authenticated;
grant select (viewer_id, target_id, created_at) on public.photo_unlocks to authenticated;


-- ============================================================================
-- 5. 데모 후보 8명 추가 — 남 4명 · 여 4명 (화면 확인 · 테스트용)
--    id 는 ...0007 ~ ...0014 로 고정. 이미 있으면 건너뜁니다(on conflict do nothing).
--    · 직업 · 나이 · 지역 · MBTI · 키 · 취미 · 가치관 · 우선순위를 서로 다르게
--    · ...0007 은 긴 소개(상세 시트 스크롤 테스트용)
--    · 데모 사진은 저장하지 않습니다 — 사진 열람을 누르면 예시 그림이 보입니다.
-- ============================================================================
insert into public.profiles
  (id, email, nickname, gender, birth_year, age, job, company, company_domain, region, mbti, height,
   bio, match_tickets, points, verified, status, hidden_company, hobbies, values_list, photo_captions,
   dist_km, job_stable, nonsmoker, is_demo, priorities)
values
  ('a0000000-0000-4000-8000-000000000007', 'sejun@example.com', '오세준', 'male', 1988, 38,
   '제품 기획자', '모노랩스', 'monolabs.kr', '서울시 마포구', 'INTJ', 181,
   '앱 기획자로 일해요. 아침엔 한강을 따라 30분쯤 뛰고, 주말엔 전시를 보러 갑니다. 회의가 많은 주라도 저녁에는 책을 읽거나 와인 한 잔을 곁들이는 시간을 꼭 만들어요. 말수가 아주 많은 편은 아니지만, 좋아하는 사람에게는 하루에 있었던 일을 하나씩 나누는 쪽입니다. 서로의 자리를 존중하면서도 오래 이야기할 수 있는 사람이면 좋겠어요. 여행은 계획형이라 짐을 미리 싸 두는 편이고, 최근에는 교토와 타이베이를 다녀왔습니다.',
   3, 0, true, 'active', true,
   '["러닝","와인","전시"]', '["솔직함","꾸준함"]', '["회사 창가","한강 러닝","동네 와인바"]',
   4.2, true, true, true,
   '{"priorities":["personality","job","hobby"],"mbti":[],"ageMin":29,"ageMax":39,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000008', 'minjae@example.com', '권민재', 'male', 1986, 40,
   '세무사', '민재세무회계', 'mj-tax.co.kr', '서울시 강남구', 'ESTJ', 174,
   '작은 사업자들의 장부를 봐 줍니다. 숫자를 다루는 일이라 약속과 시간을 특히 중요하게 생각해요.',
   3, 0, true, 'active', true,
   '["골프","독서","와인"]', '["성실함","책임감"]', '["사무실 장부","주말 라운딩","와인 한 잔"]',
   12.6, true, true, true,
   '{"priorities":["job","personality","habit"],"mbti":[],"ageMin":30,"ageMax":42,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000009', 'seunghyun@example.com', '백승현', 'male', 1994, 32,
   '임상간호사', '푸른병원', 'pureun-hospital.kr', '서울시 송파구', 'ISFP', 178,
   '삼교대 근무라 주말이 꼭 주말은 아니지만, 쉬는 날엔 자전거를 타거나 집에서 파스타를 만듭니다. 조용한 다정함을 좋아해요.',
   3, 0, false, 'active', true,
   '["자전거","요리","영화"]', '["다정함","건강한 생활"]', '["퇴근길 한강","주말 파스타","영화 보는 밤"]',
   16.8, true, true, true,
   '{"priorities":["personality","age","area"],"mbti":[],"ageMin":28,"ageMax":38,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000010', 'jaeyun@example.com', '문재윤', 'male', 1996, 30,
   '백엔드 개발자', '코드베이스', 'codebase.dev', '경기도 성남시', 'INTP', 176,
   '서버 만드는 일을 해요. 주말엔 클라이밍과 보드게임, 평일 저녁엔 동네 카페에서 커피를 마십니다. 말보다 행동이 편한 사람이에요.',
   3, 0, false, 'active', true,
   '["클라이밍","보드게임","커피"]', '["자유로움","호기심"]', '["퇴근 후 클라이밍","보드게임 밤","동네 카페"]',
   21.4, true, false, true,
   '{"priorities":["hobby","personality","looks"],"mbti":[],"ageMin":27,"ageMax":36,"areas":["서울시 전체","경기도 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000011', 'soyoung@example.com', '한소영', 'female', 1992, 34,
   '브랜드 디자이너', '스튜디오 결', 'gyeol.studio', '서울시 마포구', 'INFJ', 168,
   '브랜드의 말투와 표정을 만드는 일을 해요. 주말엔 도자기를 빚거나 전시를 보러 가고, 밤에는 재즈를 틀어 둡니다. 섬세한 이야기를 오래 나눌 수 있는 사람이면 좋겠어요.',
   3, 0, true, 'active', true,
   '["전시","도자기","재즈"]', '["섬세함","존중"]', '["작업실 책상","도자기 굽는 날","재즈바"]',
   6.4, false, true, true,
   '{"priorities":["personality","hobby","job"],"mbti":[],"ageMin":30,"ageMax":41,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000012', 'sera@example.com', '김세라', 'female', 1989, 37,
   '약사', '햇살약국', 'hatsal-pharm.kr', '서울시 노원구', 'ISTJ', 162,
   '동네 약국을 지키고 있어요. 아침 일찍 문을 열고 저녁에 닫는 규칙적인 하루를 살아요. 주말엔 북한산 쪽으로 등산을 다니거나 집에서 빵을 굽습니다. 약속은 꼭 지키는 편이에요.',
   3, 0, true, 'active', true,
   '["등산","베이킹","독서"]', '["안정적인 생활","성실함"]', '["약국 창가","주말 등산","빵 굽는 오후"]',
   18.2, true, true, true,
   '{"priorities":["habit","job","personality"],"mbti":[],"ageMin":31,"ageMax":43,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000013', 'haneul@example.com', '정하늘', 'female', 1995, 31,
   '콘텐츠 에디터', '페이지원', 'pageone.kr', '서울시 종로구', 'ENFP', 165,
   '책 만드는 일을 해요. 서촌 골목을 걷다가 마음에 드는 카페를 찾으면 한참 앉아 있습니다. 필름카메라로 일상을 남기는 걸 좋아하고, 웃긴 이야기에 잘 넘어가는 편이에요.',
   3, 0, false, 'active', true,
   '["책","카페 투어","필름카메라"]', '["유머 코드","솔직함"]', '["서촌 골목","카페 창가","필름 스캔"]',
   9.6, false, true, true,
   '{"priorities":["personality","hobby","age"],"mbti":[],"ageMin":28,"ageMax":38,"areas":["서울시 전체"],"values":[]}'::jsonb),

  ('a0000000-0000-4000-8000-000000000014', 'sumin@example.com', '배수민', 'female', 1991, 35,
   'HR 매니저', '세림산업', 'serim.co.kr', '경기도 성남시', 'ESTJ', 167,
   '사람을 뽑고 함께 일하는 일을 해요. 계획 세우는 걸 좋아해서 여행도 일정표부터 만듭니다. 주말엔 요가를 하고 와인을 한 잔 마시며 한 주를 정리해요.',
   3, 0, true, 'active', true,
   '["요가","와인","여행"]', '["책임감","계획성"]', '["분당 사무실","주말 요가","여행 일정표"]',
   20.5, true, true, true,
   '{"priorities":["job","personality","style"],"mbti":[],"ageMin":30,"ageMax":40,"areas":["서울시 전체","경기도 전체"],"values":[]}'::jsonb)
on conflict (id) do nothing;

-- ============================================================================
-- 6. 확인용 (선택) — 실행하면 아래 표에 결과가 보입니다.
-- ============================================================================
select 'photo_unlocks' as table_name, count(*) as rows from public.photo_unlocks
union all select 'demo_profiles', count(*) from public.profiles where coalesce(is_demo, false) = true
union all select 'profiles', count(*) from public.profiles;
