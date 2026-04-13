.PHONY: deploy deploy-ecs destroy ssh tunnel status setup run switch-branch switch-executor

SUFFIX ?=
REPO ?= https://github.com/apache/airflow.git
BRANCH ?= main

STACK_SUFFIX = $(if $(SUFFIX),-$(SUFFIX),)
CDK_SUFFIX_ARG = $(if $(SUFFIX),-c suffix=$(SUFFIX),)

INSTANCE_ID = $(shell aws cloudformation describe-stacks \
  --stack-name AirflowEc2$(STACK_SUFFIX) \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2InstanceId'].OutputValue" \
  --output text 2>/dev/null)

# ── CDK Deploy ──────────────────────────────────────────────────────────────────
deploy:
	cd cdk && npm install && npm run build && npx cdk deploy --all \
	  $(CDK_SUFFIX_ARG) \
	  -c repo=$(REPO) -c branch=$(BRANCH) \
	  --require-approval never

deploy-ecs:
	cd cdk && npm install && npm run build && npx cdk deploy --all \
	  -c executor=ecs \
	  $(CDK_SUFFIX_ARG) \
	  -c repo=$(REPO) -c branch=$(BRANCH) \
	  --require-approval never

destroy:
	cd cdk && npx cdk destroy --all $(CDK_SUFFIX_ARG) --force

# ── EC2 Access ──────────────────────────────────────────────────────────────────
ssh:
	aws ssm start-session --target $(INSTANCE_ID)

tunnel:
	aws ssm start-session --target $(INSTANCE_ID) \
	  --document-name AWS-StartPortForwardingSession \
	  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'

status:
	@echo "Instance: $(INSTANCE_ID)"
	@aws ec2 describe-instance-status --instance-ids $(INSTANCE_ID) \
	  --query "InstanceStatuses[0].{State:InstanceState.Name,Status:InstanceStatus.Status}" \
	  --output table 2>/dev/null || echo "Instance not found or not running"

# ── Remote Commands (run on EC2 via SSM) ──────────────────────────────────
setup:
	@echo "Running setup on EC2 (this takes ~10 minutes)..."
	aws ssm send-command \
	  --instance-ids $(INSTANCE_ID) \
	  --document-name AWS-RunShellScript \
	  --parameters '{"commands":["sudo -u ec2-user bash /opt/airflow-scripts/setup-airflow.sh"],"executionTimeout":["1800"]}' \
	  --output text --query "Command.CommandId"

run:
	@echo "Running on EC2: $(CMD)"
	aws ssm send-command \
	  --instance-ids $(INSTANCE_ID) \
	  --document-name AWS-RunShellScript \
	  --parameters '{"commands":["sudo -u ec2-user bash -lc '"'"'"'$(CMD)'"'"'"'"],"executionTimeout":["600"]}' \
	  --output text --query "Command.CommandId"

switch-branch:
	@echo "Switching to branch $(BRANCH) on EC2..."
	aws ssm send-command \
	  --instance-ids $(INSTANCE_ID) \
	  --document-name AWS-RunShellScript \
	  --parameters '{"commands":["sudo -u ec2-user bash /opt/airflow-scripts/switch-branch.sh $(BRANCH) $(REPO)"],"executionTimeout":["1800"]}' \
	  --output text --query "Command.CommandId"

switch-executor:
	@echo "Switching executor to $(EXECUTOR) on EC2..."
	aws ssm send-command \
	  --instance-ids $(INSTANCE_ID) \
	  --document-name AWS-RunShellScript \
	  --parameters '{"commands":["sudo -u ec2-user bash /opt/airflow-scripts/switch-executor.sh $(EXECUTOR)"],"executionTimeout":["600"]}' \
	  --output text --query "Command.CommandId"
