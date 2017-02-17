#!/usr/bin/env bash

set -e

# FUNCTIONS

# Runs the `java -jar` for given application $1 jars $2 and env vars $3
function java_jar() {
    local APP_NAME=$1
    local JAR="${ROOT}/${APP_NAME}/target/*.jar"
    local EXPRESSION="nohup ${JAVA_PATH_TO_BIN}java -jar ${JAR} >${LOGS_DIR}/${APP_NAME}.log &"
    echo -e "\nTrying to run [$EXPRESSION]"
    eval ${EXPRESSION}
    pid=$!
    echo ${pid} > ${LOGS_DIR}/${APP_NAME}.pid
    echo -e "[${APP_NAME}] process pid is [${pid}]"
    echo -e "Logs are under [${LOGS_DIR}${APP_NAME}.log]\n"
    return 0
}

# ${RETRIES} number of times will try to curl to /health endpoint to passed port $1 and host $2
function curl_health_endpoint() {
    local PORT=$1
    local PASSED_HOST="${2:-$HEALTH_HOST}"
    local READY_FOR_TESTS=1
    for i in $( seq 1 "${RETRIES}" ); do
        sleep "${WAIT_TIME}"
        curl -m 5 "${PASSED_HOST}:${PORT}/health" && READY_FOR_TESTS=0 && break
        echo "Fail #$i/${RETRIES}... will try again in [${WAIT_TIME}] seconds"
    done
    return ${READY_FOR_TESTS}
}

# ${RETRIES} number of times will try to curl to /health endpoint to passed port $1 and localhost
function curl_local_health_endpoint() {
    curl_health_endpoint $1 "127.0.0.1"
}

function send_test_request() {
    local fileName=${1}
    local path="${LOGS_DIR}/${fileName}"
    for i in $( seq 1 "${NO_OF_REQUESTS}" ); do
        if (( ${i} % 100 == 0 )) ; then
            echo "Sent ${i}/${NO_OF_REQUESTS} requests"
        fi
        local CURL=`curl -s "http://localhost:6666/test"`
        echo "${CURL}" >> ${path}
    done
}

function store_heap_dump() {
    local fileName=${1}
    local path="${LOGS_DIR}/${fileName}"
    echo -e "\nStoring heapdump of [${fileName}]"
    curl -s "http://localhost:6666/heapdump" > "${path}_heapdump"
}

function calculate_99th_percentile() {
    local fileName=${1}
    local path="${LOGS_DIR}/${fileName}"
    sort -n ${path} | awk '{all[NR] = $0} END{print all[int(NR*0.99 - 0.01)]}' > "${path}_99th"
}

function calculate_difference() {

    CALCULATED_DIFFERENCE=
}

function killApps() {
    ${ROOT}/scripts/kill.sh
}

# VARIABLES
JAVA_PATH_TO_BIN="${JAVA_HOME}/bin/"
if [[ -z "${JAVA_HOME}" ]] ; then
    JAVA_PATH_TO_BIN=""
fi
ROOT=`pwd`
LOGS_DIR="${ROOT}/target/"
HEALTH_HOST="127.0.0.1"
RETRIES=10
WAIT_TIME=5
NO_OF_REQUESTS=${NO_OF_REQUESTS:-100}
ALLOWED_DIFFERENCE_IN_PERCENTS=30
NON_SLEUTH="non-sleuth-application"
SLEUTH="sleuth-application"

cat <<'EOF'

This Bash file will try to see check the memory usage of two apps. One without and one with Sleuth:

01) Build both apps
02) Run the non sleuth app
03) Curl X requests to the app and store the results in target/non_sleuth
04) Kill the non sleuth app
05) Run the sleuth app
06) Curl X requests to the app and store the results in target/sleuth
07) Kill the sleuth app
08) Calculate the 99 percentile of each of the metrics
09) Calculate the difference between memory usage of Sleuth vs Non-Sleuth app

_______ _________ _______  _______ _________
(  ____ \\__   __/(  ___  )(  ____ )\__   __/
| (    \/   ) (   | (   ) || (    )|   ) (
| (_____    | |   | (___) || (____)|   | |
(_____  )   | |   |  ___  ||     __)   | |
      ) |   | |   | (   ) || (\ (      | |
/\____) |   | |   | )   ( || ) \ \__   | |
\_______)   )_(   |/     \||/   \__/   )_(
EOF

./mvnw clean install -T 2 -DskipTests

mkdir -p "${LOGS_DIR}"
echo -e "\n\nRunning the non sleuth application\n\n"
cd "${ROOT}/${NON_SLEUTH}"
java_jar "${NON_SLEUTH}"
curl_local_health_endpoint 6666
echo -e "\n\nSending ${NO_OF_REQUESTS} requests to the app\n\n"
send_test_request "${NON_SLEUTH}"
store_heap_dump "${NON_SLEUTH}"
killApps

echo -e "\n\nRunning the sleuth application\n\n"
cd "${ROOT}/${SLEUTH}"
java_jar "${SLEUTH}"
curl_local_health_endpoint 6666
echo -e "\n\nSending ${NO_OF_REQUESTS} requests to the app\n\n"
send_test_request "${SLEUTH}"
store_heap_dump "${SLEUTH}"
killApps

calculate_99th_percentile "${NON_SLEUTH}"
calculate_99th_percentile "${SLEUTH}"

NON_SLEUTH_PERCENTILE=`cat ${LOGS_DIR}/${NON_SLEUTH}_99th`
SLEUTH_PERCENTILE=`cat ${LOGS_DIR}/${SLEUTH}_99th`

echo "99th percentile of memory usage for a non sleuth app is [${NON_SLEUTH_PERCENTILE}]"
echo "99th percentile of memory usage for a sleuth app is [${SLEUTH_PERCENTILE}]"

DIFFERENCE_IN_MEMORY=$(( SLEUTH_PERCENTILE - NON_SLEUTH_PERCENTILE ))
INCREASE_IN_PERCENTS=$(echo "scale=2; ${DIFFERENCE_IN_MEMORY}/${NON_SLEUTH_PERCENTILE}*100" | bc)

echo "The Sleuth app is using [${DIFFERENCE_IN_MEMORY}] more memory which means a increase by [${INCREASE_IN_PERCENTS}%]"

cd ${ROOT}