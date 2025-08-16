#!/bin/bash

# This script fetches live weather station data and creates timestamp, error log, and chart history files.

# --- Determine script's directory ---
# This ensures all generated files are placed relative to the script's location,
# regardless of the current working directory when the script is executed (e.g., by cron).
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# --- Robustness and Debugging ---
# Temporarily disable set -e to allow curl errors to be handled
set +e
# Treat unset variables as an error.
set -u
# Print commands and their arguments as they are executed (useful for debugging).
set -x
# The return value of a pipeline is the status of the last command to exit with a non-zero status,
# or zero if all commands exit successfully.
set -o pipefail

# --- Configuration for Sensor Hubs ---
# Uncomment and configure DATA_URL_2, DATA_URL_3, DATA_URL_4 if you have more sensor hubs.
# The corresponding data-N.json files will be generated in the script's directory.
DATA_URL_1="http://192.168.1.27/get_livedata_info"
DATA_URL_2="" # Example: "http://192.168.1.28/get_livedata_info"
DATA_URL_3="" # Example: "http://192.168.1.29/get_livedata_info"
DATA_URL_4="" # Example: "http://192.168.1.30/get_livedata_info"

# Output files (paths are relative to SCRIPT_DIR)
TIMESTAMP_FILE="${SCRIPT_DIR}/timestamp.json"
LAST_ERROR_FILE="${SCRIPT_DIR}/lasterror.json" # File for last error timestamp
CHART_FILE="${SCRIPT_DIR}/chart.csv"         # CSV file for chart data history

# --- Chart Data Logging Interval ---
# Log data to chart.csv only if at least this many seconds have passed since the last log for that sensor.
# 1 minute = 60 seconds
LOG_INTERVAL_SECONDS=60
# Max history duration for charts (24 hours in seconds)
MAX_HISTORY_SECONDS=$((24 * 60 * 60))

# --- Check for jq (JSON processor) and awk ---
if ! command -v jq &> /dev/null
then
    echo "jq is not installed. Please install it using: sudo apt update && sudo apt install jq"
    echo "Exiting script."
    exit 1
fi
if ! command -v awk &> /dev/null
then
    echo "awk is not installed. It is usually pre-installed on Ubuntu. If not, install using: sudo apt update && sudo apt install awk"
    echo "Exiting script."
    exit 1
fi

# --- Get current timestamp in ISO 8601 format (UTC) ---
CURRENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT_UNIX_TIMESTAMP=$(date -u +"%s") # Unix timestamp for calculations

# --- Initialize temporary files for aggregated sensor readings and JSON data structures ---
# This file will accumulate all 'ch_soil' entries from all successfully fetched data-N.json files.
ALL_SENSOR_READINGS_TEMP=$(mktemp "${SCRIPT_DIR}/all_sensors_XXXXXX.json")
# This JSON string will be built up to contain status for each hub for timestamp.json
HUB_STATUSES_JSON="{}"
# Read existing last error data, or initialize as empty object if file doesn't exist or is invalid
LAST_ERRORS_JSON=$(cat "${LAST_ERROR_FILE}" 2>/dev/null || echo '{}')
if ! echo "${LAST_ERRORS_JSON}" | jq '.' &> /dev/null; then
    echo "Warning: ${LAST_ERROR_FILE} is invalid or empty, re-initializing."
    LAST_ERRORS_JSON='{}'
fi

