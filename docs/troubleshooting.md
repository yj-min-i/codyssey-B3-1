# 트러블슈팅 보고서

> **작성 원칙:** 아래 `▶ 실제 기록` 칸은 **본인이 직접 실행한 명령과 실제 출력**으로 채운다. 예상 출력은 참고용이며, 실제와 다르면 실제를 적고 가설을 고친다. 오류가 다르게 났다면 그 오류로 사례를 바꿔 써도 된다.
> 사례 1·2는 runbook에서 **의도적으로 재현**한 오류이고, 사례 3·4는 구축 중 **실제로 예상치 못하게 겪은** 오류다.

---

## 사례 1. 외부에서 웹 접속이 안 됨 (인스턴스 안에서는 정상)

| 항목 | 내용 |
|---|---|
| **증상** | EC2 안에서 `curl -I http://localhost` → `200 OK`. 그런데 Mac에서 `curl -i -m 10 http://13.125.69.184/health` 는 응답 없이 10초 뒤 타임아웃. |
| **원인 가설** | 요청이 서버까지 오는 경로 중 하나가 막힘. 후보: ① 서브넷 라우팅에 IGW 경로 없음 ② 인스턴스에 퍼블릭 IP 없음 ③ SG 인바운드 80 미허용 ④ nginx가 80에서 안 들음. **타임아웃(무응답)** 은 패킷이 버려졌다는 뜻이라 ③ 가능성이 가장 큼. (서버까지 갔는데 포트에 프로세스가 없으면 보통 즉시 `Connection refused`) |
| **검증** | ④ 배제: 서버에서 `sudo ss -tlnp \| grep :80` → nginx LISTEN 확인. ② 배제: 콘솔 인스턴스 세부 정보에 퍼블릭 IPv4 존재. ① 배제: 같은 IP로 SSH(22)는 접속됨 → 라우팅·IGW·퍼블릭 IP는 정상. 남은 차이는 포트뿐 → SG 인바운드 규칙 확인 결과 **22만 있고 80 없음**. |
| **조치** | `b3-1-web-sg` 인바운드에 `HTTP / TCP 80 / 0.0.0.0/0` 추가. (SG는 상태 저장형이라 응답용 아웃바운드 규칙은 따로 필요 없음) |
| **결과** | 재실행 `curl -i http://<퍼블릭IP>/health` → `HTTP/1.1 200 OK` / `OK`. 브라우저 FATELIA 화면 표시. |
| **재발 방지** | ① 배포 전 체크리스트에 "SG 인바운드 80(0.0.0.0/0)·22(내 IP) 확인" 추가 ② "안에서는 되는데 밖에서 안 됨" → 바깥쪽 계층(SG → 라우팅 → 퍼블릭 IP)부터 확인 ③ 타임아웃 vs refused 를 먼저 구분 |

▶ 실제 기록 (붙여넣기)

```text
# Mac
$ curl -i -m 10 http://13.125.69.184/health
curl: (28) Connection timed out after 10006 milliseconds

# EC2
$ curl -I http://localhost
$ sudo ss -tlnp | grep :80
HTTP/1.1 200 OK
Server: nginx
Date: Thu, 19 Nov 2026 17:45:17 GMT
Content-Type: text/html; charset=utf-8
Content-Length: 1224
…(보안 헤더 생략)

LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=2895,fd=5),("nginx",pid=2894,fd=5),("nginx",pid=1818,fd=5))

# 조치 후 Mac
$ curl -i -m 10 http://13.125.69.184/health
HTTP/1.1 200 OK
Server: nginx
Date: Thu, 19 Nov 2026 18:06:23 GMT
Content-Type: text/plain
Content-Length: 3
Connection: keep-alive

OK
```

📸 증빙: `ts1-before-timeout.png`, `ts1-server-local-ok.png`, `ts1-sg-before.png`, `ts1-sg-after.png`, `ts1-after-200.png`

---

## 사례 2. IAM 최소권한 때문에 작업이 거부됨 (의도적 재현)

`b3-1-operator`로 인스턴스 유형을 `t3.small`로 골라 시작을 시도했다.

