#!/bin/bash

# Drupal Content Analysis Report Generator
# Runs analysis queries against a local DDEV database and generates a markdown report
# See docs/background.md for rationale and query details

set -e

# Parse command line arguments
SITE_NAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --site=*)
            SITE_NAME="${1#*=}"
            shift
            ;;
        --site)
            SITE_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--site=SITENAME]"
            exit 1
            ;;
    esac
done

# Configuration
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Determine the script's directory to find the reports folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENT_ANALYSIS_DIR="$(dirname "$SCRIPT_DIR")"
REPORTS_DIR="${CONTENT_ANALYSIS_DIR}/reports"

# Create output directory in reports folder
if [ -n "$SITE_NAME" ]; then
    OUTPUT_DIR="${REPORTS_DIR}/content-analysis-report-${SITE_NAME}-${TIMESTAMP}"
else
    OUTPUT_DIR="${REPORTS_DIR}/content-analysis-report-${TIMESTAMP}"
fi
DATA_DIR="$OUTPUT_DIR"
REPORT_FILE="${OUTPUT_DIR}/content-analysis-report.md"
DAYS_RECENT=90
DAYS_EDITOR_ACTIVITY=180
HIGH_REVISION_THRESHOLD=5
HIGH_REVISION_LIMIT=50
RECENT_CONTENT_LIMIT=50
PARAGRAPH_LIST_LIMIT=500
BLOCK_LIST_LIMIT=100
TAXONOMY_LIST_LIMIT=200
MEDIA_LIST_LIMIT=100

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function to run SQL and return results
run_query() {
    ddev drush sql-query "$1" 2>/dev/null
}

# Helper function to format query results as markdown table
format_as_table() {
    local input="$1"
    local header="$2"

    if [ -z "$input" ]; then
        echo "*No data found*"
        return
    fi

    # Print header
    echo "$header"

    # Print separator (count columns from header)
    local col_count=$(echo "$header" | tr '|' '\n' | grep -c '[^[:space:]]')
    local separator="|"
    for ((i=1; i<=col_count; i++)); do
        separator="$separator --- |"
    done
    echo "$separator"

    # Print data rows
    echo "$input" | while IFS=$'\t' read -r line; do
        # Convert tab-separated to pipe-separated
        echo "| $(echo "$line" | sed 's/\t/ | /g') |"
    done
}

# Helper function to save query results as CSV
save_as_csv() {
    local input="$1"
    local header="$2"
    local filename="$3"

    local filepath="${DATA_DIR}/${filename}"

    # Write header row
    echo "$header" > "$filepath"

    # Write data rows with proper CSV quoting for fields containing commas or quotes
    if [ -n "$input" ]; then
        echo "$input" | while IFS=$'\t' read -r line; do
            # Process each tab-separated field
            local csv_line=""
            local first=true
            # Use a different approach to split by tab
            while IFS= read -r -d $'\t' field || [ -n "$field" ]; do
                # Add comma separator (except for first field)
                if [ "$first" = true ]; then
                    first=false
                else
                    csv_line+=","
                fi
                # If field contains comma, quote, or newline, wrap in quotes and escape internal quotes
                if [[ "$field" == *","* ]] || [[ "$field" == *'"'* ]] || [[ "$field" == *$'\n'* ]]; then
                    # Escape any existing quotes by doubling them
                    field="${field//\"/\"\"}"
                    csv_line+="\"${field}\""
                else
                    csv_line+="$field"
                fi
            done <<< "$line"$'\t'
            echo "$csv_line"
        done >> "$filepath"
    fi

    echo -e "${GREEN}    -> Saved: ${filepath}${NC}"
}

# Check if we're in a DDEV project
check_ddev() {
    if ! ddev describe > /dev/null 2>&1; then
        echo -e "${RED}Error: Not in a DDEV project directory or DDEV is not running.${NC}"
        echo "Please run this script from your DDEV project root and ensure DDEV is started."
        exit 1
    fi
    echo -e "${GREEN}[OK] DDEV project detected${NC}"
}

