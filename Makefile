APP_NAME=gobid
REGION=us-east-1
ACCOUNT_ID=$(shell aws sts get-caller-identity --query Account --output text)
ECR_URL=$(ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com
REPO_URL=$(ECR_URL)/$(APP_NAME)
ACCESS_ROLE_ARN=arn:aws:iam::592406580033:role/AppRunnerECRAccessRole
SG_NAME=gobid-sg
VPC_ID=vpc-0746fa24ca42014c3
GO=$(shell which go)

all: create-ecr build push deploy

create-sg:
	@if ! aws ec2 describe-security-groups --filters Name=group-name,Values=$(SG_NAME) --region $(REGION) --query 'SecurityGroups[*].GroupId' --output text | grep -qE 'sg-'; then \
		echo "Creating security group $(SG_NAME)..."; \
		aws ec2 create-security-group \
			--group-name $(SG_NAME) \
			--description "Allow Postgres for Gobid" \
			--vpc-id $(VPC_ID) \
			--region $(REGION); \
	else \
		echo "Security group $(SG_NAME) already exists."; \
	fi; \
	SG_ID=$$(aws ec2 describe-security-groups --filters Name=group-name,Values=$(SG_NAME) --region $(REGION) --query 'SecurityGroups[0].GroupId' --output text); \
	echo "Authorizing port 5432 on SG $$SG_ID..."; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol tcp \
		--port 5432 \
		--cidr 0.0.0.0/0 \
		--region $(REGION) || echo "Ingress rule already exists or failed silently."


create-ecr:
	aws ecr describe-repositories --repository-names $(APP_NAME) --region $(REGION) || \
	aws ecr create-repository --repository-name $(APP_NAME) --region $(REGION)

build:
	docker build -t $(APP_NAME) -f Dockerfile.prod .

tag:
	docker tag $(APP_NAME):latest $(REPO_URL):latest

push: tag
	aws ecr get-login-password --region $(REGION) | \
	docker login --username AWS --password-stdin $(ECR_URL)
	docker push $(REPO_URL):latest

create-db:
	@if ! aws rds describe-db-instances --db-instance-identifier $(APP_NAME)-db --region $(REGION) >/dev/null 2>&1; then \
		echo "Creating RDS instance $(APP_NAME)-db..."; \
		SG_ID=$$(aws ec2 describe-security-groups --filters Name=group-name,Values=$(SG_NAME) --region $(REGION) --query 'SecurityGroups[0].GroupId' --output text); \
		aws rds create-db-instance \
			--db-instance-identifier $(APP_NAME)-db \
			--db-instance-class db.t3.micro \
			--engine postgres \
			--allocated-storage 20 \
			--master-username postgres \
			--master-user-password 123456789 \
			--vpc-security-group-ids $$SG_ID \
			--publicly-accessible \
			--backup-retention-period 0 \
			--no-multi-az \
			--engine-version 11.22 \
			--port 5432 \
			--region $(REGION); \
	else \
		echo "RDS instance $(APP_NAME)-db already exists."; \
	fi

migrate:
	$(GO) run ./cmd/terndotenv/main.go

deploy: build tag push
	@if aws apprunner list-services --query "ServiceSummaryList[?ServiceName=='$(APP_NAME)']" --output text | grep -q '$(APP_NAME)'; then \
		echo "Service '$(APP_NAME)' exists. Updating..."; \
		SERVICE_ARN=$$(aws apprunner list-services --query "ServiceSummaryList[?ServiceName=='$(APP_NAME)'].ServiceArn" --output text); \
		aws apprunner update-service \
			--service-arn $$SERVICE_ARN \
			--source-configuration file://apprunner-config.json \
			--region $(REGION); \
	else \
		echo "Service '$(APP_NAME)' does not exist. Creating..."; \
		aws apprunner create-service \
			--service-name $(APP_NAME) \
			--source-configuration file://apprunner-config.json \
			--region $(REGION); \
	fi