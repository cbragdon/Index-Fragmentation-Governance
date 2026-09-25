# SQL Server index defrag

## What this process is for

This process helps a DBA maintain SQL Server rowstore indexes when their pages have become sparsely filled or out of logical order. You can preview an entire instance or focus on selected databases, tables, or indexes, then run only the qualifying work. It measures each eligible index partition, chooses a reorganize or rebuild, and reports what it planned or did. After a reorganize, it can optionally hand index statistics decisions to the separate Stats Governance process.

## Why choose page fullness or page link fragmentation?

- **Page fullness** (`PAGE_FULLNESS`) asks how much of each index page contains data. Choose it when low fullness makes the same data occupy more pages. More pages can mean more reads and more memory to cache them, even when the pages are in order. For example, an index that is 70% full with 2% link fragmentation has a fullness issue. This process rebuilds an index that qualifies on fullness.
- **Page link fragmentation** (`PAGE_LINK`) asks whether leaf pages follow the index's logical key order. Choose it when an important workload scans many pages or reads key ranges and out-of-order pages may reduce efficient read-ahead. For example, an index that is 95% full with 20% link fragmentation has a page-order issue. This process reorganizes at moderate fragmentation and rebuilds at higher fragmentation.
Choose one criterion for each run. To investigate both conditions, preview or run the procedure separately with each choice.

