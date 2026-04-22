#!/bin/bash
# AUTHOR: Tial Streinard 
# This script fetches recent kills from a provided system,
# filters out NPC kills, 
# extracts attacker (final blow) IDs and timestamps,
# fetches character names and produces a CSV file for further analysis

SYSTEM_ID="30002768" # <-- CHANGE THIS TO TARGET SYSTEM

# ===== STEP 1: Fetch kills =====
echo "Fetching system name for system ID $SYSTEM_ID..."
SYSTEM_NAME=$(curl -s "https://esi.evetech.net/latest/universe/systems/$SYSTEM_ID/" | jq -r '.name')

if [ -z "$SYSTEM_NAME" ]; then
    echo "Error: Could not fetch system name. Exiting."
    exit 1
fi

echo "System name: $SYSTEM_NAME"

# Create directory named after the system
mkdir -p "$SYSTEM_NAME"

# Define file paths to system directory
STEP1_OUTPUT="$SYSTEM_NAME/${SYSTEM_NAME}_step1_raw_kills.json"
STEP2_OUTPUT="$SYSTEM_NAME/${SYSTEM_NAME}_step2_filtered_kills.json"
STEP3_OUTPUT="$SYSTEM_NAME/${SYSTEM_NAME}_step3_ids_timestamps.json"
STEP3_TEMP="$SYSTEM_NAME/${SYSTEM_NAME}_step3_temp_killdata.json"
STEP4_OUTPUT="$SYSTEM_NAME/${SYSTEM_NAME}_step4_character_kills.csv"

echo "Fetching all kills from system $SYSTEM_ID..."
curl -s "https://zkillboard.com/api/systemID/$SYSTEM_ID/kills/" > "$STEP1_OUTPUT"

echo "Raw kills saved to $STEP1_OUTPUT"
echo "Total entries: $(jq 'length' "$STEP1_OUTPUT")"

# ===== STEP 2: Filter GANKER kills =====
echo "Filtering GANKER kills..."

# Filter kills where npc is false and label 'ganked' is present
# save to new file
jq '[.[] | select(.zkb.npc == false and (.zkb.labels | any(. == "ganked")))]' "$STEP1_OUTPUT" > "$STEP2_OUTPUT"

# Count GANKER kills
COUNT=$(jq 'length' "$STEP2_OUTPUT")
echo "GANKER kills found: $COUNT"
echo "Filtered kills saved to $STEP2_OUTPUT"

# ===== STEP 3: Fetch attacker IDs and timestamps =====
echo "Fetching full killmail data from ESI API..."

# Clear temp file if it exists
> "$STEP3_TEMP"

# Iterate through each kill
jq -r '.[] | "\(.killmail_id),\(.zkb.hash)"' "$STEP2_OUTPUT" | while IFS=',' read -r killmail_id hash; do
    echo "Fetching killmail $killmail_id..."
    
    # Fetch from ESI API
    killmail_data=$(curl -s "https://esi.evetech.net/latest/killmails/$killmail_id/$hash/")
    
    # Extract killmail_time and all attacker character IDs into a temporary file
    # Each attacker becomes an object: {killmail_time, character_id}
    echo "$killmail_data" | jq -c '.killmail_time as $kt | .attackers[] | {killmail_time: $kt, character_id}' >> "$STEP3_TEMP"
    
    # Small delay to avoid rate limiting
    sleep 0.1
done

# Convert the line-separated JSON objects into a proper JSON array
jq -s '.' "$STEP3_TEMP" > "$STEP3_OUTPUT"
rm $STEP3_TEMP

echo "Character IDs and timestamps extracted and saved to $STEP3_OUTPUT"
echo "Total attacker entries: $(jq 'length' "$STEP3_OUTPUT")"

# ===== STEP 4: Fetch character names =====
echo ""
echo "Processing character IDs..."

# Extract character_id and killmail_time, filter nulls
char_id_time_data=$(jq -r '.[] | select(.character_id != null) | "\(.character_id),\(.killmail_time)"' "$STEP3_OUTPUT")

echo "Fetching character names from ESI API..."

# Output CSV header
echo "character_id,name,killmail_time" > "$STEP4_OUTPUT"

# Iterate through each kill
echo "$char_id_time_data" | while IFS=',' read -r char_id kill_time; do
    
    # Skip empty lines
    if [ -z "$char_id" ] || [ "$char_id" = "null" ]; then
        continue
    fi
    
    echo "Fetching name for character ID: $char_id..."
    
    # Fetch character data from ESI
    char_api_data=$(curl -s "https://esi.evetech.net/latest/characters/$char_id/")
    char_name=$(echo "$char_api_data" | jq -r '.name')
    
    echo "  Name: $char_name"
    
    # Output one row per kill with character_id, name, and killmail_time
    echo "$char_id,$char_name,$kill_time" >> "$STEP4_OUTPUT"
    
    # Small delay to avoid rate limiting
    sleep 0.1
done

echo ""
echo "=== RESULTS SAVED TO $STEP4_OUTPUT ==="
echo ""
echo "=== SAMPLE DATA ==="
head -20 "$STEP4_OUTPUT" | column -t -s ','