| 항목 | 내용 |
|---|---|
| **증상** | 인스턴스 시작 실패. 콘솔에 권한이 없다는 오류와 인코딩된 거부 메시지가 표시됨 (아래 실제 기록). |
| **원인 가설** | IAM 정책의 `DenyNonFreeTierInstanceTypes` 문(t2.micro·t3.micro 외 인스턴스 시작을 명시적으로 거부)에 걸림. 즉 **설계대로 막힌 것**이지 장애가 아님. |
| **검증** | 오류 메시지가 직접 원인을 가리킴: `ec2:RunInstances`가 **explicit deny**로 거부됐고, 거부한 정책이 `B3-1-LeastPrivilege`라고 명시됨. 정책 JSON에서 `ec2:InstanceType`이 t2.micro·t3.micro가 아니면 `RunInstances`를 Deny하는 문(`DenyNonFreeTierInstanceTypes`)을 확인. 같은 설정에서 유형만 `t3.micro`로 바꾸면 정상 시작됨. |
| **조치** | 권한을 넓히지 **않음**. 인스턴스 유형을 `t3.micro`로 바꿔 다시 시작. |
| **결과** | `t3.micro` 인스턴스 `b3-1-web` 정상 시작(`ec2-instance.png`). 최소권한 정책이 큰 인스턴스로 인한 과금 사고를 실제로 막는 것을 확인. |
| **재발 방지** | 권한 오류가 나면 "권한 추가"부터 하지 말고 어떤 정책 문이 막았는지 먼저 확인. 정말 필요한 권한이면 그 액션 하나만 추가하고 이유를 기록. |

▶ 실제 기록

```text
인스턴스 시작 실패
You are not authorized to perform this operation.
User: arn:aws:iam::7938****0172:user/b3-1-operator is not authorized to perform:
ec2:RunInstances on resource: arn:aws:ec2:ap-northeast-2:7938****0172:instance/*
with an explicit deny in an identity-based policy:
arn:aws:iam::7938****0172:policy/B3-1-LeastPrivilege.
Encoded authorization failure message: BbZQAqYMUDILgjl5UGYhLeWpMKBW…(이하 생략)
```

📸 증빙: `ts2-denied.png`, `iam-user-policy.png`, `ec2-instance.png`

---

## 사례 3. IAM 사용자 콘솔 로그인 실패 (Authentication failed)

발생: 2026-11-20 01:27 (KST), IAM 사용자 `b3-1-operator` 생성 직후 첫 로그인

| 항목 | 내용 |
|---|---|
| **증상** | IAM 사용자 로그인 화면(IAM user sign in)에서 `b3-1-operator`와 비밀번호를 입력하고 Sign in → **"Authentication failed — 인증 정보가 정확하지 않습니다. 다시 시도하십시오."** |
| **원인 가설** | ① 비밀번호 오타 ② 사용자 이름 오타 ③ 계정 ID 입력 오류 ④ 루트 로그인 화면에 입력 ⑤ 사용자에게 콘솔 액세스가 꺼져 있음 |
| **검증** | ④ 배제: 화면 제목이 "IAM user sign in"이고 IAM username 칸이 있음. ② 배제: username 칸에 `b3-1-operator` 정확히 입력됨. ③ 확인: **Account ID or alias 칸에 `https://7938****0172.signin.aws.amazon...` 처럼 로그인 URL 전체가 들어가 있었음.** 이 칸은 12자리 계정 ID(또는 별칭)만 받는다. |
| **조치** | Account ID 칸을 지우고 **숫자 12자리만** 입력, 비밀번호 다시 입력 후 Sign in. |
| **결과** | 로그인 성공. 콘솔 오른쪽 위에 `b3-1-operator` 표시 확인. |
| **재발 방지** | ① 로그인 URL은 **브라우저 주소창**에 붙여넣는 용도(그러면 계정 ID가 자동 입력됨), 입력 칸에는 ID만 ② "Remember this account" 체크 ③ 인증 실패 시 비밀번호보다 **각 입력 칸의 형식**부터 확인 |

> 계정 ID는 일부(****)를 가려서 기록했다.

📸 증빙: `ts3-login-failed.png` (Authentication failed 화면 — 입력 칸에 URL이 들어간 상태)

---