# --- Loop through sensor hubs (1 to 4) ---
for i in {1..4}; do
    # Dynamically get the URL variable name (e.g., DATA_URL_1)
    CURRENT_DATA_URL_VAR="DATA_URL_${i}"
    # Construct the data file name for this hub (e.g., data-1.json)
    CURRENT_DATA_FILE_NAME="data-${i}.json"
    # Construct the full path to the data file for this hub
    CURRENT_DATA_FILE_PATH="${SCRIPT_DIR}/${CURRENT_DATA_FILE_NAME}"

    # Check if the URL variable for this hub is set and not empty
    # The :- operator provides a default empty string if the variable is unset, preventing unbound variable errors.
    if [ -z "${!CURRENT_DATA_URL_VAR:-}" ]; then
        echo "DATA_URL_${i} is not set or empty. Skipping hub ${i}."
        # Add a "skipped" status for this hub to the JSON structure for timestamp.json
        HUB_STATUSES_JSON=$(echo "${HUB_STATUSES_JSON}" | jq \
            --arg file_name "${CURRENT_DATA_FILE_NAME}" \
            --arg current_ts "${CURRENT_TIMESTAMP}" \
            '. + { ($file_name): {status: "skipped", message: "URL not configured", last_fetch: $current_ts} }'
        )
        continue # Move to the next hub in the loop
    fi
    # Get the actual URL value using indirect expansion
    CURRENT_DATA_URL="${!CURRENT_DATA_URL_VAR}"

    echo "Fetching live data for hub ${i} from ${CURRENT_DATA_URL}..."
    curl -s -o "${CURRENT_DATA_FILE_PATH}" "${CURRENT_DATA_URL}"
    CURL_STATUS=$? # Get the exit status of the curl command

    FETCH_STATUS="success"
    ERROR_MESSAGE=""
    HUB_DATA_FETCHED_SUCCESSFULLY=false

    # Check for curl errors first
    if [ "${CURL_STATUS}" -ne 0 ]; then
        FETCH_STATUS="error"
        ERROR_MESSAGE="Failed to fetch data. Curl exited with status: ${CURL_STATUS}. Check URL and network connectivity."
        echo "Error: ${ERROR_MESSAGE}"
    elif [ ! -s "${CURRENT_DATA_FILE_PATH}" ]; then # Check if fetched file is empty (even if curl succeeded)
        FETCH_STATUS="error"
        ERROR_MESSAGE="Fetched ${CURRENT_DATA_FILE_NAME} is empty or invalid. Check the URL content."
        echo "Error: ${ERROR_MESSAGE}"
    else
        # Verify if data.json is valid JSON and contains ch_soil array
        if ! jq -e '.ch_soil | arrays' "${CURRENT_DATA_FILE_PATH}" &> /dev/null; then
            FETCH_STATUS="error"
            ERROR_MESSAGE="Fetched ${CURRENT_DATA_FILE_NAME} is not valid JSON or missing 'ch_soil' array."
            echo "Error: ${ERROR_MESSAGE}"
        else
            HUB_DATA_FETCHED_SUCCESSFULLY=true
            # If data is valid, append its 'ch_soil' entries to the aggregated temporary file
            # Use -c for compact output, each sensor on a new line
            jq -c '.ch_soil[]' "${CURRENT_DATA_FILE_PATH}" >> "${ALL_SENSOR_READINGS_TEMP}"
        fi
    fi

    # Update the JSON string that will be used to create timestamp.json
    HUB_STATUSES_JSON=$(echo "${HUB_STATUSES_JSON}" | jq \
        --arg file_name "${CURRENT_DATA_FILE_NAME}" \
        --arg status "${FETCH_STATUS}" \
        --arg msg "${ERROR_MESSAGE}" \
        --arg current_ts "${CURRENT_TIMESTAMP}" \
        '. + { ($file_name): {status: $status, message: $msg, last_fetch: $current_ts} }'
    )

    # Update the JSON string that will be used to create lasterror.json
    if [ "${FETCH_STATUS}" = "error" ]; then
        LAST_ERRORS_JSON=$(echo "${LAST_ERRORS_JSON}" | jq \
            --arg file_name "${CURRENT_DATA_FILE_NAME}" \
            --arg current_ts "${CURRENT_TIMESTAMP}" \
            '. + { ($file_name): $current_ts }'
        )
    else
        # If the current fetch was successful, remove any previous error entry for this file
        LAST_ERRORS_JSON=$(echo "${LAST_ERRORS_JSON}" | jq \
            --arg file_name "${CURRENT_DATA_FILE_NAME}" \
            'del(.[$file_name])'
        )
    fi
done

# Re-enable set -e after curl commands and JSON processing
set -e

# --- Create the consolidated timestamp.json file ---
echo "Creating ${TIMESTAMP_FILE}..."
jq -n \
    --arg overall_ts "${CURRENT_TIMESTAMP}" \
    --argjson hubs_data "${HUB_STATUSES_JSON}" \
    '{ "overall_timestamp": $overall_ts, "hubs": $hubs_data }' > "${TIMESTAMP_FILE}"

# --- Update the consolidated lasterror.json file ---
echo "Updating ${LAST_ERROR_FILE}..."
echo "${LAST_ERRORS_JSON}" > "${LAST_ERROR_FILE}"

