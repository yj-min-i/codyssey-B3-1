#!/usr/bin/env bash
# =============================================================================
# EC2 안에서 실행하는 요구사항 점검 스크립트 — 출력 화면을 그대로 캡처해 증빙으로 사용
#   bash verify.sh
# =============================================================================
set -u
ok()   { printf "  [PASS] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; }

echo "== 인스턴스 정보 (IMDSv2) =="
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
md() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
echo "  instance-id : $(md instance-id)"
echo "  type        : $(md instance-type)"
echo "  AZ          : $(md placement/availability-zone)"
echo "  private IP  : $(md local-ipv4)"
echo "  public IP   : $(md public-ipv4)"

echo "== 1. 아웃바운드 인터넷 통신 (curl https://example.com) =="
code=$(curl -s -o /dev/null -m 10 -w "%{http_code}" https://example.com)
[[ "$code" == "200" ]] && ok "example.com → $code" || fail "example.com → $code"

echo "== 2. 웹 서버 실행 상태 =="
systemctl is-active --quiet nginx && ok "nginx active" || fail "nginx inactive"
if systemctl list-unit-files | grep -q '^fatelia.service'; then
  systemctl is-active --quiet fatelia && ok "fatelia(Node) active" || fail "fatelia(Node) inactive"
fi

echo "== 3. curl http://localhost → 200 =="
code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost)
[[ "$code" == "200" ]] && ok "localhost → $code" || fail "localhost → $code"

echo "== 4. curl http://localhost/health → 200 OK =="
body=$(curl -s -w " (HTTP %{http_code})" http://localhost/health)
[[ "$body" == "OK"*"(HTTP 200)" ]] && ok "/health → $body" || fail "/health → $body"

echo "== 5. 리스닝 포트 (외부 노출은 SG가 80/22만 허용) =="
sudo ss -tlnp | awk 'NR==1 || /:(22|80|3000) /'
