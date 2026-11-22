# 리소스 정리 체크리스트

> **현재 상태:** ✅ 정리 완료 (2026-11-22 18:26 KST, `b3-1-operator`로 서울 리전에서 수행)
> **언제 정리했나:** 동작 증빙 스크린샷(README 항목 1)을 모두 남긴 **뒤**, 동료평가 전에 정리했다. 지운 리소스는 되살릴 수 없다.
> **리전:** 서울(ap-northeast-2)에서 확인. 다른 리전에 실수로 만든 것은 없는지 EC2 대시보드 "글로벌 보기"도 한 번 확인.
> **순서가 중요한 이유:** 상위 리소스는 하위 리소스가 붙어 있으면 삭제가 거부된다(예: 인스턴스의 네트워크 인터페이스가 남아 있으면 서브넷·SG 삭제 불가, IGW가 붙어 있으면 VPC 삭제 불가).

| # | 리소스 | 작업 | 확인 기준 | 완료 | 근거(스크린샷/메모) |
|---|---|---|---|---|---|
| 1 | EC2 인스턴스 `b3-1-web` | 인스턴스 상태 → **종료(Terminate)** | 상태 `종료됨(Terminated)` | ☑ | `cleanup-ec2.png` |
| 2 | EBS 볼륨 | 볼륨 목록 확인 (루트 볼륨은 "종료 시 삭제"로 자동 삭제) | 볼륨 목록 0개 | ☑ | `cleanup-ebs.png` |
| 3 | Elastic IP | 처음부터 할당하지 않음 | 탄력적 IP 목록 0개 | ☑ (미생성) | `cleanup-eip.png` |
| 4 | 키 페어 `b3-1-key` | 삭제 + Mac의 `~/.ssh/b3-1-key.pem` 삭제 (과금 항목은 아님) | 키 페어 목록에 없음 | ☑ | |
| 5 | 보안 그룹 `b3-1-web-sg` | 삭제 (인스턴스 종료 후) | 목록에 기본 SG만 남음 | ☑ | |
| 6 | Internet Gateway `b3-1-igw` | **VPC에서 분리(Detach)** → 삭제 | 목록에 없음 (기본 VPC용 IGW만 남음) | ☑ | `cleanup-igw.png` |
| 7 | 서브넷·라우팅 테이블 | `b3-1-public-subnet` 삭제 → `b3-1-public-rt` 삭제 | 목록에 없음 | ☑ | |
| 8 | VPC `b3-1-vpc` | 삭제 | VPC 목록에 **기본 VPC만** 남음 | ☑ | `cleanup-vpc.png` |
| 9 | NAT Gateway | **생성 안 함** | 해당 없음 | ☑ (미생성) | |
| 10 | ELB/ALB | **생성 안 함**. `b3-1-operator` 정책에 `elasticloadbalancing:*` 권한이 없어 생성 자체가 불가 | 해당 없음 | ☑ (미생성) | |
| 11 | RDS | **생성 안 함** (정책상 권한 없음) | 해당 없음 | ☑ (미생성) | |
| 12 | Billing | 결제 콘솔 접근은 루트만 켤 수 있어 **루트 사용 최소화 원칙에 따라 미실시**. 대신 1~8번의 "목록 비어 있음" 화면으로 과금 리소스가 남지 않았음을 증빙. 계정은 Free 플랜이라 업그레이드 전에는 카드 청구 없음 | — | 미실시(사유 기재) | |
| 13 | IAM 사용자 `b3-1-operator`·정책 | 과금 항목이 아니라 평가 기간에는 유지, 평가 종료 후 삭제 여부 결정 | — | 유지 | |

## 과금이 생기는 대표 요인 (왜 위 항목을 지우는가)

- **실행 중인 EC2** — 시간당 과금(프리 티어 한도 초과 시). 중지(Stop)해도 EBS는 계속 과금 → 실습 끝이면 **종료**.
- **EBS 볼륨** — 인스턴스가 없어도 볼륨이 남아 있으면 GB-월 단위 과금.
- **퍼블릭 IPv4 / Elastic IP** — 2024-02부터 퍼블릭 IPv4 주소는 시간당 과금 대상. EC2 프리 티어에 일정 시간이 포함되지만, **연결 안 된 채 남은 Elastic IP**는 잊기 쉬운 대표 비용.
- **NAT Gateway·ALB·RDS** — 켜져 있는 것만으로 시간당 과금 → 이 미션에서는 만들지 않음.
- VPC·서브넷·라우팅 테이블·IGW·SG 자체는 요금이 없지만, 남겨두면 다음 실습에서 헷갈리고 재사용 실수를 부르므로 함께 정리.

## CLI로 한 번에 확인 (선택, `b3-1-operator` 자격)

```bash
R=ap-northeast-2
aws ec2 describe-instances --region $R --filters Name=tag:Project,Values=b3-1 \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
aws ec2 describe-volumes   --region $R --query 'Volumes[].[VolumeId,State]' --output table
aws ec2 describe-addresses --region $R --query 'Addresses[].PublicIp' --output table
aws ec2 describe-vpcs      --region $R --query 'Vpcs[].[VpcId,IsDefault,CidrBlock]' --output table
aws ec2 describe-internet-gateways --region $R --query 'InternetGateways[].InternetGatewayId' --output table
aws ec2 describe-nat-gateways --region $R --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output table
```

정리 완료 일시: 2026-11-22 18:26 (KST)
