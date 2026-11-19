# 구축 절차 (Runbook)

> 모든 리소스는 **서울 리전(ap-northeast-2)** 에 만든다. 콘솔 오른쪽 위 리전 표시를 매 단계 확인한다.
> 리소스 이름은 모두 `b3-1-` 접두사를 붙이고 태그 `Project=b3-1`을 달아 정리할 때 빠짐없이 찾는다.
> 각 단계의 📸 표시는 스크린샷을 `docs/screenshots/`에 저장할 지점이다.

---

## 0. IAM 사용자 준비 (최소권한)

계정은 **Sign up for AWS (advanced)** 경로 + 이메일 + **Free 플랜**으로 만든다(Google·GitHub 간편 가입은 시드니 리전으로 고정되어 불가).
새 계정에서는 첫 IAM 사용자를 루트로만 만들 수 있으므로, **루트는 MFA 설정과 아래 1~3에만** 쓰고 로그아웃한다. 이후 모든 작업은 `b3-1-operator`로 한다.

0. 루트로 로그인 → 계정 이름 → 보안 자격 증명 → MFA 디바이스 할당(인증 앱)
1. IAM → 정책 → **정책 생성** → JSON 탭에 `iam/b3-1-least-privilege-policy.json` 붙여넣기 → 이름 `B3-1-LeastPrivilege`
2. IAM → 사용자 → **사용자 생성** → 이름 `b3-1-operator` → "AWS Management Console 액세스 제공" 체크
3. 권한: **직접 정책 연결** → `B3-1-LeastPrivilege` 하나만 선택 (AdministratorAccess 선택 금지)
4. 로그아웃 후 콘솔 로그인 URL(`https://<계정ID>.signin.aws.amazon.com/console`)로 `b3-1-operator` 로그인 📸 `iam-user-policy.png` (사용자 → 권한 탭. 1~3을 한 사용자 화면에서 찍어 두면 편함)

| 정책 Statement | 왜 필요한가 |
|---|---|
| `ec2:Describe*` (서울 한정) | 콘솔 화면 조회. VPC·서브넷·SG API도 `ec2:` 네임스페이스에 속함 |
| VPC/Subnet/IGW/RouteTable/SG 생성·연결·삭제 | 네트워크 구축 **과 정리** (삭제 권한이 없으면 과금 정리를 못 함) |
| RunInstances·TerminateInstances·KeyPair·EIP·Volume 삭제 | 인스턴스 수명주기와 정리 |
| **Deny**: t2.micro/t3.micro 이외 타입 | 실수로 큰 인스턴스를 띄워 과금되는 것 차단 |
| `sts:DecodeAuthorizationMessage` | 권한 오류 시 인코딩된 거부 메시지를 해독해 원인 분석 (트러블슈팅용) |
| 본인 비밀번호 변경만 | 첫 로그인 시 비밀번호 변경 |
| **없는 것** | S3, RDS, IAM 관리, Billing 등 실습과 무관한 모든 권한 |

> ⚠️ 이 정책은 AWS 정책 검사기로 직접 검증하지 못했습니다. 붙여넣을 때 IAM 콘솔이 경고를 보여주면 그 내용을 그대로 기록하세요(트러블슈팅 소재가 됩니다). 콘솔 화면 일부(예: 모니터링 탭, Compute Optimizer 권고)가 "권한 없음"으로 뜨는 것은 정상이며 미션 범위 밖입니다.

---

## 1. VPC 만들기 (수동으로 하나씩 — 각 구성요소 역할을 설명하기 위해)

VPC 콘솔 → 상단 리전 = 서울

| 순서 | 메뉴 | 설정 |
|---|---|---|
| 1 | VPC → VPC 생성 → **VPC만** | 이름 `b3-1-vpc`, IPv4 CIDR `10.0.0.0/16`, IPv6 없음 |
| 2 | 서브넷 → 서브넷 생성 | VPC `b3-1-vpc`, 이름 `b3-1-public-subnet`, AZ `ap-northeast-2a`, CIDR `10.0.1.0/24` |
| 3 | 서브넷 선택 → 작업 → **서브넷 설정 편집** | **퍼블릭 IPv4 주소 자동 할당 활성화** 체크 |
| 4 | 인터넷 게이트웨이 → 생성 | 이름 `b3-1-igw` → 작업 → **VPC에 연결** → `b3-1-vpc` |
| 5 | 라우팅 테이블 → 생성 | 이름 `b3-1-public-rt`, VPC `b3-1-vpc` |
| 6 | `b3-1-public-rt` → 라우팅 편집 → 라우팅 추가 | 대상 `0.0.0.0/0` → 타겟 **인터넷 게이트웨이** `b3-1-igw` |
| 7 | `b3-1-public-rt` → 서브넷 연결 편집 | `b3-1-public-subnet` 체크 |

📸 `route-table.png` — 라우팅 탭에 `10.0.0.0/16 local` + `0.0.0.0/0 igw-…` 두 줄이 보이게

**왜 이 순서인가:** 서브넷은 "어느 라우팅 테이블에 연결됐는가"로 퍼블릭/프라이빗이 갈린다. IGW가 VPC에 붙어 있어도 서브넷의 라우팅 테이블에 `0.0.0.0/0 → igw`가 없으면 그 서브넷은 인터넷과 통신할 수 없다.

---

## 2. Security Group

EC2 콘솔 → 보안 그룹 → 생성 → 이름 `b3-1-web-sg`, VPC `b3-1-vpc`

| 방향 | 유형 | 포트 | 소스 | 설명 |
|---|---|---|---|---|
| 인바운드 | HTTP | 80 | `0.0.0.0/0` | public web |
| 인바운드 | SSH | 22 | **내 IP** (콘솔 드롭다운 → `x.x.x.x/32`) | admin ssh only |
| 아웃바운드 | 모든 트래픽 | 전체 | `0.0.0.0/0` (기본값 유지) | apt, npm, AI API 호출 |

