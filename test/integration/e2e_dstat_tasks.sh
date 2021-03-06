#!/bin/bash

# Copyright 2016 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset

# Test dstat.
#
# This test launches a job with multiple tasks and then verifies
# that dstat can lookup jobs by job-id, status, age, task-id,
# and job-name, with both default and --full output. It ensures
# that no error is returned and the output looks minimally sane.

readonly SCRIPT_DIR="$(dirname "${0}")"
readonly TESTDATA_DIR="$(cd "${SCRIPT_DIR}/../testdata" && pwd)"
readonly JOB_NAME="test-job"

# This test is not sensitive to the output of the dsub job.
# Set the ALLOW_DIRTY_TESTS environment variable to 1 in your shell to
# run this test without first emptying the output and logging directories.
source "${SCRIPT_DIR}/test_setup_e2e.sh"

if [[ "${CHECK_RESULTS_ONLY:-0}" -eq 0 ]]; then

  echo "Launching pipeline..."

  JOBID="$(run_dsub \
    --name "${JOB_NAME}" \
    --command 'sleep 5m' \
    --tasks "${TASKS_FILE}")"

  # Get a count of the number of lines in the tasks file.
  # It should be one more than the total number of tasks, since it includes
  # the header line.
  readonly TASKS_FILE_LINE_COUNT="$(cat "${TASKS_FILE}" | wc -l)"
  readonly EXPECTED_TASKS_COUNT="$((TASKS_FILE_LINE_COUNT - 1))"

  # Ensure the correct number of tasks were launched
  if ! TASKS_STATUS="$(run_dstat --jobs "${JOBID}" --full --format yaml 2>&1 | sed --quiet 's#^ *status: *\(.*\)#\1#p')"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${TASKS_STATUS}"
    exit 1
  fi

  readonly TASKS_LAUNCH_COUNT="$(echo "${TASKS_STATUS}" | wc -l)"

  if [[ "${TASKS_LAUNCH_COUNT}" -ne "${EXPECTED_TASKS_COUNT}" ]]; then
    1>&2 echo "Unexpected count of launched tasks: ${TASKS_LAUNCH_COUNT}"
    1>&2 echo "Expected count of launched tasks: ${EXPECTED_TASKS_COUNT}"
    exit 1
  fi

  echo "Checking dstat (by status)..."

  if ! DSTAT_OUTPUT="$(run_dstat --status 'RUNNING' --jobs "${JOBID}" 2>&1)"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! echo "${DSTAT_OUTPUT}" | grep -qi "${JOB_NAME}"; then
    echo "Job ${JOB_NAME} not found in the dstat output!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  echo "Checking dstat (by --tasks)..."

  TASK_NUM=2

  if ! DSTAT_OUTPUT="$(run_dstat --status '*' --full  --jobs "${JOBID}" --tasks "${TASK_NUM}" 2>&1)"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  # Check that the task id is set
  util::dstat_yaml_assert_field_equal "${DSTAT_OUTPUT}" "[0].task-id" "${TASK_NUM}"

  echo "Checking dstat (by job-name)..."

  if ! DSTAT_OUTPUT="$(run_dstat --status '*' --full --names "${JOB_NAME}" 2>&1)"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! echo "${DSTAT_OUTPUT}" | grep -qi "job-name: ${JOB_NAME}"; then
    echo "Job ${JOB_NAME} not found in the dstat output!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  echo "Checking dstat (by job-id: default)..."

  if ! DSTAT_OUTPUT="$(run_dstat --status '*' --jobs "${JOBID}" 2>&1)"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! echo "${DSTAT_OUTPUT}" | grep -qi "${JOB_NAME}"; then
    echo "Job ${JOB_NAME} not found in the dstat output!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  echo "Checking dstat (by job-id: full)..."

  if ! DSTAT_OUTPUT=$(run_dstat --status '*' --full --jobs "${JOBID}" 2>&1); then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! echo "${DSTAT_OUTPUT}" | grep -qi "${JOB_NAME}"; then
    echo "Job ${JOB_NAME} not found in the dstat output!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  echo "Checking dstat (with a limit)..."

  LIMIT=1
  if ! DSTAT_OUTPUT=$(run_dstat --status '*' --limit="${LIMIT}" --format yaml 2>&1); then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  TASK_COUNT=$(echo "${DSTAT_OUTPUT}" | grep -w "job-name" | wc -l)
  if [[ "${TASK_COUNT}" -ne "${LIMIT}" ]]; then
    echo "Number of tasks returned by limit ${TASK_COUNT} not ${LIMIT}!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi
  echo "Checking dstat (summary)"

  if ! DSTAT_OUTPUT="$(run_dstat --status '*' --jobs "${JOBID}" --summary 2>&1)"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! echo "${DSTAT_OUTPUT}" | grep -qi "${JOB_NAME}"; then
    echo "Job ${JOB_NAME} not found in the dstat output!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! echo "${DSTAT_OUTPUT}" | grep -qi "RUNNING \+3"; then
    echo "'RUNNING 3' not found in the dstat output!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  echo "Checking dstat (summary, json)"

  if ! run_dstat --status '*' --jobs "${JOBID}" --summary --format json > "${TEST_TMP}/summary_json"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! diff -q "${TEST_TMP}/summary_json" "${TESTDATA_DIR}/summary_3_running.json"; then
    echo "Output does not match expected"
    echo "Expected:"
    cat "${TESTDATA_DIR}/summary_3_running.json"
    echo "Output:"
    cat "${TEST_TMP}/summary_json"
    exit 1
  fi

  echo "Checking dstat (summary, yaml)"

  if ! run_dstat --status '*' --jobs "${JOBID}" --summary --format yaml > "${TEST_TMP}/summary_yaml"; then
    echo "dstat exited with a non-zero exit code!"
    echo "Output:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  if ! diff -q "${TEST_TMP}/summary_yaml" "${TESTDATA_DIR}/summary_3_running.yaml"; then
    echo "Output does not match expected"
    echo "Expected:"
    cat "${TESTDATA_DIR}/summary_3_running.yaml"
    echo "Output:"
    cat "${TEST_TMP}/summary_yaml"
    exit 1
  fi

  echo "Waiting 5 seconds and checking 'dstat --age 5s'..."
  sleep 5s

  DSTAT_OUTPUT="$(run_dstat_age "5s" --status '*' --jobs "${JOBID}")"
  if [[ -n "${DSTAT_OUTPUT}" ]]; then
    echo "dstat output not empty as expected:"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  echo "Verifying that the job didn't disappear completely."

  DSTAT_OUTPUT="$(run_dstat --status '*' --jobs "${JOBID}" 2>&1)"
  if ! echo "${DSTAT_OUTPUT}" | grep -qi "${JOB_NAME}"; then
    echo "Job ${JOB_NAME} not found in the dstat output!"
    echo "${DSTAT_OUTPUT}"
    exit 1
  fi

  echo "SUCCESS"

fi


