#!/usr/bin/env bash
#
# Creates everything the "Continuous Deployment to ECS" tutorial needs:
#
#   - notes-ecs, an ECR repository for the images that GitHub Actions builds
#   - GitHub as an identity provider in IAM, if your account doesn't have it
#   - notes-ecs-github, a role that GitHub Actions in your repository can use
#     to push to notes-ecs, and the repository variable AWS_ROLE_ARN
#   - notes-ecs-<account-id>, a private S3 bucket for files attached to notes
#   - /notes-ecs/MAX_NOTE_LENGTH and /notes-ecs/S3_BUCKET in Parameter Store
#   - ecsTaskExecutionRole, if you don't have it already, and notes-task-role
#   - the log group /ecs/notes-task
#   - notes-alb-sg, which allows HTTP from anywhere, and notes-tasks-sg, which
#     only allows port 8000 from the load balancer
#   - the target group notes-targets, and the load balancer notes-alb with a
#     listener on port 80
#   - the cluster notes-cluster, the task definition notes-task, and the
#     service notes-service, which runs two tasks behind the load balancer
#
# The first revision of notes-task runs ghcr.io/mcandru/wdd-notes-app:ecs.
# In the tutorial, GitHub Actions deploys your own images from notes-ecs.
#
# Run it from the root of your own repository, created from the template:
#
#   ./scripts/create-infrastructure.sh
#
# Delete everything again with ./scripts/destroy-infrastructure.sh

set -euo pipefail

export AWS_REGION=eu-west-1

# Print output straight to the terminal, instead of opening it in a pager
# that waits for you to press q
export AWS_PAGER=""

REPOSITORY_NAME=notes-ecs
GITHUB_ROLE_NAME=notes-ecs-github
CLUSTER_NAME=notes-cluster
SERVICE_NAME=notes-service
TASK_FAMILY=notes-task
CONTAINER_NAME=notes
APP_PORT=8000
START_IMAGE=ghcr.io/mcandru/wdd-notes-app:ecs
EXECUTION_ROLE_NAME=ecsTaskExecutionRole
TASK_ROLE_NAME=notes-task-role
LOG_GROUP_NAME=/ecs/notes-task
ALB_NAME=notes-alb
ALB_SG_NAME=notes-alb-sg
TASKS_SG_NAME=notes-tasks-sg
TARGET_GROUP_NAME=notes-targets
MAX_LENGTH_PARAMETER=/notes-ecs/MAX_NOTE_LENGTH
BUCKET_PARAMETER=/notes-ecs/S3_BUCKET

# Every resource gets this tag, so that you can find them in the console
PROJECT_TAG=wdd-ecs-cli

# The script uses the GitHub CLI to find your repository and to store the
# role's ARN in it

if ! command -v gh > /dev/null; then
  echo "The GitHub CLI isn't installed. Install it, run gh auth login, and run"
  echo "this script again."
  exit 1
fi

if ! gh auth status > /dev/null 2>&1; then
  echo "The GitHub CLI isn't logged in. Run gh auth login, and run this script"
  echo "again."
  exit 1
fi

# gh works out the repository from the folder's git remote
GITHUB_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
GITHUB_BRANCH=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)

if [ "$GITHUB_REPO" = "mcandru/wdd-notes-ecs-starter" ]; then
  echo "This folder is a clone of the template. Create your own repository"
  echo "from the template on GitHub, clone it, and run this script in it."
  exit 1
fi

# The OIDC subject that GitHub puts in tokens for workflows on the default
# branch. Asking GitHub for it gets the exact format for your repository.
SUBJECT_PREFIX=$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix)
SUBJECT="$SUBJECT_PREFIX:ref:refs/heads/$GITHUB_BRANCH"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Bucket names are shared by every AWS account, so the account ID makes this
# one unique
BUCKET_NAME=notes-ecs-$ACCOUNT_ID

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "$VPC_ID" = "None" ]; then
  echo "This region has no default VPC. Create one in the VPC console with"
  echo "Actions, Create default VPC, and run this script again."
  exit 1
fi

