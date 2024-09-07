#!/usr/bin/env bash

set -euo pipefail

# URL of your Mastodon server, without a trailing slash
MASTODON_SERVER="{{MASTODON_SERVER}}"

# Your Mastodon account's access token
MASTODON_TOKEN="{{MASTODON_TOKEN}}"

# The Covid wastewater source JSON
JSON_URL="https://www.cdc.gov/wcms/vizdata/NCEZID_DIDRI/NWSSStateMap.json"

# Function to handle errors
exit_error() {
    echo "$1" >&2
    exit 1
}

# Ensure necessary environment variables are set
[ "$MASTODON_SERVER" != "{{MASTODON_SERVER}}" ] || exit_error "Error: MASTODON_SERVER is not set."
[ "$MASTODON_TOKEN" != "{{MASTODON_TOKEN}}" ] || exit_error "Error: MASTODON_TOKEN is not set."

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit_error "Error: Directory ."

# Fetch CDC JSON
json_data=$(curl --silent "$JSON_URL")

# Check if curl command was successful
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to fetch JSON from $JSON_URL."
    exit 1
fi

# Check if the data is non-empty
if [[ -z "$json_data" ]]; then
    echo "Error: No JSON retrieved from the $JSON_URL."
    exit 1
fi

# Check if the data is valid JSON
echo "$json_data" | jq empty > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
    echo "Error: The data at $JSON_URL is not valid JSON."
    exit 1
fi

# Custom order for the activity level labels
order='["No Data", "Minimal", "Low", "Moderate", "High", "Very High"]'

# Extract useful data from the JSON, grouping the data by activity level, listing the states for
# each
POST_TEXT=$(echo "$json_data" | jq -r --argjson order "$order" '
    group_by(.activity_level_label) | 
    sort_by([.[0].activity_level_label] | index($order[])) | 
    .[] | 
    {
        activity_level_label: .[0].activity_level_label, 
        states: [.[] | .state_abbrev] | sort
    } | 
    "\( .activity_level_label ): \( .states | join(", ") )\n"')

# Print the output
echo "$POST_TEXT"

# Post to Mastodon
curl "$MASTODON_SERVER"/api/v1/statuses -H "Authorization: Bearer ${MASTODON_TOKEN}" --data "media_ids[]=${MEDIA_ID}" --data "status=${POST_TEXT}"

RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    exit_error "Posting message to Mastodon failed."
fi

echo "Message successfully posted to Mastodon."