“Page link fragmentation” means out-of-order pages; it does not mean damaged page pointers. The default qualification thresholds are below 75% page fullness for a fullness run, or at least 10% link fragmentation for a link run, with rebuild at 30% link fragmentation. These are configurable process settings, not universal performance targets. A percentage alone does not prove that maintenance will help: compare the before and after measurements and the performance of the queries that use the index. Microsoft notes that low page density often has a greater impact than fragmentation, while fragmentation mainly affects large scans. See [Microsoft's index maintenance guidance](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes?view=sql-server-ver17).

`sql/usp_DefragIndexes.sql` installs `dbo.usp_DefragIndexes` in an administration database. It scans online, writable user databases on the current SQL Server instance and plans maintenance for rowstore index partitions. It excludes system databases, snapshots, heaps, columnstore indexes, disabled indexes, and small partitions.

## Install

Run the script in the administration database on SQL Server 2016 SP1 or later. The administration database must have compatibility level 130 or higher for `OPENJSON`:

```powershell
sqlcmd -S YourServer -d YourAdminDatabase -E -b -i .\sql\usp_DefragIndexes.sql
```

The caller needs visibility into the selected databases, `VIEW DATABASE STATE` to read `sys.dm_db_index_physical_stats`, and `ALTER` permission on the selected tables to execute maintenance. A DBA login with appropriate rights is the simplest operator. The procedure must run outside an explicit transaction.

## Choose scope

Leave `@Targets` null for every eligible user database. Otherwise, pass a JSON array of selectors. Each selector requires a database; schema, table, and index narrow the selection. Selectors can be mixed and overlapping selectors are handled once.

```sql
-- Preview the entire instance for page link fragmentation.
EXEC dbo.usp_DefragIndexes @Criterion = 'PAGE_LINK';

-- Preview selected databases.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"Sales"},{"database":"Warehouse"}]',
    @Criterion = 'PAGE_LINK';

-- Preview a table and one index on a different table.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[
      {"database":"Sales","schema":"dbo","table":"Orders"},
      {"database":"Sales","schema":"dbo","table":"OrderLines","index":"IX_OrderLines_OrderId"}
    ]',
    @Criterion = 'PAGE_FULLNESS';
```

## Choose criterion

Set the required `@Criterion` to either `PAGE_FULLNESS` or `PAGE_LINK`. The procedure reads the leaf level `IN_ROW_DATA` metrics from `sys.dm_db_index_physical_stats` in `SAMPLED` mode.

| Criterion | Qualifies when | Planned action |
| --- | --- | --- |
| `PAGE_FULLNESS` | Average page space used is below `@MinPageFullness` (default 75%) | Rebuild |
| `PAGE_LINK` | Logical fragmentation is at least `@MinLinkFragmentation` (default 10%) | Reorganize below `@RebuildAtFragmentation` (default 30%); rebuild at or above it |

`PAGE_LINK` is SQL Server's logical page order fragmentation, reported as `avg_fragmentation_in_percent`. Page fullness is `avg_page_space_used_in_percent`. A partition must also have at least `@MinPageCount` pages (default 1,000). An index with a configured fill factor below `@MinPageFullness` is exempt from the fullness test because rebuilding it preserves that fill factor and would predictably leave it below the requested target. Indexes that disallow page locks are rebuilt instead of reorganized.

```sql
-- Preview indexes with low page fullness in one database.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"Sales"}]',
    @Criterion = 'PAGE_FULLNESS',
    @MinPageFullness = 80;

-- Preview indexes with out-of-order pages in one table.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"Sales","schema":"dbo","table":"Orders"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 15,
    @RebuildAtFragmentation = 35;
```

## Execute

The default `@Execute = 0` returns planned SQL without altering indexes. After reviewing the result, set `@Execute = 1`. `@MaxOperations` limits the run to the largest qualifying partitions first; extra candidates are marked `DEFERRED`. `@OnlineRebuild = 1` requests online rebuilds where the SQL Server version, edition, and index support them. The default is an offline rebuild. `@MaxDop` controls rebuild parallelism.

```sql
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"Sales"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 15,
    @RebuildAtFragmentation = 35,
    @MaxOperations = 20,
    @OnlineRebuild = 1,
    @Execute = 1;
```

The first result set contains the candidate partitions, measured values, reason, action, command, and status (`PLANNED`, `DEFERRED`, `SUCCEEDED`, or `FAILED`). The second result set reports database scan errors. The third result set shows table-level handoffs to Stats Governance after successful reorganizations, with status `PLANNED`, `SKIPPED`, `DELEGATED`, or `FAILED`. When the handoff runs, the Stats Governance procedure also emits its own decision and execution result sets. Individual errors are recorded and the run continues. No candidate means no index met the scope and thresholds. The instance application lock prevents two executing runs of this procedure from overlapping when installed in the same administration database.

Rebuilds retain each index's existing fill factor and refresh that index's statistics as part of the rebuild. Reorganize does not refresh statistics. The separate Stats Governance engine decides whether statistics need maintenance from modification, cooldown, scope, capability, sampling, and persistence rules. Defrag does not issue a direct `UPDATE STATISTICS` after reorganizing. Set `@StatsGovernanceDatabase` to the utility database containing `dbo.usp_DRE_StatsGovernanceTargeted_v1` and select `@StatsGovernanceMode = 'RECOMMEND'` or `'ENFORCE'` to hand off each affected table with `INDEX_ONLY` scope. The default mode is `NONE`.

```sql
-- Reorganize qualifying indexes, then ask Stats Governance for recommendations.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"Production","table":"TransactionHistoryArchive"}]',
    @Criterion = 'PAGE_LINK',
    @StatsGovernanceDatabase = N'DBAdmin',
    @StatsGovernanceMode = 'RECOMMEND',
    @Execute = 1;
```

`ENFORCE` is an explicit choice and remains subject to the Stats Governance database approval and eligibility gates. Its targeted interface accepts a table and `INDEX_ONLY` scope, so it may maintain another eligible index statistic on the same table, and it may leave a reorganized index statistic unchanged when that statistic is not eligible. `DELEGATED` means the governance procedure ran successfully; inspect its result sets and telemetry for the per-statistic outcome. Run during a maintenance window appropriate for the selected indexes, especially if using offline rebuilds.

## Test and compare before and after

The [AdventureWorks2019 example](tests/before_after_AdventureWorks2019.sql) creates a dedicated demo table, generates page fragmentation and low page fullness, previews each criterion, executes each action, and returns a side-by-side comparison of page count, fullness, link fragmentation, and the index statistic's last update time. The page-link step asks the real `DBAdmin` Stats Governance installation for `RECOMMEND` results; it does not force a statistics update. It leaves the demo table in place for inspection and includes an optional cleanup command at the end. The example expects the latest defrag procedure in `StatsGovernanceTest`; replace that database name if you installed it elsewhere.

```powershell
sqlcmd -S YourServer -d StatsGovernanceTest -E -b -i .\sql\usp_DefragIndexes.sql
sqlcmd -S YourServer -d AdventureWorks2019 -E -b -i .\tests\before_after_AdventureWorks2019.sql
```

For a smaller test on an existing AdventureWorks2019 index, [the smoke test](tests/AdventureWorks2019_smoke.sql) previews and executes both criteria on `Production.TransactionHistoryArchive`. [Scope previews](tests/scope_preview.sql) cover table, database, and instance selectors without changing indexes.

The [local validation record](docs/LOCAL_TEST_RESULTS_20260924.md) captures the before-and-after measurements and the Stats Governance RunID from the dedicated demo.
