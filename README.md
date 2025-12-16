# Drupal Content Analysis

Analyze production content patterns from Drupal database backups to inform test prioritization.

## Quick Start

### 1. Clone into your Drupal site

From your DDEV-powered Drupal project root:

```bash
git clone <repo-url> content_analysis
```

Your structure should look like:
```
my-drupal-site/
├── web/
├── vendor/
├── .ddev/
└── content_analysis/    # This repo
```

### 2. Download a database backup

Download a database backup from Pantheon (or your hosting provider) and place it in `content_analysis/databases/`:

```bash
# Example: downloading from Pantheon
terminus backup:get my-site.live --element=db --to=content_analysis/databases/
```

### 3. Import the database

```bash
ddev import-db --file content_analysis/databases/my-site_live_database.sql.gz
```

### 4. Run the analysis

```bash
./content_analysis/scripts/drupal-content-analysis.sh --site=my-site
```

The script will:
- Verify DDEV is running
- Create performance indexes (if Content Sync tables exist)
- Run analysis queries
- Generate output directly in `content_analysis/reports/`

Output is organized in a timestamped directory:
```
content_analysis/reports/content-analysis-report-my-site-20250115-143022/
├── content-analysis-report.md    # Human-readable report
├── content-type-activity.csv
├── editor-activity.csv
└── ... (15 CSV files for deeper analysis)
```

## Analyzing Multiple Sites

Repeat steps 3-4 for each site. The `--site` flag keeps outputs organized:

```bash
# Import and analyze site A
ddev import-db --file content_analysis/databases/site-a_database.sql.gz
./content_analysis/scripts/drupal-content-analysis.sh --site=site-a

# Import and analyze site B
ddev import-db --file content_analysis/databases/site-b_database.sql.gz
./content_analysis/scripts/drupal-content-analysis.sh --site=site-b
```

Results appear in separate directories:
```
content_analysis/reports/
├── content-analysis-report-site-a-20250115-143022/
└── content-analysis-report-site-b-20250115-144533/
```

## What the Report Contains

| Section | Description |
|---------|-------------|
| Content Type Activity | Most-edited content types (prioritize tests here) |
| Content Sync Status | Local vs syndicated vs locally-modified content |
| Editor Activity | Who edits what (validate against QA roles) |
| High-Revision Content | Potential UX pain points |
| Paragraph Usage | Most-used components |

## CSV Data Files

Each analysis generates CSV files alongside the markdown report for follow-up investigation:

| File | Contents |
|------|----------|
| `content-type-activity.csv` | All content types with edit/create counts |
| `content-type-activity-no-sync.csv` | Same, excluding Content Sync imports |
| `content-sync-status.csv` | Sync status breakdown by type |
| `synced-node-counts.csv` | Volume of synced content |
| `editor-activity.csv` | User editing patterns |
| `high-revision-content.csv` | Nodes with many revisions |
| `recent-nodes.csv` | Most recently edited content |
| `paragraph-summary.csv` | Paragraph type usage counts |
| `paragraph-list.csv` | Individual paragraph instances with parent nodes |
| `block-summary.csv` | Block content type counts |
| `block-list.csv` | Individual custom blocks |
| `taxonomy-summary.csv` | Term counts by vocabulary |
| `taxonomy-list.csv` | Individual taxonomy terms |
| `media-summary.csv` | Media item counts by type |
| `media-list.csv` | Individual media items |

Open these in a spreadsheet to sort, filter, or run additional analysis after reviewing the markdown report.

## Configuration

Edit `scripts/drupal-content-analysis.sh` to adjust:

| Variable | Default | Description |
|----------|---------|-------------|
| `DAYS_RECENT` | 90 | Time window for "recent" activity |
| `DAYS_EDITOR_ACTIVITY` | 180 | Time window for editor analysis |
| `HIGH_REVISION_THRESHOLD` | 5 | Min revisions to flag |
| `HIGH_REVISION_LIMIT` | 50 | Max items in high-revision list |

## Requirements

- [DDEV](https://ddev.com/) with a running Drupal project
- Database backup from Pantheon (or compatible hosting)

## Further Reading

See [docs/background.md](docs/background.md) for the rationale behind this approach and detailed SQL queries.