- **만들지 않는 것:** 0.0.0.0/0 전체 포트, 3000번(Node) 포트. Node는 nginx 뒤에 숨긴다.
- 📸 `security-group.png` — 인바운드 규칙 탭

> 🔁 **트러블슈팅 사례 1을 직접 재현하려면:** 처음엔 HTTP(80) 규칙을 **빼고** 만든 뒤 4단계까지 진행 → 외부 접속 실패를 기록 → 그때 80 규칙을 추가한다. (`docs/troubleshooting.md` 사례 1)

---

## 3. EC2 인스턴스

EC2 → 인스턴스 시작

| 항목 | 값 |
|---|---|
| 이름 | `b3-1-web` (태그 `Project=b3-1` 추가) |
| AMI | **Ubuntu Server 24.04 LTS** (프리 티어 사용 가능 표시 확인) |
| 인스턴스 유형 | `t3.micro` (또는 `t2.micro`) — 프리 티어 표시 확인 |
| 키 페어 | 새로 생성 `b3-1-key`, RSA, `.pem` → **다운로드는 1회뿐**. `~/.ssh/`로 옮기고 `chmod 400` |
| 네트워크 설정 → 편집 | VPC `b3-1-vpc` / 서브넷 `b3-1-public-subnet` / 퍼블릭 IP 자동 할당 **활성화** / 기존 보안 그룹 `b3-1-web-sg` |
| 스토리지 | 8 GiB gp3 (기본값, 증설 금지) |

시작 후 퍼블릭 IPv4 주소를 메모한다. 📸 `ec2-instance.png` (세부 정보: 퍼블릭 IP, 서브넷, VPC, 보안 그룹이 보이게)

> Elastic IP는 **만들지 않는 것을 권장**한다. 이 미션에 필요 없고, 할당만 해두고 잊으면 계속 과금된다. 인스턴스를 중지·시작하면 퍼블릭 IP가 바뀔 수 있다는 점만 기억한다(README의 IP는 최종 제출 시점 기준으로 갱신).

---

## 4. 서버 세팅 (Mac 터미널)

```bash
# 키 권한 (안 하면 "UNPROTECTED PRIVATE KEY FILE" 오류)
mv ~/Downloads/b3-1-key.pem ~/.ssh/ && chmod 400 ~/.ssh/b3-1-key.pem

# 이 저장소의 server/ 폴더를 EC2로 복사
cd codyssey-B3-1
scp -i ~/.ssh/b3-1-key.pem -r server ubuntu@<퍼블릭IP>:~/

# SSH 접속 📸 ssh-login.png
ssh -i ~/.ssh/b3-1-key.pem ubuntu@<퍼블릭IP>
```

EC2 안에서:

```bash
cd ~/server
# FATELIA가 Node 서버면 node, 빌드된 정적 파일뿐이면 static
sudo bash setup.sh node
```

> **FATELIA가 어느 쪽인지 판단법:** Render에서 "Web Service"로 배포했고 `package.json`에 `start` 스크립트가 있으면 `node`. "Static Site"였다면 `static`.
> Node 버전은 로컬 `node -v` 메이저 버전에 맞춰 `sudo NODE_MAJOR=22 bash setup.sh node`처럼 지정한다.

### 4-1. API 키 등 환경변수 (node 모드만)

```bash
sudo nano /opt/fatelia/.env      # Render 환경변수에 넣었던 값들을 그대로
sudo chown ubuntu:fatelia /opt/fatelia/.env && sudo chmod 640 /opt/fatelia/.env
```

- `.env`는 **절대 GitHub(제출 저장소 포함)에 올리지 않는다.** 이 저장소의 `.gitignore`가 막아둔다.
- 퍼블릭 IP는 누구나 접속할 수 있으므로, FATELIA의 이용자별·전체 AI 사용 한도가 켜져 있는지 확인한다. 불안하면 이 미션 기간에는 AI 기능 키를 넣지 않아도 된다(웹 접속 증빙에는 영향 없음).

### 4-2. FATELIA 업로드 (Mac 새 터미널)

```bash
bash server/deploy-from-mac.sh <퍼블릭IP> ~/.ssh/b3-1-key.pem ~/경로/fatelia node
# 정적 사이트라면: ... static dist   (빌드 폴더명이 build면 build)
```

GitHub 비공개 저장소를 서버에서 clone하지 않고 rsync로 보내는 이유: 서버에 GitHub 토큰을 두지 않기 위해서(최소권한).

---

## 5. 검증

EC2 안에서:

```bash
bash ~/server/verify.sh       # 📸 verify.png  (PASS 목록 전체가 보이게)
curl -I http://localhost      # 📸 localhost-200.png
curl https://example.com -o /dev/null -w "%{http_code}\n"   # 아웃바운드 200
```

Mac(외부)에서:

```bash
curl -i http://<퍼블릭IP>/health     # → HTTP/1.1 200 OK + OK (사례 1의 ts1-after-200.png와 같은 내용이라 별도 캡처 불필요)
```

브라우저에서 `http://<퍼블릭IP>` → FATELIA 첫 화면 📸 `external-browser.png` (주소창의 IP가 보이게)

> 브라우저가 자동으로 `https://`로 바꿔 접속 실패할 수 있다. 주소창에 `http://`를 직접 입력한다. (보너스 1에서 HTTPS 적용 시 해결)

---

## 6. 정리

`docs/cleanup-checklist.md` 순서대로 진행한다. 순서가 틀리면 "의존성 때문에 삭제 불가" 오류가 난다.
