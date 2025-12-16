# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Drupal content analysis toolkit that runs against local database copies to inform test prioritization. Clone this repo into the root of a DDEV-powered Drupal site.

## Architecture

```
my-drupal-site/
├── web/
├── .ddev/
└── content_analysis/        # This repo, cloned here
    ├── scripts/
    │   └── drupal-content-analysis.sh
    ├── databases/           # Store .sql.gz backups here (gitignored)
    ├── reports/             # Generated reports (gitignored)
    │   └── content-analysis-report-mysite-20250115-143022/
    │       ├── content-analysis-report.md
    │       ├── content-type-activity.csv
    │       ├── editor-activity.csv
    │       ├── high-revision-content.csv
    │       ├── paragraph-summary.csv
    │       └── ... (15 CSV files total)
    └── docs/
        └── background.md    # Rationale and detailed SQL queries
```

## Running the Analysis

From the Drupal project root (where `.ddev/` lives):

```bash
ddev import-db --file content_analysis/databases/mysite_database.sql.gz
./content_analysis/scripts/drupal-content-analysis.sh --site=mysite
```

The `--site` flag names the output directory and sets the Site field in the report header. Output is written directly to `content_analysis/reports/` with a timestamped directory name.

The CSV files allow you to dig deeper after reviewing the initial report (sort, filter, run follow-up queries). Repeat with different database backups to analyze multiple sites.

## Key Configuration (in drupal-content-analysis.sh)

- `DAYS_RECENT=90` - Time window for "recent" content activity
- `DAYS_EDITOR_ACTIVITY=180` - Time window for editor activity analysis
- `HIGH_REVISION_THRESHOLD=5` - Minimum revisions to flag as "high revision"
- `HIGH_REVISION_LIMIT=50` - Max high-revision items to show
- `RECENT_CONTENT_LIMIT=50` - Max recently edited nodes to show
- `PARAGRAPH_LIST_LIMIT=500` - Max paragraph instances to show
- `BLOCK_LIST_LIMIT=100` - Max block content items to show
- `TAXONOMY_LIST_LIMIT=200` - Max taxonomy terms to show
- `MEDIA_LIST_LIMIT=100` - Max media items to show

## Analysis Queries

The script runs these queries against Drupal tables. There are two types of reports:
- **Summaries**: Aggregated counts by type (useful for prioritization)
- **Content Lists**: Individual items with edit URLs (useful for investigation)

### Summaries

| Query | Purpose |
|-------|---------|
| Content Type Activity | Most-edited content types |
| Content Type Activity (no sync) | Same, excluding Content Sync imports |
| Content Sync Status | local_only vs syndicated vs syndicated_locally_modified |
| Synced Node Counts | Content Sync volume by type |
| Editor Activity Patterns | User/content type editing patterns |
| Paragraph Type Summary | Count of each paragraph type |
| Block Content Type Summary | Count of each block type |
| Taxonomy Vocabulary Summary | Term counts by vocabulary |
| Media Type Summary | Count of each media type |

### Content Lists

| Query | Purpose |
|-------|---------|
| High-Revision Content | Nodes with many revisions (potential UX pain points) |
| Recently Edited Nodes | Most recently changed content |
| Paragraph Content List | Paragraph instances with parent node info |
| Block Content List | Individual custom blocks |
| Taxonomy Term List | Individual taxonomy terms |
| Media Content List | Individual media items |

## Database Tables Used

- `node_field_data` - Core node data
- `node_revision` - Revision history
- `users_field_data` - User accounts
- `cms_content_sync_entity_status` - Content Sync tracking (optional)
- `paragraphs_item_field_data` - Paragraph usage (optional)
- `block_content_field_data` - Custom block content (optional)
- `taxonomy_term_field_data` - Taxonomy terms (optional)
- `media_field_data` - Media items (optional)