# Helper function to create an index if it doesn't exist
create_index_if_missing() {
    local table="$1"
    local index_name="$2"
    local columns="$3"

    local existing=$(run_query "SHOW INDEX FROM ${table} WHERE Key_name = '${index_name}';")
    if [ -z "$existing" ]; then
        echo "  Creating index ${index_name} on ${table}(${columns})..."
        run_query "CREATE INDEX ${index_name} ON ${table}(${columns});" || true
        return 0
    fi
    return 1
}

# Check/create indexes for performance
ensure_indexes() {
    echo -e "${YELLOW}Checking performance indexes...${NC}"
    local indexes_created=0

    # --- cms_content_sync_entity_status indexes ---
    local table_exists=$(run_query "SHOW TABLES LIKE 'cms_content_sync_entity_status';")
    if [ -z "$table_exists" ]; then
        echo -e "${YELLOW}  Note: cms_content_sync_entity_status table not found. Content Sync queries will be skipped.${NC}"
        CONTENT_SYNC_AVAILABLE=false
    else
        CONTENT_SYNC_AVAILABLE=true
        create_index_if_missing "cms_content_sync_entity_status" "idx_last_import" "last_import" && ((indexes_created++))
        create_index_if_missing "cms_content_sync_entity_status" "idx_sync_lookup" "entity_type, entity__target_id, last_import" && ((indexes_created++))
    fi

    # --- node_field_data indexes ---
    # Helps: Content Type Activity, Editor Activity, Recently Edited queries
    create_index_if_missing "node_field_data" "idx_analysis_changed" "changed" && ((indexes_created++))
    create_index_if_missing "node_field_data" "idx_analysis_type_changed" "type, changed" && ((indexes_created++))
    create_index_if_missing "node_field_data" "idx_analysis_uid_changed" "uid, changed" && ((indexes_created++))

    # --- node_revision indexes ---
    # Helps: High-Revision Content query (JOIN + GROUP BY + COUNT)
    # Note: Drupal may already have an index on nid, but this ensures it
    create_index_if_missing "node_revision" "idx_analysis_nid" "nid" && ((indexes_created++))

    # --- paragraphs_item_field_data indexes ---
    table_exists=$(run_query "SHOW TABLES LIKE 'paragraphs_item_field_data';")
    if [ -n "$table_exists" ]; then
        # Helps: Paragraph Content List query (JOIN on parent_type, parent_id)
        create_index_if_missing "paragraphs_item_field_data" "idx_analysis_parent" "parent_type, parent_id" && ((indexes_created++))
    fi

    # --- block_content_field_data indexes ---
    table_exists=$(run_query "SHOW TABLES LIKE 'block_content_field_data';")
    if [ -n "$table_exists" ]; then
        # Helps: Block Content List query (ORDER BY changed)
        create_index_if_missing "block_content_field_data" "idx_analysis_changed" "changed" && ((indexes_created++))
    fi

    # --- taxonomy_term_field_data indexes ---
    table_exists=$(run_query "SHOW TABLES LIKE 'taxonomy_term_field_data';")
    if [ -n "$table_exists" ]; then
        # Helps: Taxonomy Term List query (ORDER BY changed)
        create_index_if_missing "taxonomy_term_field_data" "idx_analysis_changed" "changed" && ((indexes_created++))
    fi

    # --- media_field_data indexes ---
    table_exists=$(run_query "SHOW TABLES LIKE 'media_field_data';")
    if [ -n "$table_exists" ]; then
        # Helps: Media Content List query (ORDER BY changed)
        create_index_if_missing "media_field_data" "idx_analysis_changed" "changed" && ((indexes_created++))
    fi

    if [ $indexes_created -gt 0 ]; then
        echo -e "${GREEN}[OK] Created ${indexes_created} new index(es)${NC}"
    else
        echo -e "${GREEN}[OK] All indexes already exist${NC}"
    fi
}

