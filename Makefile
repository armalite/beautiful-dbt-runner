SHELL=/bin/bash -e -o pipefail
bold := $(shell tput bold)
sgr0 := $(shell tput sgr0)

.PHONY: help install check lint pyright test hooks install-hooks
.SILENT:

output_location = "output"
dbt_runner_image:="dbt-runner:latest"

MAKEFLAGS += --warn-undefined-variables
.DEFAULT_GOAL := help

## display help message
help:
	@awk '/^##.*$$/,/^[~\/\.0-9a-zA-Z_-]+:/' $(MAKEFILE_LIST) | awk '!(NR%2){print $$0p}{p=$$0}' | awk 'BEGIN {FS = ":.*?##"}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' | sort

venv = .venv
pip := $(venv)/bin/pip

$(pip):
	# create empty virtualenv containing pip
	$(if $(value VIRTUAL_ENV),$(error Cannot create a virtualenv when running in a virtualenv. Please deactivate the current virtual env $(VIRTUAL_ENV)),)
	python3 -m venv --clear $(venv)
	cp pip.conf $(venv)
	$(pip) install pip==21.3.1 setuptools==58.5.3 wheel==0.37.0

$(venv): setup.py $(pip)
	$(pip) install -e '.[dev]'
	touch $(venv)

# delete the venv
clean:
	rm -rf $(venv)

## create venv and install this package and hooks
install: $(venv) node_modules $(if $(value CI),,install-hooks)

node_modules: package.json
	npm install --no-save
	touch node_modules

## format all code
format: $(venv)
	$(venv)/bin/autopep8 --in-place .
	$(venv)/bin/isort .

## pyright type check
pyright: node_modules $(venv)
# activate venv so pyright can find dependencies
	PATH="$(venv)/bin:$$PATH" node_modules/.bin/pyright

## run pre-commit git hooks on all files
hooks: $(venv)
	$(venv)/bin/pre-commit run --show-diff-on-failure --color=always --all-files --hook-stage push

## lint using flake8
lint: $(venv)
	$(venv)/bin/flake8

## lint and type check
check: lint pyright


install-hooks: .git/hooks/pre-commit .git/hooks/pre-push

.git/hooks/pre-commit: $(venv)
	$(venv)/bin/pre-commit install -t pre-commit

.git/hooks/pre-push: $(venv)
	$(venv)/bin/pre-commit install -t pre-push

###############################################################################
# Local Development Targets
#
###############################################################################

build:
	docker build -t dbt-runner:latest .


# This example mounts the local dbt project (dbt_tester) into the container under dbt_tester/
# The source code is also mounted during this command to test changes quickly (i.e. image does not need rebuilding)
run-dbt-mounted:
	$(eval pwd:=$(shell pwd))
	docker run -it \
			-p 443:443 \
			-v $(pwd)/src:/src \
			-v $(pwd)/dbt_tester:/dbt_tester \
			-e DBT_PATH="dbt_tester" \
			-e DBT_TARGET="admin" \
			-e DBT_ROLE="DBT_ROLE" \
			-e DBT_PASS \
			-e DBT_ACCOUNT \
			-e DBT_COMMAND="dbt deps --profiles-dir . && dbt run --profiles-dir ."	\
			dbt-runner:latest	\
			$(SHELL)

# This example mounts the local dbt project (dbt_tester) into the container and uses the key pair configuration for connection
# This command also takes in DBT_PASS_SECRET_ARN as a parameter, which will cause the application to attempt to fetch this secret
# Since DBT_CRED_TYPE='key', the application will assume the stored secret is a private key stored as a binary, and will fetch + write it to a file named specified in DBT_KEY_NAME param
# Update the values of DBT_USER, DBT_PASS_SECRET_ARN, DBT_RPOLE, DBT_WH, DBT_COMMAND etc.
run-dbt-mounted-key:
	$(eval pwd:=$(shell pwd))
	docker run -it \
			-p 443:443 \
			-v $(pwd)/src:/src \
			-v $(pwd)/dbt_tester:/dbt_tester \
			-e DBT_USER="MY_DBT_USER" \
			-e DBT_PASS_SECRET_ARN='arn:aws:secretsmanager:us-east-1:123456789123:secret:snowflake.user.privatekey.mysecret-abc' \
			-e DBT_CRED_TYPE='key' \
			-e DBT_KEY_NAME='private.key' \
			-e AWS_ACCESS_KEY_ID \
			-e AWS_SECRET_ACCESS_KEY \
			-e AWS_SESSION_TOKEN \
			-e DBT_PATH="dbt_tester" \
			-e DBT_TARGET="sandbox_key" \
			-e DBT_ROLE="MY_SNOWFLAKE_ROLE" \
			-e DBT_WH="MY_SNOWFLAKE_WH" \
			-e DBT_COMMAND="./run_dbt.sh"	\
			dbt-runner:latest	\