subnet_in_zone() {
  aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" Name=availability-zone,Values="$1" \
    --query 'Subnets[0].SubnetId' \
    --output text
}

SUBNET_A=$(subnet_in_zone "${AWS_REGION}a")
SUBNET_B=$(subnet_in_zone "${AWS_REGION}b")

# Stop if a previous run, or the earlier ECS tutorial, left resources behind

already_exists() {
  echo "$1 already exists. Run ./scripts/destroy-infrastructure.sh first,"
  echo "then run this script again."
  exit 1
}

if aws ecr describe-repositories --repository-names "$REPOSITORY_NAME" > /dev/null 2>&1; then
  already_exists "The ECR repository $REPOSITORY_NAME"
fi

CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters "$CLUSTER_NAME" \
  --query 'clusters[0].status' \
  --output text)

if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
  already_exists "The cluster $CLUSTER_NAME"
fi

EXISTING_ALB=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?LoadBalancerName=='$ALB_NAME'] | [0].LoadBalancerArn" \
  --output text)

if [ "$EXISTING_ALB" != "None" ]; then
  already_exists "The load balancer $ALB_NAME"
fi

for sg in "$ALB_SG_NAME" "$TASKS_SG_NAME"; do
  EXISTING_SG=$(aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

  if [ "$EXISTING_SG" != "None" ]; then
    already_exists "The security group $sg"
  fi
done

if aws s3api head-bucket --bucket "$BUCKET_NAME" > /dev/null 2>&1; then
  already_exists "The bucket $BUCKET_NAME"
fi

if aws iam get-role --role-name "$GITHUB_ROLE_NAME" > /dev/null 2>&1; then
  already_exists "The role $GITHUB_ROLE_NAME"
fi

# The ECR repository. Tags are mutable, because each push moves the latest
# tag to the newest image.

echo "Creating ECR repository $REPOSITORY_NAME"

REPOSITORY_URI=$(aws ecr create-repository \
  --repository-name "$REPOSITORY_NAME" \
  --image-tag-mutability MUTABLE \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'repository.repositoryUri' \
  --output text)

# The bucket for files attached to notes. New buckets block all public
# access. Outside us-east-1, create-bucket needs the region in
# --create-bucket-configuration as well as in AWS_REGION.

echo "Creating bucket $BUCKET_NAME"

aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION" \
  > /dev/null

aws s3api put-bucket-tagging \
  --bucket "$BUCKET_NAME" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG}]"

# The app's settings in Parameter Store

echo "Creating parameters $MAX_LENGTH_PARAMETER and $BUCKET_PARAMETER"

aws ssm put-parameter --name "$MAX_LENGTH_PARAMETER" --type String --value 100 --overwrite > /dev/null
aws ssm put-parameter --name "$BUCKET_PARAMETER" --type String --value "$BUCKET_NAME" --overwrite > /dev/null

MAX_LENGTH_PARAMETER_ARN=$(aws ssm get-parameter --name "$MAX_LENGTH_PARAMETER" --query Parameter.ARN --output text)
BUCKET_PARAMETER_ARN=$(aws ssm get-parameter --name "$BUCKET_PARAMETER" --query Parameter.ARN --output text)

# The log group for the tasks' output

if [ "$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" \
  --query "logGroups[?logGroupName=='$LOG_GROUP_NAME'] | length(@)" --output text)" = "0" ]; then
  echo "Creating log group $LOG_GROUP_NAME"
  aws logs create-log-group --log-group-name "$LOG_GROUP_NAME"
fi

# The roles. Both are used by ECS tasks, so both trust ecs-tasks.amazonaws.com.
# put-role-policy replaces an inline policy with the same name, so running it
# on a role that already exists is safe.

TASKS_TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}'

if ! aws iam get-role --role-name "$EXECUTION_ROLE_NAME" > /dev/null 2>&1; then
  echo "Creating role $EXECUTION_ROLE_NAME"

  aws iam create-role \
    --role-name "$EXECUTION_ROLE_NAME" \
    --assume-role-policy-document "$TASKS_TRUST_POLICY" \
    > /dev/null

  aws iam attach-role-policy \
    --role-name "$EXECUTION_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
