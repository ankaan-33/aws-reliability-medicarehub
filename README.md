# MediCareHub – Highly Available Web App on AWS

**AWS Well-Architected Framework: Reliability Pillar**

Healthcare organisations can't afford downtime. This project takes a single-server app and rebuilds it as a self-healing, Multi-AZ architecture that keeps serving users through instance crashes and Availability Zone outages.

```
                       Route 53 (failover routing + health check)
                    PRIMARY │                     │ SECONDARY
                            ▼                     ▼
             Application Load Balancer     S3 static maintenance site
                 │                 │
        ┌────────┴──────┐ ┌────────┴──────┐
        │ AZ a          │ │ AZ b          │
        │ EC2 (ASG)     │ │ EC2 (ASG)     │   ← Auto Scaling: min 2, max 4, ELB health checks
        │    │          │ │    │          │
        │ EFS mount ────┼─┼─── EFS mount  │   ← shared /uploads on every instance
        │               │ │               │
        │ RDS primary ◀─┼─┼─▶ RDS standby │   ← Multi-AZ MySQL, synchronous replication
        └───────────────┘ └───────────────┘
```

## What's in this repo

| Path | What it is |
|---|---|
| `infrastructure/template.yaml` | CloudFormation: VPC, ALB, Auto Scaling group, EFS, Multi-AZ RDS and Route 53 failover |
| `app/index.html` | The demo page. It shows which instance and AZ served each request |
| `app/maintenance.html` | The failover page, hosted in S3 |
| `scripts/deploy.sh` | Deploys the stack and uploads the failover page |
| `scripts/chaos-tests.sh` | Kill an instance, force a database failover, or fail the whole app tier |

## How each failure is handled

| Failure | What happens |
|---|---|
| An instance crashes | The ALB health check fails, traffic moves to healthy instances, and the ASG launches a replacement. |
| A whole AZ goes down | The other AZ keeps serving traffic and RDS fails over to its standby. The ASG rebalances once the AZ returns. |
| A traffic spike | Target tracking adds instances to keep CPU around 50%, up to 4. |
| The database primary fails | RDS promotes the standby within 1–2 minutes. The endpoint doesn't change. |
| The whole app tier fails | The Route 53 health check fails and DNS sends users to the S3 maintenance page. |

## Design notes

I first built this by hand in the AWS console, then turned it into infrastructure as code:

- **EFS mounts on boot.** The template injects the real file system ID into the startup script and adds an `fstab` entry, so every new instance mounts the shared storage automatically.
- **The failover records share one name.** Route 53 only pairs PRIMARY and SECONDARY records that have the same name. The S3 bucket is named after the domain, as S3 website hosting requires, and it's reached through an alias record instead of a CNAME containing `http://`.
- **Layered security groups:** ALB → app → EFS/RDS, each allowing traffic only from the layer in front of it. The database sits in subnets with no internet route.
- **No stored passwords or SSH keys.** RDS generates its password and keeps it in Secrets Manager. You reach instances through Session Manager, and they require IMDSv2.
- **Encryption at rest** for both EFS and RDS.

## Deploy

**You'll need:** the AWS CLI, logged in. DNS failover is optional and needs a domain in a Route 53 public hosted zone.

```bash
# Without DNS failover
./scripts/deploy.sh medicarehub <region>

# With DNS failover
./scripts/deploy.sh medicarehub <region> DomainName=app.example.com HostedZoneId=<Z…>
```

Open the `AppUrl` output and refresh a few times. You'll see the serving instance and AZ change.

**Test the resilience:**

```bash
./scripts/chaos-tests.sh terminate-instance    # self-healing
./scripts/chaos-tests.sh reboot-db-failover    # Multi-AZ RDS
./scripts/chaos-tests.sh break-alb             # Route 53 → S3 failover (needs a domain)
```

## Cost and clean-up

This stack is **not** free tier. Multi-AZ RDS, the ALB and two instances come to roughly **$2–3 a day**. Delete it once you've finished testing:

```bash
aws s3 rm s3://<your-domain> --recursive   # only if you enabled DNS failover
aws cloudformation delete-stack --stack-name medicarehub --region <region>
```

## Next steps

- HTTPS on the ALB using an ACM certificate
- App instances in private subnets behind NAT (see my [Security Pillar project](https://github.com/ankaan-33/aws-security-ecommerce))
- AWS Backup plans for RDS and EFS
- A warm standby in a second region for regional failover
