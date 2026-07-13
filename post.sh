#!/usr/bin/env bash

set -euo pipefail

# URL of your Mastodon server, without a trailing slash
MASTODON_SERVER="{{MASTODON_SERVER}}"

# Your Mastodon account's access token
MASTODON_TOKEN="{{MASTODON_TOKEN}}"

# CDC wastewater dataset (Socrata dataset ID) and the SODA query endpoint.
BASE="https://data.cdc.gov/resource/atcp-73re.json"
PATHOGEN="SARS-CoV-2"

# For scheduled/automated use, register a free Socrata app token and uncomment
# the two lines below to avoid anonymous per-IP rate limiting.
# APP_TOKEN="your_token_here"
# AUTH=(-H "X-App-Token: ${APP_TOKEN}")
AUTH=()

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

# 1. Most recent week_end that has COVID data. Do not hard-code a date.
WEEK=$(curl -sfG ${AUTH[@]+"${AUTH[@]}"} "$BASE" \
    --data-urlencode "\$select=max(week_end) as latest" \
    --data-urlencode "\$where=pathogen_target='${PATHOGEN}'" \
    | jq -r '.[0].latest') || exit_error "Error: Failed to query latest week from $BASE."

if [[ -z "$WEEK" || "$WEEK" == "null" ]]; then
    exit_error "Error: could not determine latest week_end."
elif [[ $(date -d "$WEEK" +%s) -lt $(date -d "10 days ago" +%s) ]]; then
    exit_error "Error: latest week_end ($WEEK) is more than 10 days old."
fi
WEEK_TEXT="For the week ending %s\n\n" "$WEEK"

# 2. All site rows for that pathogen + week. $limit must exceed the ~750 rows/week.
json_data=$(curl -sfG ${AUTH[@]+"${AUTH[@]}"} "$BASE" \
    --data-urlencode "\$where=pathogen_target='${PATHOGEN}' AND week_end='${WEEK}'" \
    --data-urlencode "\$select=state_territory,site,site_wval" \
    --data-urlencode "\$limit=50000") || exit_error "Error: Failed to fetch site data from $BASE."

# Check if the data is non-empty
if [[ -z "$json_data" ]]; then
    exit_error "Error: No JSON retrieved from $BASE."
fi

# Check if the data is valid JSON
echo "$json_data" | jq empty > /dev/null 2>&1 || exit_error "Error: The data from $BASE is not valid JSON."

# Custom order for the activity level labels (low to high)
order='["No data", "Very Low", "Low", "Moderate", "High", "Very High"]'

# Map full state/territory names to postal abbreviations. Unknown names fall
# through to the full name so nothing is silently dropped.
abbr='{
    "Alabama":"AL","Alaska":"AK","Arizona":"AZ","Arkansas":"AR","California":"CA",
    "Colorado":"CO","Connecticut":"CT","Delaware":"DE","District of Columbia":"DC",
    "Florida":"FL","Georgia":"GA","Hawaii":"HI","Idaho":"ID","Illinois":"IL",
    "Indiana":"IN","Iowa":"IA","Kansas":"KS","Kentucky":"KY","Louisiana":"LA",
    "Maine":"ME","Maryland":"MD","Massachusetts":"MA","Michigan":"MI","Minnesota":"MN",
    "Mississippi":"MS","Missouri":"MO","Montana":"MT","Nebraska":"NE","Nevada":"NV",
    "New Hampshire":"NH","New Jersey":"NJ","New Mexico":"NM","New York":"NY",
    "North Carolina":"NC","North Dakota":"ND","Ohio":"OH","Oklahoma":"OK","Oregon":"OR",
    "Pennsylvania":"PA","Rhode Island":"RI","South Carolina":"SC","South Dakota":"SD",
    "Tennessee":"TN","Texas":"TX","Utah":"UT","Vermont":"VT","Virginia":"VA",
    "Washington":"WA","West Virginia":"WV","Wisconsin":"WI","Wyoming":"WY",
    "Puerto Rico":"PR","Guam":"GU","U.S. Virgin Islands":"VI","Virgin Islands":"VI",
    "American Samoa":"AS","Northern Mariana Islands":"MP",
    "Commonwealth of the Northern Mariana Islands":"MP"
}'

# Derive the state-level category from the site-level data, group states by
# category, and format one line per category listing the state abbreviations.
#   - drop null site_wval, dedupe to one value per site, take the state median
#   - bucket the median into a category using CDC's COVID-19 thresholds
POST_TEXT=$(echo "$json_data" | jq -r --argjson order "$order" --argjson abbr "$abbr" '
    def median:
        sort
        | if   length == 0     then null
          elif length % 2 == 1 then .[(length/2)|floor]
          else (.[length/2-1] + .[length/2]) / 2 end;
    def bucket:
        if   . == null then "No data"
        elif . <= 2    then "Very Low"
        elif . <= 3.4  then "Low"
        elif . <= 5.3  then "Moderate"
        elif . <= 7.8  then "High"
        else                "Very High" end;

    map(select(.site_wval != null)
        | {state: .state_territory, site: .site, wval: (.site_wval|tonumber)})
    | group_by(.state)
    | map( (group_by(.site) | map(.[0].wval)) as $v          # dedupe: one value per site
           | {level: ($v|median|bucket), abbr: ($abbr[.[0].state] // .[0].state)} )
    | group_by(.level)
    | sort_by(.[0].level as $l | $order | index($l))
    | map( "\(.[0].level): \([.[].abbr] | sort | join(", "))" )
    | join("\n\n")')

# Print the output
echo "$POST_TEXT"

# Make sure some states are present
if [[ "$POST_TEXT" != *"CA"* || "$POST_TEXT" != *"NY"* ]]; then
    exit_error "Formatted output is missing states (at least CA and NY)"
fi

# Add WEEK_TEXT before POST_TEXT
POST_TEXT="${WEEK_TEXT}${POST_TEXT}"

# Post to Mastodon
curl "$MASTODON_SERVER"/api/v1/statuses -H "Authorization: Bearer ${MASTODON_TOKEN}" --data "status=${POST_TEXT}"

RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    exit_error "Posting message to Mastodon failed."
fi

echo "Message successfully posted to Mastodon."
