# InspectFlowAI developer shortcuts. `make test` and `make lint` need no AWS account.
IMAGE ?= dataset/01-compliant/compliant-pcb.png

.PHONY: test lint deploy run demo check teardown

test:        ## run the unit tests (AWS mocked)
	python3 -m unittest discover -s tests -p "test_*.py" -v

lint:        ## validate the CloudFormation template and the shell scripts
	cfn-lint template.yaml
	shellcheck -S warning run.sh scripts/*.sh

deploy:      ## deploy / update the stack (idempotent)
	./scripts/deploy.sh

run:         ## deploy, inspect the whole dataset, print the results matrix
	./run.sh

demo:        ## inspect one image and tail the Lambda logs  (make demo IMAGE=path.png)
	./scripts/demo.sh $(IMAGE)

check:       ## pre-flight check of tooling, credentials and the deployed stack
	./scripts/check.sh

teardown:    ## empty the buckets and delete the stack
	./scripts/teardown.sh