# --- Update chart.csv with new data (only if any valid sensor data was collected) ---
# Check if the temporary file containing aggregated sensor readings has content
if [ -s "${ALL_SENSOR_READINGS_TEMP}" ]; then
    echo "Updating ${CHART_FILE}..."

    # Bug fix: The header must be updated to use the 'channel_id' instead of 'name'
    if [ ! -f "${CHART_FILE}" ] || [ ! -s "${CHART_FILE}" ]; then
        echo "timestamp,channel_id,humidity" > "${CHART_FILE}"
        echo "Created new ${CHART_FILE} with header."
    fi

    # Read existing valid data from chart.csv, filter out old data, and store in a temporary file
    TEMP_CHART_DATA=$(mktemp "${SCRIPT_DIR}/chart_temp_XXXXXX.csv")
    {
        head -n 1 "${CHART_FILE}" # Keep the header
        # Use awk to filter out old data. NR > 0 ensures it processes all lines after header.
        tail -n +2 "${CHART_FILE}" | awk -v current_ts="${CURRENT_UNIX_TIMESTAMP}" -v max_history_sec="${MAX_HISTORY_SECONDS}" '
            BEGIN { FS=","; OFS="," }
            {
                # Convert ISO 8601 timestamp to Unix timestamp for comparison
                # This requires GNU date for `date -d` in awk.
                cmd = "date -d \"" $1 "\" +%s"
                cmd | getline point_unix_ts
                close(cmd)

                if ((current_ts - point_unix_ts) <= max_history_sec) {
                    print $0
                }
            }
        '
    } > "${TEMP_CHART_DATA}"

    # Get the last logged timestamp for each sensor from the *current* data (excluding header)
    declare -A LAST_LOGGED_TIMES
    LAST_LOGS_TEMP=$(mktemp "${SCRIPT_DIR}/last_logs_temp_XXXXXX.txt")
    tail -n +2 "${TEMP_CHART_DATA}" | awk -F',' '{
        # Convert ISO 8601 to Unix timestamp using GNU date
        cmd = "date -d \"" $1 "\" +%s"
        cmd | getline point_unix_ts
        close(cmd)

        # Bug fix: Use the channel ID ($2) for the key instead of the sensor name
        if (!($2 in last_ts) || point_unix_ts > last_ts[$2]) {
            last_ts[$2] = point_unix_ts
        }
    } END {
        for (channel_id in last_ts) {
            print channel_id "," last_ts[channel_id]
        }
    }' > "${LAST_LOGS_TEMP}"

    # Read the last logged times into the associative array in the main shell
    while IFS=, read -r channel_id last_ts; do
        LAST_LOGGED_TIMES[${channel_id}]=${last_ts}
    done < "${LAST_LOGS_TEMP}"
    rm "${LAST_LOGS_TEMP}" # Clean up temporary file for last logs

    # Process each sensor reading from the aggregated temporary JSON file
    # This loop now reads from ALL_SENSOR_READINGS_TEMP, which contains all ch_soil entries from all hubs
    while IFS= read -r sensor_json; do
        # Bug fix: Extract 'channel' instead of 'name'
        CHANNEL_ID=$(echo "${sensor_json}" | jq -r '.channel')
        HUMIDITY=$(echo "${sensor_json}" | jq -r '.humidity' | sed 's/%//') # Remove '%' if present

        # Skip if name or humidity is null/empty or not a number
        if [ -z "${CHANNEL_ID}" ] || [ -z "${HUMIDITY}" ] || ! [[ "${HUMIDITY}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "Skipping invalid sensor reading: ${sensor_json}"
            continue
        fi

        # Get last logged Unix timestamp for this sensor. Default to 0 if no entry exists.
        LAST_LOG_UNIX_TIME=${LAST_LOGGED_TIMES[${CHANNEL_ID}]:-0}

        # Check if enough time has passed since the last log for this sensor
        if (( CURRENT_UNIX_TIMESTAMP - LAST_LOG_UNIX_TIME >= LOG_INTERVAL_SECONDS )); then
            echo "${CURRENT_TIMESTAMP},${CHANNEL_ID},${HUMIDITY}" >> "${TEMP_CHART_DATA}"
            echo "Logged new data for channel ${CHANNEL_ID} to ${CHART_FILE}."
        else
            echo "Skipping logging for channel ${CHANNEL_ID}: Not enough time passed since last log."
        fi
    done < "${ALL_SENSOR_READINGS_TEMP}" # Read from aggregated temp file

    # Sort the data by timestamp (excluding header) and rewrite chart.csv
    (head -n 1 "${TEMP_CHART_DATA}"; tail -n +2 "${TEMP_CHART_DATA}" | sort -t',' -k1) > "${CHART_FILE}"
    rm "${TEMP_CHART_DATA}" # Clean up temporary file for chart data
    echo "Updated and sorted ${CHART_FILE}."
else
    echo "No valid sensor data fetched from any configured hub. Skipping ${CHART_FILE} update."
fi

# Clean up the aggregated sensor readings temporary file
rm -f "${ALL_SENSOR_READINGS_TEMP}"

echo "Script execution complete."
echo "Data saved to ${SCRIPT_DIR}/data-N.json files (if configured)."
echo "Timestamp and status saved to ${TIMESTAMP_FILE}"
echo "Last error timestamp (if any) saved to ${LAST_ERROR_FILE}"
echo "Chart history (if updated) saved to ${CHART_FILE}"

# Exit with a status indicating overall success or failure of the data fetch.
# The script will exit with status 0 if everything succeeded, or 1 if any command failed due to set -e.
exit 0