## 사례 4. 세팅 직후 `/health`가 404 Not Found

발생: 2026-11-19 17:30 UTC (2026-11-20 02:30 KST), EC2에서 `sudo bash ~/server/setup.sh node` 실행 중 마지막 확인 단계

| 항목 | 내용 |
|---|---|
| **증상** | 세팅 스크립트의 nginx 설정 검사는 통과(`syntax is ok`, `test is successful`)했는데, 바로 이어진 확인에서 `curl http://localhost/health` → **`HTTP/1.1 404 Not Found`**. |
| **원인 가설** | ① 새 설정 파일(`fatelia`)이 `sites-enabled`에 연결되지 않음 ② 설정에 `/health` 블록이 없음 ③ 설정은 맞지만 **`systemctl reload` 직후 새 설정이 적용되기 전에** Ubuntu 기본 사이트(`/health` 없음)가 응답함 |
| **검증** | 약 2분 뒤 다시 확인. ① 배제: `ls -l /etc/nginx/sites-enabled/` → `fatelia -> /etc/nginx/sites-available/fatelia` 하나만 있음(default 제거됨). ② 배제: `sudo nginx -T \| grep -n health` → `201: location = /health {` 존재. 같은 요청을 다시 보내니 `200 OK` → 설정은 정상이고 **적용 시점과 확인 요청이 겹친 타이밍 문제(③)**로 판단. |
| **조치** | 서버에서는 추가 조치 없이 재요청으로 정상 확인. 스크립트는 `systemctl reload nginx` → `systemctl restart nginx` + 1초 대기로 수정. |
| **결과** | `curl -i http://localhost/health` → `HTTP/1.1 200 OK` / `OK`. |
| **재발 방지** | ① 설정 변경 직후 검증은 restart 후 잠깐 기다렸다가 수행 ② 404가 나면 바로 설정을 의심하지 말고 `sites-enabled` 연결과 `nginx -T`로 **실제 로드된 설정**부터 확인 |

▶ 실제 기록

```text
# setup.sh 출력 마지막 부분 (17:30 UTC)
==[4/5] nginx 설정 ==
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
==[5/5] 확인 ==
-- 아웃바운드(인터넷) 통신: curl https://example.com
example.com HTTP 200
-- 로컬 헬스체크: curl http://localhost/health
HTTP/1.1 404 Not Found

# 재확인 (17:32 UTC)
ubuntu@ip-10-0-1-179:~$ curl -i http://localhost/health
HTTP/1.1 200 OK
Server: nginx
Date: Thu, 19 Nov 2026 17:32:00 GMT
Content-Type: text/plain
Content-Length: 3
Connection: keep-alive

OK
ubuntu@ip-10-0-1-179:~$ ls -l /etc/nginx/sites-enabled/
total 0
lrwxrwxrwx 1 root root 34 Nov 19 17:30 fatelia -> /etc/nginx/sites-available/fatelia
ubuntu@ip-10-0-1-179:~$ sudo nginx -T 2>/dev/null | grep -n "health"
201:    location = /health {
```

---

## 참고: 자주 나는 오류와 확인 위치

| 증상 | 먼저 볼 곳 |
|---|---|
| `Permission denied (publickey)` | 사용자명(Ubuntu는 `ubuntu`), `-i` 키 경로, 키페어 이름 일치 |
| `UNPROTECTED PRIVATE KEY FILE` | `chmod 400 키.pem` |
| SSH 타임아웃 (어제는 됐음) | 내 공인 IP가 바뀜(학교↔집) → SG 22 소스를 "내 IP"로 다시 저장 |
| 브라우저 `502 Bad Gateway` | nginx는 살아 있고 Node가 죽음 → `sudo journalctl -u fatelia -n 50` |
| `npm ci` 중 `Killed` | 메모리 부족 → `free -h`로 스왑 확인 (setup.sh가 1GiB 생성) |
| Node 로그 `EACCES` | 앱이 파일을 쓰려 함 → 쓰는 폴더만 `sudo chown fatelia` |
| `curl https://example.com` 실패 | 라우팅 테이블 `0.0.0.0/0 → igw`, 서브넷-라우팅테이블 연결, SG 아웃바운드 |