# This fetches a dbt project from github. The repository path is specified in the DBT_PACKAGE_URL env var
# The dbt_download folder is mounted just so that we can see the cloned github repo locally
# For your purposes you can replace DBT_PACKAGE_URL values to point to your own github containing your dbt project
# DBT_PASS will need to be set in your environment variable, along with DBT_ACCOUNT (Snowflake account)
run-dbt-github:
	$(eval pwd:=$(shell pwd))
	docker run -it \
			-p 443:443 \
			-v $(pwd)/src:/src \
			-v $(pwd)/dbt_download:/dbt_download \
			-e DBT_PACKAGE_URL="https://github.com/Armalite/yummy-dummy-dbt/" \
			-e DBT_PACKAGE_TYPE="github" \
			-e DBT_PATH="dbt_tester" \
			-e DBT_TARGET="admin" \
			-e DBT_ROLE="DBT_ROLE" \
			-e DBT_PASS \
			-e DBT_ACCOUNT \
			-e DBT_COMMAND="./run_dbt.sh"	\
			dbt-runner:latest	\
			$(SHELL)

# This kicks off a Make test by mounting the entire repo in the container
test-container-mounted: build-dbt-runner-image
	$(eval pwd:=$(shell pwd))
	docker run --rm -it \
			-v $(pwd):/runner \
			-w /runner \
			--entrypoint "make" \
			$(dbt_runner_image)	\
			test

# This kicks off a Make test using the app that is installed in the container image (see Dockerfile)
test-container: build-dbt-runner-image
	$(eval pwd:=$(shell pwd))
	docker run --rm -it \
			-e ARTI_PASS \
			--entrypoint "make" \
			$(dbt_runner_image)	\
			test

###############################################################################
# Deployment targets
#
###############################################################################
build-deployer-image: **/* #
	echo "$(bold)=== Building Docker Image ===$(sgr0)"
	@docker build -t beautiful_dbt_runner_deployer:latest .

publish-docker-images: build-deployer-image
	echo "Publishing DBT runner image"

###############################################################################
# Tests
#
###############################################################################
test: test-functional
	echo "$(bold)=== Run all tests ===$(sgr0)"

unit-tests:
	echo "$(bold)=== Running unit tests ===$(sgr0)"
	#pytest --capture=no --doctest-modules -m unit --user=$(user) --password=$(password) --account=$(account) --prefix=$(prefix) --environment=$(env) tests/

test-functional:
	echo "$(bold)=== Running functional tests ===$(sgr0)"
	pytest --capture=tee-sys --doctest-modules -m functional tests/

end-to-end-tests:
	echo "$(bold)=== Running end-to-end tests ===$(sgr0)"
	#pytest --capture=no --doctest-modules -m end_to_end --user=$(user) --password=$(password) --account=$(account) --prefix=$(prefix) --environment=$(env) tests/

pre-deployment-tests:
	echo "$(bold)=== Running pre-deployment tests ===$(sgr0)"
	#pytest --capture=no --doctest-modules -m pre_deployment --user=$(user) --password=$(password) --account=$(account) --prefix=$(prefix) --environment=$(env) tests/

post-deployment-tests:
	echo "$(bold)=== Running post-deployment tests ===$(sgr0)"
	#pytest --capture=no --doctest-modules -m post_deployment --user=$(user) --password=$(password) --account=$(account) --prefix=$(prefix) --environment=$(env) tests/
