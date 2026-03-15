.PHONY: deploy deploy-ecs destroy ssh tunnel status

INSTANCE_ID = $(shell aws cloudformation describe-stacks \
  --stack-name AirflowEc2 \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2InstanceId'].OutputValue" \
  --output text 2>/dev/null)

deploy:
	cd cdk && npm install && npm run build && npx cdk deploy --all --require-approval never

deploy-ecs:
	cd cdk && npm install && npm run build && npx cdk deploy --all -c executor=ecs --require-approval never

destroy:
	cd cdk && npx cdk destroy --all --force

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
