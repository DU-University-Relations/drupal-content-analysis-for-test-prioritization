# Background: Content Analysis via Local Database

## Purpose
This document describes a method for analyzing production content patterns using local database copies.

The goal is to inform test prioritization by understanding what content types and workflows are actually used in production, rather than writing tests based on assumptions.

**Key insight:** Functional tests are most meaningful when they model real user behavior. Analyzing production data helps us discover what the real acceptance criteria should be based on actual usage.

## Why Local Database Analysis?
The team has explored several approaches to content analysis:

| Approach | Limitation |
| :--- | :--- |
| **Manual UI audits** | Tedious, error-prone, doesn't scale |
| **Usage Report Views in Drupal** | Times out on large sites before completing, or have to use pagination on Views, which is inefficient |
| **Real-time dynamic interfaces** | Impacts site performance |
| **Local database queries** | Fast, deep, repeatable, no production impact |

Manual content audits are tedious and involve a lot of copy and pasting from the Drupal UI into spreadsheets.

This SQL-based approach can automate and extend that work.

## Process

### 1. Grab Database Backup from Pantheon
Download a database backup from the Pantheon dashboard for the site you want to analyze.

### 2. Import into DDEV
```bash
ddev import-db --file dumpfile.sql.gz
````

### 3\. Add Indexes for Query Performance

The script automatically creates indexes on columns commonly used in analysis queries. Without these, queries can take 4+ minutes. With indexes, the same queries complete in \~30 seconds.

**Indexes created automatically by the script:**

| Table | Index | Purpose |
| :--- | :--- | :--- |
| `cms_content_sync_entity_status` | `idx_last_import` | Content Sync filtering |
| `cms_content_sync_entity_status` | `idx_sync_lookup` | Content Sync JOIN operations |
| `node_field_data` | `idx_analysis_changed` | Recently Edited sorting |
| `node_field_data` | `idx_analysis_type_changed` | Content Type Activity filtering |
| `node_field_data` | `idx_analysis_uid_changed` | Editor Activity queries |
| `node_revision` | `idx_analysis_nid` | High-Revision Content JOIN |
| `paragraphs_item_field_data` | `idx_analysis_parent` | Paragraph Content List JOIN |
| `block_content_field_data` | `idx_analysis_changed` | Block Content List sorting |
| `taxonomy_term_field_data` | `idx_analysis_changed` | Taxonomy Term List sorting |
| `media_field_data` | `idx_analysis_changed` | Media Content List sorting |

To manually verify indexes on any table:

```sql
ddev drush sql-query "SHOW INDEX FROM node_field_data WHERE Key_name LIKE 'idx_analysis%';"
```

### 4\. Run Analysis Queries

See the **Standard Queries** section below.

### 5\. Export and Analyze Results

A bash script adds indexes, compiles the analysis queries, and creates a report in markdown format.

-----

## Standard Queries

### Content Type Activity (What gets edited most?)

This query identifies which content types see the most editing activity, helping prioritize which workflows to test first.

```sql
SELECT n.type, 
       COUNT(*) as total_nodes,
       COUNT(CASE WHEN n.changed > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 90 DAY)) THEN 1 END) as edited_last_90_days, 
       COUNT(CASE WHEN n.created > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 90 DAY)) THEN 1 END) as created_last_90_days 
FROM node_field_data n 
GROUP BY n.type 
ORDER BY edited_last_90_days DESC;
```

### Content Type Activity (Excluding Content Sync Imports)

Same as above, but filters out content that was imported via Content Sync and not locally modified. This shows what editors are actually touching.

**Note:** This query requires the indexes from Step 3 to run in reasonable time.

```sql
SELECT n.type, 
       COUNT(*) as total_nodes,
       COUNT(CASE WHEN n.changed > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 90 DAY)) THEN 1 END) as edited_last_90_days, 
       COUNT(CASE WHEN n.created > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 90 DAY)) THEN 1 END) as created_last_90_days 
FROM node_field_data n 
LEFT JOIN cms_content_sync_entity_status s 
ON n.nid = s.entity_target_id AND s.entity_type = 'node' 
WHERE s.last_import IS NULL OR s.last_import < n.changed 
GROUP BY n.type 
ORDER BY edited_last_90_days DESC;
```

### Content Sync Status by Type

Distinguishes between locally-created content, syndicated content, and syndicated content that was locally modified.

```sql
SELECT n.type, 
       CASE 
         WHEN s.entity_target_id IS NULL THEN 'local_only' 
         WHEN s.last_import >= n.changed THEN 'syndicated_unmodified' 
         ELSE 'syndicated_locally_modified' 
       END as sync_status, 
       COUNT(*) as count 
FROM node_field_data n 
LEFT JOIN cms_content_sync_entity_status s 
ON n.nid = s.entity_target_id AND s.entity_type = 'node' 
GROUP BY n.type, sync_status 
ORDER BY n.type, sync_status;
```

### Synced Node Counts by Type

A simpler query to see how many nodes of each type came through Content Sync.

```sql
SELECT n.type, COUNT(*) as synced_count 
FROM cms_content_sync_entity_status s 
JOIN node_field_data n ON s.entity_target_id = n.nid 
WHERE s.entity_type = 'node' 
GROUP BY n.type;
```

### Editor Activity Patterns

Shows which users are editing which content types, useful for understanding role-based workflows.

```sql
SELECT u.name, n.type, COUNT(*) as edits, 
       MAX(FROM_UNIXTIME(n.changed)) as last_edit 
FROM node_field_data n 
JOIN users_field_data u ON n.uid = u.uid 
WHERE n.changed > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 180 DAY)) 
GROUP BY u.name, n.type 
ORDER BY edits DESC;
```

### High-Revision Content (Potential Pain Points)

Content with many revisions may indicate editing friction or complex workflows worth investigating.

```sql
SELECT n.nid, n.title, n.type, COUNT(r.vid) as revision_count, 
       FROM_UNIXTIME(n.created) as created, 
       FROM_UNIXTIME(n.changed) as last_changed 
FROM node_field_data n 
JOIN node_revision r ON n.nid = r.nid 
GROUP BY n.nid, n.title, n.type, n.created, n.changed 
HAVING revision_count > 5 
ORDER BY revision_count DESC 
LIMIT 50;
```

### Paragraph Type Usage

Shows which paragraph components are actually used across the site.

```sql
SELECT p.type, COUNT(*) as usage_count 
FROM paragraphs_item_field_data p 
GROUP BY p.type 
ORDER BY usage_count DESC;
```

-----

## Mapping Results to Test Priorities

| Finding | Testing Implication |
| :--- | :--- |
| **High edit frequency content types** | Prioritize Playwright tests for these workflows |
| **Content types with high revision counts** | May indicate UX issues; consider edge case testing |
| **Locally-modified syndicated content** | Test the "edit after sync" workflow |
| **Top paragraph types** | Focus component tests on these |
| **Editor patterns by role** | Validate against QA Account roles |

-----

## Related Resources

**Drupal Documentation:**

  * [Drupal Testing Guide](https://www.drupal.org/docs/testing)
  * [Content Moderation](https://www.drupal.org/docs/8/core/modules/content-moderation)
  * [Paragraphs Module](https://www.drupal.org/project/paragraphs)

**Content Sync:**

  * [CMS Content Sync Module](https://www.drupal.org/project/cms_content_sync) - If your site uses content syndication

## Notes

  * This analysis uses a point-in-time snapshot. For trend analysis, repeat periodically with fresh backups.
  * The indexes added locally do not affect production databases.
  * Results should be cross-referenced with team knowledge about upcoming deprecations or migrations.

<!-- end list -->