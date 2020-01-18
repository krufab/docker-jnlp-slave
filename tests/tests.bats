#!/usr/bin/env bats

AGENT_IMAGE=jenkins-jnlp-slave
AGENT_CONTAINER=bats-jenkins-jnlp-slave
NETCAT_HELPER_CONTAINER=netcat-helper

REGEX='^([0-9]+)/(.+)$'

if [[ ${FOLDER} =~ ${REGEX} ]] && [[ -d "${FOLDER}" ]]
then
  JDK="${BASH_REMATCH[1]}"
  FLAVOR="${BASH_REMATCH[2]}"
else
  echo "Wrong folder format or folder does not exist: ${FOLDER}"
  exit 1
fi

DOCKERFILE="${FOLDER}/Dockerfile"

if [[ "${JDK}" = "11" ]]
then
  AGENT_IMAGE+=":jdk11"
  AGENT_CONTAINER+="-jdk11"
else
  if [[ "${FLAVOR}" = "alpine*" ]]
  then
    AGENT_IMAGE+=":alpine"
    AGENT_CONTAINER+="-alpine"
  else
    AGENT_IMAGE+=":latest"
  fi
fi

load test_helpers

clean_test_container

buildNetcatImage

function teardown () {
  clean_test_container
}

@test "[${JDK} ${FLAVOR}] build image" {
  cd "${BATS_TEST_DIRNAME}"/.. || false
  docker build -t "${AGENT_IMAGE}" -f "${DOCKERFILE}" "${JDK}"
}

@test "[${JDK} ${FLAVOR}] image has installed jenkins-agent in PATH" {
  docker run -d -it --name "${AGENT_CONTAINER}" -P "${AGENT_IMAGE}" /bin/bash

  is_slave_container_running

  run docker exec "${AGENT_CONTAINER}" which jenkins-slave
  [ "/usr/local/bin/jenkins-slave" = "${lines[0]}" ]

  run docker exec "${AGENT_CONTAINER}" which jenkins-agent
  [ "/usr/local/bin/jenkins-agent" = "${lines[0]}" ]
}

@test "[${JDK} ${FLAVOR}] image starts jenkins-agent correctly" {
  docker run -d -it --name netcat-helper netcat-helper:latest /bin/sh

  docker run -d --link netcat-helper --name "${AGENT_CONTAINER}" "${AGENT_IMAGE}" -url http://netcat-helper:5000 aaa bbb

  run docker exec netcat-helper /bin/sh -c "timeout 10s nc -l 5000"

  # The GET request ends with a '\r'
  [ $'GET /tcpSlaveAgentListener/ HTTP/1.1\r' = "${lines[0]}" ]
}

@test "[${JDK} ${FLAVOR}] use build args correctly" {
  cd "${BATS_TEST_DIRNAME}"/.. || false

	local ARG_TEST_VERSION
  local TEST_VERSION="3.36"
	local TEST_USER="root"

	if [[ "${FLAVOR}" = "debian" ]]
  then
    ARG_TEST_VERSION="${TEST_VERSION}-1"
  elif [[ "${FLAVOR}" = "jdk11" ]]
  then
    ARG_TEST_VERSION="${TEST_VERSION}-1-jdk11"
  else
    ARG_TEST_VERSION="${TEST_VERSION}-1-alpine"
  fi

  docker build \
    --build-arg "version=${ARG_TEST_VERSION}" \
    --build-arg "user=${TEST_USER}" \
    -t "${AGENT_IMAGE}" \
    -f "${DOCKERFILE}" \
    "${JDK}"

  docker run -d -it --name "${AGENT_CONTAINER}" -P "${AGENT_IMAGE}" /bin/sh

  is_slave_container_running

  run docker exec "${AGENT_CONTAINER}" sh -c "java -cp /usr/share/jenkins/agent.jar hudson.remoting.jnlp.Main -version"
  [ "${TEST_VERSION}" = "${lines[0]}" ]

  run docker exec "${AGENT_CONTAINER}" sh -c "id -u -n ${TEST_USER}"
  [ "${TEST_USER}" = "${lines[0]}" ]
}
