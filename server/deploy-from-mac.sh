#!/usr/bin/env bash
# =============================================================================
# 로컬 Mac에 있는 FATELIA 프로젝트를 EC2로 올리고 실행하는 스크립트
# (GitHub 비공개 저장소 토큰을 서버에 두지 않기 위해 SSH(rsync)로 직접 전송)
#
# 사용법:
#   bash deploy-from-mac.sh <퍼블릭IP> <키페어.pem 경로> <FATELIA 폴더 경로> [node|static] [정적 빌드 폴더명]
# 예:
#   bash deploy-from-mac.sh 3.35.xx.xx ~/.ssh/b3-1-key.pem ~/Projects/fatelia node
#   bash deploy-from-mac.sh 3.35.xx.xx ~/.ssh/b3-1-key.pem ~/Projects/fatelia static dist
# =============================================================================
set -euo pipefail

IP="${1:?퍼블릭 IP를 넣으세요}"
KEY="${2:?.pem 키 경로를 넣으세요}"
SRC="${3:?FATELIA 프로젝트 폴더 경로를 넣으세요}"
MODE="${4:-node}"
BUILD_DIR="${5:-dist}"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new)
REMOTE="ubuntu@${IP}"

# .env(API 키), node_modules, .git 은 절대 올리지 않음
EXCLUDES=(--exclude node_modules --exclude .git --exclude '.env' --exclude '.env.*' --exclude '.DS_Store')

if [[ "$MODE" == "node" ]]; then
  echo "== 소스 업로드 → /opt/fatelia =="
  # --delete는 제외(exclude)된 파일은 지우지 않으므로 서버의 .env는 보존됨
  rsync -az --delete "${EXCLUDES[@]}" \
    -e "ssh ${SSH_OPTS[*]}" "${SRC%/}/" "${REMOTE}:/opt/fatelia/"

  echo "== 의존성 설치·빌드·서비스 재시작 =="
  ssh "${SSH_OPTS[@]}" "$REMOTE" bash -s <<'EOF'
set -euo pipefail
cd /opt/fatelia
if [ -f package-lock.json ]; then npm ci; else npm install; fi
# build 스크립트가 있을 때만 실행
if node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)"; then npm run build; fi
# 소유자 ubuntu(배포용) / 그룹 fatelia(실행용, 읽기 전용) — 앱 프로세스는 코드를 수정할 수 없음
sudo chown -R ubuntu:fatelia /opt/fatelia
if [ -f .env ]; then sudo chmod 640 .env; fi
sudo systemctl enable fatelia >/dev/null 2>&1 || true
sudo systemctl restart fatelia
sleep 3
sudo systemctl --no-pager --lines=5 status fatelia || true
echo "-- curl http://localhost (nginx 경유)"
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost
EOF
else
  echo "== 정적 빌드 결과물 업로드: ${SRC%/}/${BUILD_DIR} → /var/www/fatelia =="
  rsync -az --delete -e "ssh ${SSH_OPTS[*]}" "${SRC%/}/${BUILD_DIR}/" "${REMOTE}:/var/www/fatelia/"
  ssh "${SSH_OPTS[@]}" "$REMOTE" 'curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost'
fi

echo
echo "외부 확인: 브라우저에서 http://${IP}  또는  curl -i http://${IP}/health"
