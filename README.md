# 990 인연 · 직장인 소개팅 (Supabase 연동판 v1.0)

`index.html` 한 파일로 도는 모바일 웹 앱입니다. 데이터는 **Supabase**(인증·프로필·호감·매칭·대화·인증심사·충전·신고)에 저장됩니다.
화면 스타일은 v0.5의 **조용한 파스텔 에디토리얼**(아이보리 종이 · 샌드 · 세이지 · 살구색 악센트 · 얇은 선 그림, Gowun Batang)을 그대로 유지했습니다.

- 배포: https://dpwl519-wq.github.io/990_mannam/
- Supabase 프로젝트: `pyelrhjhsvltayheqgbj`

## 1. 처음 한 번만 — Supabase 준비

1. **스키마 실행** — Supabase 대시보드 → SQL Editor → New query →
   `supabase_schema.sql` **전체**를 붙여넣고 **RUN** (여러 번 실행해도 안전합니다).
   테이블 9개 + 운영 설정, RLS 정책, 서버 함수, 데모 프로필 6명이 만들어집니다.
2. **이메일 인증 끄기(권장)** — Authentication → Sign In / Providers → Email →
   *Confirm email* **OFF**. 끄면 가입 즉시 로그인됩니다.
   켜 둔 경우: Authentication → URL Configuration → **Site URL** 을
   `https://dpwl519-wq.github.io/990_mannam/` 로 바꾸고, 가입 후 메일의 인증 링크를 눌러야 로그인됩니다.
3. **운영자 PIN** — 기본값 `990418` (`admin_config` 테이블). 바꾸려면:
   ```sql
   update public.admin_config set admin_pin = '내PIN' where id = 1;
   ```
4. **입금 계좌** — 앱 → 운영자 → PIN 입력 → `입금 계좌 설정` 탭에서 저장하면
   사용자 충전 화면에 바로 표시됩니다.

## 2. 사용 흐름

1. 앱에서 회원가입(이메일·비밀번호·닉네임·성별·출생연도) → 매칭권 3장 지급
2. 첫 로그인 때 **데모 인연**이 자동으로 채워집니다
   (받은 호감 2 · 매칭된 대화 1 · 심사 대기 인증 2 · 충전 요청 1 · 신고 1).
   실제 가입자가 늘면 프로필 → `데모 인연 함께 보기`를 꺼 두세요.
3. 운영자 콘솔(PIN)에서 인증 승인 · 입금 확인(매칭권 지급) · 신고 정지를 처리합니다.

## 3. 구조

| 파일 | 역할 |
| --- | --- |
| `index.html` | 화면 + 앱 로직 (Supabase JS v2 CDN, publishable 키만 사용) |
| `supabase_schema.sql` | 테이블 · RLS · 서버 함수 · 데모 시드 (idempotent) |

- 매칭권 차감·48시간 자동 반환·매칭 성사·후기 300P·충전 승인은 모두 **서버 함수**(`send_like`, `expire_likes`, `submit_review`, `admin_review_charge` …)에서 원자적으로 처리됩니다.
- 앱에서 직접 바꿀 수 있는 프로필 열은 열 단위 권한으로 제한했습니다
  (`match_tickets`, `points`, `verified`, `is_admin` 등은 앱에서 위조 불가).
- `email`, 차단 목록, 관리자 여부는 다른 사용자에게 노출되지 않습니다.
- 새 메시지·호감은 7초 주기로 다시 읽어 옵니다.

## 4. 디자인 노트 (v0.5 유지)

- **색**: 종이 `#FAF6F0` · 샌드 `#E6D9C8` · 세이지 `#C9D6C9` · 살구 `#EABFA8`/`#D99B84` · 잉크 `#2E2825`
- **일러스트**: 사진이 없는 프로필은 얇은 선 드로잉 + 물감 번짐 SVG(`plateSVG`)로 채웁니다. 사진을 올린 프로필은 실제 사진이 카드에 표시됩니다.
- **바꾸는 법**: 사진 모티프는 `PROFILE_ART`, 아바타는 `avatarSVG`, 궁합은 `compatibility()`, 우선순위는 `matchesPriority()`.

## 5. 참고

- 결제는 **계좌이체/카카오페이 입금 확인형**입니다(자동 결제 아님). 회원이 입금자명을 남기면 운영자가 확인 후 매칭권을 지급합니다.
- 회사 메일 인증은 아직 화면 인증번호 방식이며 실제 메일 발송은 연결되어 있지 않습니다. 서류 인증은 운영자 심사로 처리됩니다.
- 전화번호 차단은 해시 값만 저장하고 원본은 남기지 않습니다.
