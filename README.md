# SQL Server index defrag

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
-- Preview the entire instance (the default).
EXEC dbo.usp_DefragIndexes;

-- Preview selected databases.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"Sales"},{"database":"Warehouse"}]';

-- Preview a table and one index on a different table.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[
      {"database":"Sales","schema":"dbo","table":"Orders"},
      {"database":"Sales","schema":"dbo","table":"OrderLines","index":"IX_OrderLines_OrderId"}
    ]';
```

## Choose criterion

Set `@Criterion` to `PAGE_FULLNESS`, `PAGE_LINK`, or `EITHER` (default). The procedure reads the leaf level `IN_ROW_DATA` metrics from `sys.dm_db_index_physical_stats` in `SAMPLED` mode.

| Criterion | Qualifies when | Planned action |
| --- | --- | --- |
| `PAGE_FULLNESS` | Average page space used is below `@MinPageFullness` (default 75%) | Rebuild |
| `PAGE_LINK` | Logical fragmentation is at least `@MinLinkFragmentation` (default 10%) | Reorganize below `@RebuildAtFragmentation` (default 30%); rebuild at or above it |
| `EITHER` | Either test qualifies | Rebuild if fullness qualifies or link fragmentation reaches the rebuild threshold; otherwise reorganize |

`PAGE_LINK` is SQL Server's logical page order fragmentation, reported as `avg_fragmentation_in_percent`. Page fullness is `avg_page_space_used_in_percent`. A partition must also have at least `@MinPageCount` pages (default 1,000). An index with a configured fill factor below `@MinPageFullness` is exempt from the fullness test because rebuilding it preserves that fill factor and would predictably leave it below the requested target. Indexes that disallow page locks are rebuilt instead of reorganized.

```sql
-- Preview indexes with low page fullness in one database.
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"Sales"}]',
    @Criterion = 'PAGE_FULLNESS',
    @MinPageFullness = 80;

-- Preview indexes with broken page links in one table.
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