fi

aws iam put-role-policy \
  --role-name "$EXECUTION_ROLE_NAME" \
  --policy-name notes-ecs-task-execution \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": \"ssm:GetParameters\",
        \"Resource\": \"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/notes-ecs/*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"logs:CreateLogGroup\",
        \"Resource\": \"*\"
      }
    ]
  }"

if ! aws iam get-role --role-name "$TASK_ROLE_NAME" > /dev/null 2>&1; then
  echo "Creating role $TASK_ROLE_NAME"

  aws iam create-role \
    --role-name "$TASK_ROLE_NAME" \
    --assume-role-policy-document "$TASKS_TRUST_POLICY" \
    --tags Key=Project,Value="$PROJECT_TAG" \
    > /dev/null
fi

aws iam put-role-policy \
  --role-name "$TASK_ROLE_NAME" \
  --policy-name notes-s3-access \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:PutObject\", \"s3:GetObject\"],
        \"Resource\": \"arn:aws:s3:::$BUCKET_NAME/*\"
      }
    ]
  }"

EXECUTION_ROLE_ARN=$(aws iam get-role --role-name "$EXECUTION_ROLE_NAME" --query Role.Arn --output text)
TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" --query Role.Arn --output text)

# GitHub as an identity provider. An account can only have one provider for
# GitHub, and every role that GitHub Actions uses shares it, so the script
# only adds it if it's missing.

PROVIDER_ARN=arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" > /dev/null 2>&1; then
  # AWS only accepts tokens whose audience the provider lists
  AUDIENCES=$(aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$PROVIDER_ARN" \
    --query ClientIDList \
    --output text)

  case " $AUDIENCES " in
    *" sts.amazonaws.com "*) ;;
    *)
      aws iam add-client-id-to-open-id-connect-provider \
        --open-id-connect-provider-arn "$PROVIDER_ARN" \
        --client-id sts.amazonaws.com
      ;;
  esac
else
  echo "Adding GitHub as an identity provider"

  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    > /dev/null
fi

# The role for GitHub Actions. The trust policy only accepts tokens from
# workflows on the default branch of your repository.

echo "Creating role $GITHUB_ROLE_NAME for $GITHUB_REPO"

aws iam create-role \
  --role-name "$GITHUB_ROLE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Principal\": { \"Federated\": \"$PROVIDER_ARN\" },
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {
          \"StringEquals\": {
            \"token.actions.githubusercontent.com:aud\": \"sts.amazonaws.com\",
            \"token.actions.githubusercontent.com:sub\": \"$SUBJECT\"
          }
        }
      }
    ]
  }" \
  > /dev/null

aws iam put-role-policy \
  --role-name "$GITHUB_ROLE_NAME" \
  --policy-name push-notes-ecs \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": \"ecr:GetAuthorizationToken\",
        \"Resource\": \"*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"ecr:BatchCheckLayerAvailability\",
          \"ecr:BatchGetImage\",
          \"ecr:CompleteLayerUpload\",
          \"ecr:InitiateLayerUpload\",
          \"ecr:PutImage\",
          \"ecr:UploadLayerPart\"
        ],
        \"Resource\": \"arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/$REPOSITORY_NAME\"
      }
    ]
  }"

GITHUB_ROLE_ARN=$(aws iam get-role --role-name "$GITHUB_ROLE_NAME" --query Role.Arn --output text)

echo "Storing the role's ARN in the AWS_ROLE_ARN variable of $GITHUB_REPO"
gh variable set AWS_ROLE_ARN --repo "$GITHUB_REPO" --body "$GITHUB_ROLE_ARN"

# ECS uses a service-linked role to manage the load balancer and network
# interfaces for you. AWS usually creates it the first time you use ECS, so
# this fails harmlessly when the role already exists.

aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com > /dev/null 2>&1 || true

# Security groups. The tasks only accept port 8000 from the load balancer.

echo "Creating security groups $ALB_SG_NAME and $TASKS_SG_NAME"

ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$ALB_SG_NAME" \
  --description "Notes app load balancer" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  > /dev/null