# Start report
start_report() {
    # Create output directory for report and CSV exports
    mkdir -p "$OUTPUT_DIR"
    echo -e "${GREEN}[OK] Output directory created: $OUTPUT_DIR${NC}"

    # Determine site name for report
    local report_site_name
    if [ -n "$SITE_NAME" ]; then
        report_site_name="$SITE_NAME"
    else
        report_site_name=$(ddev describe -j | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    cat > "$REPORT_FILE" << EOF
# Drupal Content Analysis Report

**Generated:** $(date '+%Y-%m-%d %H:%M:%S')
**Site:** ${report_site_name}
**Analysis Period:** Last ${DAYS_RECENT} days (content activity), Last ${DAYS_EDITOR_ACTIVITY} days (editor activity)

---

## Executive Summary

This report analyzes production content patterns to inform test prioritization. It identifies:
- Which content types see the most editing activity
- Content sync patterns (local vs syndicated)
- Editor workflows and activity
- Potential pain points (high-revision content)
- Paragraph/component usage

---

EOF
    echo -e "${GREEN}[OK] Report initialized${NC}"
}

# Query 1: Content Type Activity
query_content_type_activity() {
    echo "Running: Content Type Activity..."

    local results=$(run_query "SELECT
        n.type,
        COUNT(*) as total_nodes,
        COUNT(CASE WHEN n.changed > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL ${DAYS_RECENT} DAY)) THEN 1 END) as edited_last_${DAYS_RECENT}_days,
        COUNT(CASE WHEN n.created > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL ${DAYS_RECENT} DAY)) THEN 1 END) as created_last_${DAYS_RECENT}_days
    FROM node_field_data n
    GROUP BY n.type
    ORDER BY edited_last_${DAYS_RECENT}_days DESC;")

    cat >> "$REPORT_FILE" << EOF
## Content Type Activity

Which content types see the most editing activity? This helps prioritize which workflows to test first.

EOF

    format_as_table "$results" "| Content Type | Total Nodes | Edited (${DAYS_RECENT}d) | Created (${DAYS_RECENT}d) |" >> "$REPORT_FILE"
    save_as_csv "$results" "type,total_nodes,edited_last_${DAYS_RECENT}_days,created_last_${DAYS_RECENT}_days" "content-type-activity.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Content Type Activity${NC}"
}

# Query 2: Content Type Activity (Excluding Content Sync)
query_content_type_activity_no_sync() {
    if [ "$CONTENT_SYNC_AVAILABLE" != "true" ]; then
        echo "Skipping: Content Type Activity (excluding sync) - Content Sync not available"
        return
    fi

    echo "Running: Content Type Activity (excluding Content Sync imports)..."

    local results=$(run_query "SELECT
        n.type,
        COUNT(*) as total_nodes,
        COUNT(CASE WHEN n.changed > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL ${DAYS_RECENT} DAY)) THEN 1 END) as edited_last_${DAYS_RECENT}_days,
        COUNT(CASE WHEN n.created > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL ${DAYS_RECENT} DAY)) THEN 1 END) as created_last_${DAYS_RECENT}_days
    FROM node_field_data n
    LEFT JOIN cms_content_sync_entity_status s ON n.nid = s.entity__target_id AND s.entity_type = 'node'
    WHERE s.last_import IS NULL OR s.last_import < n.changed
    GROUP BY n.type
    ORDER BY edited_last_${DAYS_RECENT}_days DESC;")

    cat >> "$REPORT_FILE" << EOF

## Content Type Activity (Excluding Content Sync Imports)

Same as above, but filters out content that was imported via Content Sync and not locally modified.
This shows what editors are *actually* touching.

EOF

    format_as_table "$results" "| Content Type | Total Nodes | Edited (${DAYS_RECENT}d) | Created (${DAYS_RECENT}d) |" >> "$REPORT_FILE"
    save_as_csv "$results" "type,total_nodes,edited_last_${DAYS_RECENT}_days,created_last_${DAYS_RECENT}_days" "content-type-activity-no-sync.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Content Type Activity (excluding sync)${NC}"
}

