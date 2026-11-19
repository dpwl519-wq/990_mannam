#!/usr/bin/env bash
# 990 인연 프로토타입 → GitHub Pages 배포 (재개용 스크립트)
# 전제: 사용자가 github.com 에서 공개 저장소 dpwl519-wq/990-yeonin-mvp 를 이미 만들었을 것.
set -u
OWNER=dpwl519-wq
REPO=${1:-990-yeonin-mvp}
cd "$(dirname "$0")" || exit 1

echo "== 1. 원격 확인 =="
gh api "repos/$OWNER/$REPO" --jq '.full_name, .private' || { echo "!! 저장소가 없습니다: $OWNER/$REPO"; exit 2; }

echo "== 2. push =="
git remote remove origin 2>/dev/null
git remote add origin "https://github.com/$OWNER/$REPO.git"
git push -u origin main || { echo "!! push 실패 (권한 확인 필요)"; exit 3; }

echo "== 3. Pages 활성화 시도 =="
gh api "repos/$OWNER/$REPO/pages" --jq '.html_url' 2>/dev/null \
  || gh api -X POST "repos/$OWNER/$REPO/pages" -f "source[branch]=main" -f "source[path]=/" --jq '.html_url' 2>&1

echo "== 4. 상태 확인 =="
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://$OWNER.github.io/$REPO/")
  echo "  [$i] https://$OWNER.github.io/$REPO/ -> $code"
  [ "$code" = "200" ] && { echo "== 배포 완료 =="; exit 0; }
  sleep 6
done
echo "!! 아직 200 아님 (Pages 빌드 대기 또는 비활성)"
exit 4
