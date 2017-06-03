DOCKER := docker
AWS := aws
ANSIBLE-PLAYBOOK := ansible-playbook
TAR := tar

ifeq (${CIRCLE_BRANCH},prod)
	ENV=prod
	DOCKER_IMAGE=${prod_docker_image}
	AWS_ACCESS_KEY_ID=${prod_iam_access_key}
	AWS_SECRET_ACCESS_KEY=${prod_iam_secret_access_key}
else
	ENV=test
	DOCKER_IMAGE=${test_docker_image}
	AWS_ACCESS_KEY_ID=${test_iam_access_key}
	AWS_SECRET_ACCESS_KEY=${test_iam_secret_access_key}
endif

LOCAL_TGZ=/tmp/artifacts/${CIRCLE_PROJECT_REPONAME}.${SHORT_SHA}.tgz
SHORT_SHA1 = $(shell echo $(CIRCLE_SHA1) | head -c 12)
DOCKER_TAG := build-${SHORT_SHA1}
S3_TGZ="${CIRCLE_PROJECT_REPONAME}/${ENV}/${CIRCLE_PROJECT_REPONAME}.${SHORT_SHA1}.tgz"
LOCAL_SHA_TXT="${CIRCLE_ARTIFACTS}/${CIRCLE_PROJECT_REPONAME}.${SHORT_SHA1}.txt"
LOCAL_BRANCH_TXT="${CIRCLE_ARTIFACTS}/${CIRCLE_PROJECT_REPONAME}.${CIRCLE_BRANCH}.txt"


.aws/credentials:
	mkdir -p /root/.aws
	echo -e "[default]\naws_access_key_id = ${AWS_ACCESS_KEY_ID}\naws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}" > ~/.aws/credentials
credentials: .aws/credentials

app/config/parameters.yml: .aws/credentials
	$(AWS) s3 cp "s3://${DEPLOY_BUCKET}/ansible/${CIRCLE_PROJECT_REPONAME}_${ENV}_params.yml.j2" app/config/parameters.yml
parameters: app/config/parameters.yml

vhosts:
	$(ANSIBLE-PLAYBOOK) -e "circle_webroot=\"~/${CIRCLE_PROJECT_REPONAME}/\" env=\"${ENV}\" app_path=\"${IMAGE_BUILD_DIRECTORY}\"" -c local -i localhost, circle/build.yml
.PHONY: vhosts

docker-pull:
	$(DOCKER) pull ${DOCKER_IMAGE}:${CIRCLE_BRANCH} || true
.PHONY: docker-pull

docker-image:
	$(DOCKER) build --cache-from ${DOCKER_IMAGE}:${CIRCLE_BRANCH} \
		--build-arg GITHUB_TOKEN=${github_token} \
		--build-arg BUILD_DIRECTORY=${IMAGE_BUILD_DIRECTORY} \
		-t ${DOCKER_IMAGE}:${DOCKER_TAG} .
	$(DOCKER) tag ${DOCKER_IMAGE}:${DOCKER_TAG} ${DOCKER_IMAGE}:${CIRCLE_BRANCH}
	$(DOCKER) tag ${DOCKER_IMAGE}:${DOCKER_TAG} test-artifact
.PHONY: docker-image

docker-push:
	$(DOCKER) push ${DOCKER_IMAGE}:${DOCKER_TAG}
	$(DOCKER) push ${DOCKER_IMAGE}:${CIRCLE_BRANCH}
.PHONY: docker-push

boot-artifact:
	$(DOCKER) create --name ${CIRCLE_PROJECT_REPONAME}-artifact ${DOCKER_IMAGE}:${DOCKER_TAG}
.PHONY: boot-artifact

artifact: boot-artifact
	mkdir -p /tmp/build /tmp/artifacts
	$(DOCKER) cp ${CIRCLE_PROJECT_REPONAME}-artifact:${IMAGE_BUILD_DIRECTORY}/ /tmp/build
	$(DOCKER) cp ${CIRCLE_PROJECT_REPONAME}-artifact:/etc/apache2/sites-available/ /tmp/build/vhosts
	$(TAR) --exclude-vcs -zcf ${LOCAL_TGZ} -C /tmp/build/${CIRCLE_PROJECT_REPONAME}/ .
.PHONY: artifact

copy-artifact-to-s3:
	$(AWS) s3 cp "${LOCAL_TGZ}" "s3://${DEPLOY_BUCKET}/${CIRCLE_PROJECT_REPONAME}/${ENV}/"

	# Create pointer files with commit hash and branch references to use with deployments
	# i.e. cp $foo/unity-product.abcdef123456.txt and unity-product.prod.txt to s3://bucket/unity-product/
	echo "${S3_TGZ}" > "${LOCAL_SHA_TXT}"
	echo "${S3_TGZ}" > "${LOCAL_BRANCH_TXT}"

	# Upload commit hash pointer file, i.e. cp $foo/unity-product.abcdef123456.txt s3://bucket/unity-product/$env/
	$(AWS) s3 cp "${LOCAL_SHA_TXT}" "s3://${DEPLOY_BUCKET}/${CIRCLE_PROJECT_REPONAME}/${ENV}/"

	# Upload branch pointer file used in deployment, i.e. cp $foo/unity-product.prod.txt s3://bucket/unity-product/$env/
	$(AWS) s3 cp "${LOCAL_BRANCH_TXT}" "s3://${DEPLOY_BUCKET}/${CIRCLE_PROJECT_REPONAME}/${ENV}/"
.PHONY: copy-artifact-to-s3

docker:
	$(DOCKER)
.PHONY: docker