# Query 3: Content Sync Status by Type
query_content_sync_status() {
    if [ "$CONTENT_SYNC_AVAILABLE" != "true" ]; then
        echo "Skipping: Content Sync Status - Content Sync not available"
        return
    fi

    echo "Running: Content Sync Status by Type..."

    local results=$(run_query "SELECT
        n.type,
        CASE
            WHEN s.entity__target_id IS NULL THEN 'local_only'
            WHEN s.last_import >= n.changed THEN 'syndicated_unmodified'
            ELSE 'syndicated_locally_modified'
        END as sync_status,
        COUNT(*) as count
    FROM node_field_data n
    LEFT JOIN cms_content_sync_entity_status s ON n.nid = s.entity__target_id AND s.entity_type = 'node'
    GROUP BY n.type, sync_status
    ORDER BY count DESC, n.type, sync_status;")

    cat >> "$REPORT_FILE" << EOF

## Content Sync Status by Type

Distinguishes between locally-created content, syndicated content, and syndicated content that was locally modified.

- **local_only**: Created on this site, not syndicated
- **syndicated_unmodified**: Imported via Content Sync, not edited locally
- **syndicated_locally_modified**: Imported via Content Sync, then edited locally

EOF

    format_as_table "$results" "| Content Type | Sync Status | Count |" >> "$REPORT_FILE"
    save_as_csv "$results" "type,sync_status,count" "content-sync-status.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Content Sync Status${NC}"
}

# Query 4: Synced Node Counts by Type
query_synced_node_counts() {
    if [ "$CONTENT_SYNC_AVAILABLE" != "true" ]; then
        echo "Skipping: Synced Node Counts - Content Sync not available"
        return
    fi

    echo "Running: Synced Node Counts by Type..."

    local results=$(run_query "SELECT
        n.type,
        COUNT(*) as synced_count
    FROM cms_content_sync_entity_status s
    JOIN node_field_data n ON s.entity__target_id = n.nid
    WHERE s.entity_type = 'node'
    GROUP BY n.type
    ORDER BY synced_count DESC;")

    cat >> "$REPORT_FILE" << EOF

## Synced Node Counts by Type

A simpler view: how many nodes of each type came through Content Sync.

EOF

    format_as_table "$results" "| Content Type | Synced Count |" >> "$REPORT_FILE"
    save_as_csv "$results" "type,synced_count" "synced-node-counts.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Synced Node Counts${NC}"
}

# Query 5: Editor Activity Patterns
query_editor_activity() {
    echo "Running: Editor Activity Patterns..."

    local results=$(run_query "SELECT
        COALESCE(NULLIF(u.name, ''), CONCAT('uid:', u.uid)) as user_name,
        n.type,
        COUNT(*) as edits,
        MAX(FROM_UNIXTIME(n.changed)) as last_edit
    FROM node_field_data n
    JOIN users_field_data u ON n.uid = u.uid
    WHERE n.changed > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL ${DAYS_EDITOR_ACTIVITY} DAY))
    GROUP BY u.uid, u.name, n.type
    ORDER BY edits DESC;")

    cat >> "$REPORT_FILE" << EOF

## Editor Activity Patterns

Shows which users are editing which content types. Useful for understanding role-based workflows
and validating against QA Account roles.

*Activity from the last ${DAYS_EDITOR_ACTIVITY} days*

EOF

    format_as_table "$results" "| User | Content Type | Edit Count | Last Edit |" >> "$REPORT_FILE"
    save_as_csv "$results" "user_name,type,edit_count,last_edit" "editor-activity.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Editor Activity Patterns${NC}"
}

# Query 6: High-Revision Content
query_high_revision_content() {
    echo "Running: High-Revision Content..."

    local results=$(run_query "SELECT
        n.nid,
        n.title,
        n.type,
        COUNT(r.vid) as revision_count,
        FROM_UNIXTIME(n.created) as created,
        FROM_UNIXTIME(n.changed) as last_changed,
        CONCAT('/node/', n.nid, '/edit') as edit_url
    FROM node_field_data n
    JOIN node_revision r ON n.nid = r.nid
    GROUP BY n.nid, n.title, n.type, n.created, n.changed
    HAVING revision_count > ${HIGH_REVISION_THRESHOLD}
    ORDER BY revision_count DESC
    LIMIT ${HIGH_REVISION_LIMIT};")

    cat >> "$REPORT_FILE" << EOF

## High-Revision Content (Potential Pain Points)

Content with many revisions may indicate editing friction or complex workflows worth investigating.
Showing content with more than ${HIGH_REVISION_THRESHOLD} revisions (top ${HIGH_REVISION_LIMIT}).

EOF

    format_as_table "$results" "| NID | Title | Type | Revisions | Created | Last Changed | Edit URL |" >> "$REPORT_FILE"
    save_as_csv "$results" "nid,title,type,revision_count,created,last_changed,edit_url" "high-revision-content.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] High-Revision Content${NC}"
}

# Query 7: Recently Edited Nodes
query_recent_nodes() {
    echo "Running: Recently Edited Nodes..."

    local results=$(run_query "SELECT
        n.nid,
        n.title,
        n.type,
        FROM_UNIXTIME(n.changed) as last_changed,
        COALESCE(NULLIF(u.name, ''), CONCAT('uid:', u.uid)) as changed_by,
        CONCAT('/node/', n.nid, '/edit') as edit_url
    FROM node_field_data n
    JOIN users_field_data u ON n.uid = u.uid
    ORDER BY n.changed DESC
    LIMIT ${RECENT_CONTENT_LIMIT};")

    cat >> "$REPORT_FILE" << EOF

## Recently Edited Nodes

Most recently edited content across all types (top ${RECENT_CONTENT_LIMIT}).
Useful for understanding current editorial activity.

EOF

    format_as_table "$results" "| NID | Title | Type | Last Changed | Changed By | Edit URL |" >> "$REPORT_FILE"
    save_as_csv "$results" "nid,title,type,last_changed,changed_by,edit_url" "recent-nodes.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Recently Edited Nodes${NC}"
}

# Query 8a: Paragraph Type Summary
query_paragraph_summary() {
    echo "Running: Paragraph Type Summary..."

    # Check if paragraphs table exists
    local table_exists=$(run_query "SHOW TABLES LIKE 'paragraphs_item_field_data';")

    if [ -z "$table_exists" ]; then
        cat >> "$REPORT_FILE" << EOF

## Paragraph Type Summary

*Paragraphs module not detected - skipping this analysis.*

EOF
        echo -e "${YELLOW}Skipping: Paragraph Summary - table not found${NC}"
        PARAGRAPHS_AVAILABLE=false
        return
    fi

    PARAGRAPHS_AVAILABLE=true

    local results=$(run_query "SELECT
        p.type,
        COUNT(*) as usage_count
    FROM paragraphs_item_field_data p
    GROUP BY p.type
    ORDER BY usage_count DESC;")

    cat >> "$REPORT_FILE" << EOF

## Paragraph Type Summary

Shows which paragraph components are most used across the site.
Focus component tests on the most-used paragraph types.

EOF

    format_as_table "$results" "| Paragraph Type | Usage Count |" >> "$REPORT_FILE"
    save_as_csv "$results" "type,usage_count" "paragraph-summary.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Paragraph Type Summary${NC}"
}

# Query 7b: Paragraph Content List
query_paragraph_list() {
    if [ "$PARAGRAPHS_AVAILABLE" != "true" ]; then
        return
    fi

    echo "Running: Paragraph Content List..."

    local results=$(run_query "SELECT
        p.type as paragraph_type,
        n.type as node_type,
        n.nid,
        n.title,
        CONCAT('/node/', n.nid, '/edit') as edit_url
    FROM paragraphs_item_field_data p
    JOIN node_field_data n ON p.parent_id = n.nid AND p.parent_type = 'node'
    ORDER BY p.type, n.type, n.nid
    LIMIT ${PARAGRAPH_LIST_LIMIT};")

    cat >> "$REPORT_FILE" << EOF

## Paragraph Content List

Individual paragraph instances and their parent nodes (top ${PARAGRAPH_LIST_LIMIT}).
Use the edit URL to investigate how specific paragraphs are configured.

EOF

    format_as_table "$results" "| Paragraph Type | Node Type | NID | Title | Edit URL |" >> "$REPORT_FILE"
    save_as_csv "$results" "paragraph_type,node_type,nid,title,edit_url" "paragraph-list.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Paragraph Content List${NC}"
}

# Query 9a: Block Content Type Summary
query_block_summary() {
    echo "Running: Block Content Type Summary..."

    # Check if block_content table exists
    local table_exists=$(run_query "SHOW TABLES LIKE 'block_content_field_data';")

    if [ -z "$table_exists" ]; then
        cat >> "$REPORT_FILE" << EOF

## Block Content Type Summary

*Block Content module not detected - skipping this analysis.*

EOF
        echo -e "${YELLOW}Skipping: Block Content Summary - table not found${NC}"
        BLOCKS_AVAILABLE=false
        return
    fi

    BLOCKS_AVAILABLE=true

    local results=$(run_query "SELECT
        b.type,
        COUNT(*) as usage_count
    FROM block_content_field_data b
    GROUP BY b.type
    ORDER BY usage_count DESC;")

    cat >> "$REPORT_FILE" << EOF

## Block Content Type Summary

Shows which custom block types are used across the site.

EOF

    format_as_table "$results" "| Block Type | Usage Count |" >> "$REPORT_FILE"
    save_as_csv "$results" "type,usage_count" "block-summary.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Block Content Type Summary${NC}"
}

# Query 9b: Block Content List
query_block_list() {
    if [ "$BLOCKS_AVAILABLE" != "true" ]; then
        return
    fi

    echo "Running: Block Content List..."

    local results=$(run_query "SELECT
        b.id,
        b.info as block_description,
        b.type,
        FROM_UNIXTIME(b.changed) as last_changed,
        CONCAT('/admin/content/block/', b.id) as edit_url
    FROM block_content_field_data b
    ORDER BY b.changed DESC
    LIMIT ${BLOCK_LIST_LIMIT};")

    cat >> "$REPORT_FILE" << EOF

## Block Content List

Individual custom blocks (top ${BLOCK_LIST_LIMIT} by most recently changed).

EOF

    format_as_table "$results" "| ID | Description | Type | Last Changed | Edit URL |" >> "$REPORT_FILE"
    save_as_csv "$results" "id,block_description,type,last_changed,edit_url" "block-list.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Block Content List${NC}"
}

# Query 10a: Taxonomy Vocabulary Summary
query_taxonomy_summary() {
    echo "Running: Taxonomy Vocabulary Summary..."

    # Check if taxonomy table exists
    local table_exists=$(run_query "SHOW TABLES LIKE 'taxonomy_term_field_data';")

    if [ -z "$table_exists" ]; then
        cat >> "$REPORT_FILE" << EOF

## Taxonomy Vocabulary Summary

*Taxonomy module not detected - skipping this analysis.*

EOF
        echo -e "${YELLOW}Skipping: Taxonomy Summary - table not found${NC}"
        TAXONOMY_AVAILABLE=false
        return
    fi

    TAXONOMY_AVAILABLE=true

    local results=$(run_query "SELECT
        t.vid as vocabulary,
        COUNT(*) as term_count
    FROM taxonomy_term_field_data t
    GROUP BY t.vid
    ORDER BY term_count DESC;")

    cat >> "$REPORT_FILE" << EOF

## Taxonomy Vocabulary Summary

Shows term counts by vocabulary.

EOF

    format_as_table "$results" "| Vocabulary | Term Count |" >> "$REPORT_FILE"
    save_as_csv "$results" "vocabulary,term_count" "taxonomy-summary.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Taxonomy Vocabulary Summary${NC}"
}

# Query 10b: Taxonomy Term List
query_taxonomy_list() {
    if [ "$TAXONOMY_AVAILABLE" != "true" ]; then
        return
    fi

    echo "Running: Taxonomy Term List..."

    local results=$(run_query "SELECT
        t.tid,
        t.name,
        t.vid as vocabulary,
        FROM_UNIXTIME(t.changed) as last_changed,
        CONCAT('/taxonomy/term/', t.tid, '/edit') as edit_url
    FROM taxonomy_term_field_data t
    ORDER BY t.changed DESC
    LIMIT ${TAXONOMY_LIST_LIMIT};")

    cat >> "$REPORT_FILE" << EOF

## Taxonomy Term List

Individual taxonomy terms (top ${TAXONOMY_LIST_LIMIT} by most recently changed).

EOF

    format_as_table "$results" "| TID | Name | Vocabulary | Last Changed | Edit URL |" >> "$REPORT_FILE"
    save_as_csv "$results" "tid,name,vocabulary,last_changed,edit_url" "taxonomy-list.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Taxonomy Term List${NC}"
}

# Query 11a: Media Type Summary
query_media_summary() {
    echo "Running: Media Type Summary..."

    # Check if media table exists
    local table_exists=$(run_query "SHOW TABLES LIKE 'media_field_data';")

    if [ -z "$table_exists" ]; then
        cat >> "$REPORT_FILE" << EOF

## Media Type Summary

*Media module not detected - skipping this analysis.*

EOF
        echo -e "${YELLOW}Skipping: Media Summary - table not found${NC}"
        MEDIA_AVAILABLE=false
        return
    fi

    MEDIA_AVAILABLE=true

    local results=$(run_query "SELECT
        m.bundle as media_type,
        COUNT(*) as usage_count
    FROM media_field_data m
    GROUP BY m.bundle
    ORDER BY usage_count DESC;")

    cat >> "$REPORT_FILE" << EOF

## Media Type Summary

Shows media item counts by type (image, document, video, etc.).

EOF

    format_as_table "$results" "| Media Type | Usage Count |" >> "$REPORT_FILE"
    save_as_csv "$results" "media_type,usage_count" "media-summary.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Media Type Summary${NC}"
}

# Query 11b: Media Content List
query_media_list() {
    if [ "$MEDIA_AVAILABLE" != "true" ]; then
        return
    fi

    echo "Running: Media Content List..."

    local results=$(run_query "SELECT
        m.mid,
        m.name,
        m.bundle as media_type,
        FROM_UNIXTIME(m.changed) as last_changed,
        CONCAT('/media/', m.mid, '/edit') as edit_url
    FROM media_field_data m
    ORDER BY m.changed DESC
    LIMIT ${MEDIA_LIST_LIMIT};")

    cat >> "$REPORT_FILE" << EOF

## Media Content List

Individual media items (top ${MEDIA_LIST_LIMIT} by most recently changed).

EOF

    format_as_table "$results" "| MID | Name | Media Type | Last Changed | Edit URL |" >> "$REPORT_FILE"
    save_as_csv "$results" "mid,name,media_type,last_changed,edit_url" "media-list.csv"

    echo "" >> "$REPORT_FILE"
    echo -e "${GREEN}[OK] Media Content List${NC}"
}

# Add testing implications section
add_testing_implications() {
    cat >> "$REPORT_FILE" << EOF

---

## Mapping Results to Test Priorities

| Finding | Testing Implication |
| --- | --- |
| High edit frequency content types | Prioritize Playwright tests for these workflows |
| Content types with high revision counts | May indicate UX issues; consider edge case testing |
| Locally-modified syndicated content | Test the "edit after sync" workflow |
| Top paragraph types | Focus component tests on these |
| Top block types | Include block editing in test coverage |
| High-traffic taxonomies | Test taxonomy term management workflows |
| Top media types | Test media library and upload workflows |
| Recently edited content | Use edit URLs to verify current editorial patterns |
| Editor patterns by role | Validate against QA Account roles |

---

## Notes

- This analysis uses a **point-in-time snapshot**. For trend analysis, repeat periodically with fresh backups.
- The indexes added locally **do not affect production databases**.
- Results should be cross-referenced with team knowledge about upcoming deprecations or migrations.

## Related Resources

- [Drupal Testing Guide](https://www.drupal.org/docs/testing)
- [Content Moderation](https://www.drupal.org/docs/8/core/modules/content-moderation)
- [Paragraphs Module](https://www.drupal.org/project/paragraphs)
- [CMS Content Sync](https://www.drupal.org/project/cms_content_sync)

EOF
    echo -e "${GREEN}[OK] Testing implications added${NC}"
}

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "  Drupal Content Analysis Report"
    echo "========================================"
    echo ""

    check_ddev
    ensure_indexes
    start_report

    echo ""
    echo "Running analysis queries..."
    echo ""

    query_content_type_activity
    query_content_type_activity_no_sync
    query_content_sync_status
    query_synced_node_counts
    query_editor_activity
    query_high_revision_content
    query_recent_nodes
    query_paragraph_summary
    query_paragraph_list
    query_block_summary
    query_block_list
    query_taxonomy_summary
    query_taxonomy_list
    query_media_summary
    query_media_list
    add_testing_implications

    echo ""
    echo "========================================"
    echo -e "${GREEN}Analysis complete!${NC}"
    echo "========================================"
    echo ""
    echo "Output: $OUTPUT_DIR/"
    echo ""
    ls -lh "$OUTPUT_DIR"/
}

# Run main function
main "$@"
