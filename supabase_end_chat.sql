-- ============================================================================
-- 990 인연 · 대화 종료(양쪽 공통) 마이그레이션
-- 이미 supabase_schema.sql 을 실행한 프로젝트에서 한 번만 실행하세요.
--   Supabase 대시보드 → SQL Editor → 아래 내용 전체 붙여넣기 → Run
-- 이 파일을 실행하지 않아도 앱은 동작합니다(이 기기에서만 대화가 종료됨).
-- ============================================================================

-- 1) 상태값에 'ended' 를 허용
alter table public.likes_matches drop constraint if exists likes_matches_status_check;
alter table public.likes_matches add constraint likes_matches_status_check
  check (status in ('liked','matched','passed','expired_refunded','ended'));

-- 2) 대화 종료 함수 — 둘 중 누가 호출해도 양쪽 모두 같은 방이 닫힙니다
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

grant execute on function public.end_chat(uuid) to authenticated;
