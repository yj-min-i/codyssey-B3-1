#!/usr/bin/env bash
# =============================================================================
# B3-1 EC2 초기 세팅 스크립트 (Ubuntu 24.04 LTS 기준)
#
# 사용법 (EC2에 SSH 접속한 상태에서):
#   sudo bash setup.sh node     # FATELIA가 Node.js 서버(Express 등)인 경우  ← 기본
#   sudo bash setup.sh static   # FATELIA가 빌드된 정적 파일(HTML/JS)만인 경우
#
# 하는 일
#   1) 패키지 업데이트, nginx·curl·git 설치
#   2) t3.micro(메모리 1GiB)에서 npm 설치가 죽지 않도록 1GiB 스왑 파일 생성
#   3) (node 모드) Node.js LTS 설치 + systemd 서비스 등록 준비
#   4) nginx 설정: 80 → (node) 127.0.0.1:3000 프록시 / (static) /var/www/fatelia
#      + GET /health → 200 "OK"
#   5) 아웃바운드 인터넷 통신·로컬 응답 확인
# =============================================================================
set -euo pipefail

MODE="${1:-node}"
NODE_MAJOR="${NODE_MAJOR:-22}"        # 로컬에서 `node -v`로 확인한 메이저 버전에 맞추세요
APP_PORT="${APP_PORT:-3000}"
APP_DIR="/opt/fatelia"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "sudo로 실행하세요: sudo bash setup.sh ${MODE}" >&2
  exit 1
fi
if [[ "$MODE" != "node" && "$MODE" != "static" ]]; then
  echo "모드는 node 또는 static 중 하나입니다." >&2
  exit 1
fi

echo "==[1/5] 패키지 설치 =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx curl git rsync ca-certificates

echo "==[2/5] 스왑 1GiB 생성 (이미 있으면 건너뜀) =="
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -h

echo "==[3/5] 앱 실행 환경 준비 (${MODE}) =="
mkdir -p "$APP_DIR"
if [[ "$MODE" == "node" ]]; then
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  fi
  node -v && npm -v
  # 앱 전용 비로그인 사용자 (root로 Node를 돌리지 않기 위해)
  id -u fatelia >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin fatelia
  sed "s/__APP_PORT__/${APP_PORT}/" "$SCRIPT_DIR/fatelia.service" > /etc/systemd/system/fatelia.service
  systemctl daemon-reload
  chown -R ubuntu:ubuntu "$APP_DIR"   # 배포(rsync)는 ubuntu 사용자로 받음
else
  mkdir -p /var/www/fatelia
  chown -R ubuntu:ubuntu /var/www/fatelia
  # 앱을 아직 안 올렸어도 접속 확인이 되도록 임시 페이지
  [[ -f /var/www/fatelia/index.html ]] || cat > /var/www/fatelia/index.html <<'EOF'
<!doctype html><meta charset="utf-8"><title>FATELIA</title>
<body style="background:#120d2b;color:#f3e9ff;font-family:sans-serif;text-align:center;padding-top:20vh">
<h1>FATELIA</h1><p>Hello Cloud — 곧 이곳에 운명의 문이 열립니다.</p></body>
EOF
fi

echo "==[4/5] nginx 설정 =="
if [[ "$MODE" == "node" ]]; then
  sed "s/__APP_PORT__/${APP_PORT}/" "$SCRIPT_DIR/nginx/fatelia-proxy.conf" > /etc/nginx/sites-available/fatelia
else
  cp "$SCRIPT_DIR/nginx/fatelia-static.conf" /etc/nginx/sites-available/fatelia
fi
ln -sf /etc/nginx/sites-available/fatelia /etc/nginx/sites-enabled/fatelia
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl restart nginx   # reload는 적용 전 응답이 섞일 수 있어 restart 사용
sleep 1

echo "==[5/5] 확인 =="
echo "-- 아웃바운드(인터넷) 통신: curl https://example.com"
curl -sS -o /dev/null -w "example.com HTTP %{http_code}\n" https://example.com
echo "-- 로컬 헬스체크: curl http://localhost/health"
curl -sS -i http://localhost/health | head -n 1
echo
echo "완료. node 모드라면 다음 단계: 로컬 Mac에서 deploy-from-mac.sh 실행 → 앱 업로드"