TASKS_SG_ID=$(aws ec2 create-security-group \
  --group-name "$TASKS_SG_NAME" \
  --description "Notes app ECS tasks" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$TASKS_SG_ID" \
  --protocol tcp \
  --port "$APP_PORT" \
  --source-group "$ALB_SG_ID" \
  > /dev/null

# The target group. Fargate tasks are registered by IP address. A target is
# checked every 10 seconds, and two checks in a row change its status.

echo "Creating target group $TARGET_GROUP_NAME"

TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --name "$TARGET_GROUP_NAME" \
  --target-type ip \
  --protocol HTTP \
  --port "$APP_PORT" \
  --vpc-id "$VPC_ID" \
  --health-check-path /health \
  --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

# The default deregistration delay is 300 seconds, which makes every old task
# take five minutes to stop during a deployment

aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 \
  > /dev/null

# The load balancer and its listener

echo "Creating load balancer $ALB_NAME"

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$ALB_NAME" \
  --type application \
  --scheme internet-facing \
  --subnets "$SUBNET_A" "$SUBNET_B" \
  --security-groups "$ALB_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" \
  > /dev/null

echo "Waiting for the load balancer to become active. This takes a few minutes."
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"

# The cluster and the first revision of the task definition. The task
# definition has no tags, because the workflow copies them into every new
# revision, and registering a revision with tags needs ecs:TagResource.

echo "Creating cluster $CLUSTER_NAME"

aws ecs create-cluster \
  --cluster-name "$CLUSTER_NAME" \
  --tags key=Project,value="$PROJECT_TAG" \
  > /dev/null

echo "Registering task definition $TASK_FAMILY"

aws ecs register-task-definition \
  --cli-input-json "{
    \"family\": \"$TASK_FAMILY\",
    \"networkMode\": \"awsvpc\",
    \"requiresCompatibilities\": [\"FARGATE\"],
    \"cpu\": \"256\",
    \"memory\": \"512\",
    \"runtimePlatform\": { \"cpuArchitecture\": \"X86_64\", \"operatingSystemFamily\": \"LINUX\" },
    \"executionRoleArn\": \"$EXECUTION_ROLE_ARN\",
    \"taskRoleArn\": \"$TASK_ROLE_ARN\",
    \"containerDefinitions\": [
      {
        \"name\": \"$CONTAINER_NAME\",
        \"image\": \"$START_IMAGE\",
        \"essential\": true,
        \"portMappings\": [{ \"containerPort\": $APP_PORT, \"protocol\": \"tcp\" }],
        \"environment\": [{ \"name\": \"AWS_REGION\", \"value\": \"$AWS_REGION\" }],
        \"secrets\": [
          { \"name\": \"MAX_NOTE_LENGTH\", \"valueFrom\": \"$MAX_LENGTH_PARAMETER_ARN\" },
          { \"name\": \"S3_BUCKET\", \"valueFrom\": \"$BUCKET_PARAMETER_ARN\" }
        ],
        \"logConfiguration\": {
          \"logDriver\": \"awslogs\",
          \"options\": {
            \"awslogs-group\": \"$LOG_GROUP_NAME\",
            \"awslogs-region\": \"$AWS_REGION\",
            \"awslogs-stream-prefix\": \"ecs\"
          }
        }
      }
    ]
  }" \
  > /dev/null

# The service. A rolling deployment starts new tasks before it stops old
# ones (minimum 100%, maximum 200%), and the circuit breaker rolls back a
# deployment whose tasks keep failing.

echo "Creating service $SERVICE_NAME"

aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$TASKS_SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=$CONTAINER_NAME,containerPort=$APP_PORT" \
  --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200,deploymentCircuitBreaker={enable=true,rollback=true}" \
  --tags key=Project,value="$PROJECT_TAG" \
  > /dev/null

echo "Waiting for both tasks to start and pass their health checks."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo
echo "Done. You'll need these in the tutorial:"
echo
echo "  Load balancer DNS name: $ALB_DNS"
echo "  ECR repository URI:     $REPOSITORY_URI"
echo "  GitHub Actions role:    $GITHUB_ROLE_NAME"
